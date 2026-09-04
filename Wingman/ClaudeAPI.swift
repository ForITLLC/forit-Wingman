//
//  ClaudeAPI.swift
//  Streaming chat client for the ForIT relay
//
//  Sends Anthropic Messages-API bodies to the relay's /api/chat, which validates the
//  caller's ForIT sign-in, attaches ForIT's key, and streams the SSE back unchanged.
//  The app never holds a vendor key and never talks to the vendor directly.
//

import Foundation

enum WingmanRelayError: LocalizedError {
    /// 401 from the relay: the id_token was missing, expired, or not a ForIT account.
    case notAuthorized(message: String)
    case relayRejected(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let message):
            return "The Wingman relay did not accept your sign-in: \(message)"
        case .relayRejected(let statusCode, let message):
            return "The Wingman relay refused the request (\(statusCode)): \(message)"
        case .invalidResponse:
            return "The Wingman relay returned an invalid response."
        }
    }

    var isNotAuthorized: Bool {
        if case .notAuthorized = self {
            return true
        }
        return false
    }

    /// The relay answers with `{ "error": "...", "message": "..." }`; fall back to the raw body.
    static func message(fromRelayBody body: String) -> String {
        if let bodyData = body.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let message = payload["message"] as? String {
            return message
        }
        return body.isEmpty ? "no details" : body
    }
}

/// Claude chat through the relay, streamed for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let relayChatURL: URL
    var model: String
    private let bearerTokenProvider: WingmanBearerTokenProvider
    private let session: URLSession

    init(relayChatURL: URL, model: String, bearerTokenProvider: @escaping WingmanBearerTokenProvider) {
        self.relayChatURL = relayChatURL
        self.model = model
        self.bearerTokenProvider = bearerTokenProvider

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    /// Every relay call carries the signed-in user's id_token. Asking the provider here (rather
    /// than caching a token) means a refresh happens transparently when one is due.
    private func makeAuthorizedRequest() async throws -> URLRequest {
        let bearerToken = try await bearerTokenProvider()
        var request = URLRequest(url: relayChatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    static func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the relay host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: relayChatURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// The content blocks of a user turn: each screenshot followed by its label, then the spoken
    /// prompt. Shared by the plain vision call and the tool loop so both send the same shape.
    static func userMessageContentBlocks(images: [(data: Data, label: String)], userPrompt: String) -> [[String: Any]] {
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        return contentBlocks
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        messages.append([
            "role": "user",
            "content": Self.userMessageContentBlocks(images: images, userPrompt: userPrompt)
        ])

        let streamedTurn = try await streamTurn(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: [],
            toolChoice: nil,
            onTextChunk: onTextChunk
        )

        let duration = Date().timeIntervalSince(startTime)
        return (text: streamedTurn.text, duration: duration)
    }

    /// One streamed model turn over an explicit message list, optionally offering tools.
    /// `messages` is the Anthropic shape (role + string or content blocks), so a caller running a
    /// tool loop can append the assistant's `tool_use` blocks and its own `tool_result` blocks and
    /// call again. Calls `onTextChunk` on the main actor with the accumulated text as it arrives.
    func streamTurn(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        toolChoice: [String: Any]?,
        maxTokens: Int = 1024,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> ClaudeStreamedTurn {
        var request = try await makeAuthorizedRequest()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            if let toolChoice {
                body["tool_choice"] = toolChoice
            }
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Relay chat request: \(String(format: "%.1f", payloadMB))MB, \(messages.count) message(s), \(tools.count) tool(s), model \(model)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WingmanRelayError.invalidResponse
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorMessage = WingmanRelayError.message(fromRelayBody: errorBodyChunks.joined(separator: "\n"))
            if httpResponse.statusCode == 401 {
                throw WingmanRelayError.notAuthorized(message: errorMessage)
            }
            throw WingmanRelayError.relayRejected(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        var streamParser = ClaudeSSEStreamParser()
        for try await line in byteStream.lines {
            if let accumulatedText = streamParser.consume(line: line) {
                await onTextChunk(accumulatedText)
            }
            if streamParser.hasReachedEndOfMessage {
                break
            }
        }

        return streamParser.finishedTurn()
    }
}

// MARK: - Streamed turn

/// The model asking the app to run one tool. `input` is the parsed JSON the model produced.
struct ClaudeToolUseRequest {
    let id: String
    let name: String
    let input: [String: Any]
}

/// Everything one streamed model turn produced.
struct ClaudeStreamedTurn {
    /// The text blocks joined, in order.
    let text: String
    let toolUses: [ClaudeToolUseRequest]
    /// Anthropic's stop_reason: "end_turn", "tool_use", "max_tokens", ...
    let stopReason: String?
    /// The assistant turn exactly as it must be echoed back into `messages` before tool results:
    /// text blocks and tool_use blocks in stream order.
    let assistantContentBlocks: [[String: Any]]

    var wantsToolCalls: Bool {
        stopReason == "tool_use" && !toolUses.isEmpty
    }
}

/// Incremental parser for the Anthropic Messages SSE stream. Fed one line at a time; pure, so the
/// event handling is unit-tested without a network. Text deltas accumulate per block; tool_use
/// blocks collect their `input_json_delta` fragments and are decoded on `content_block_stop`.
struct ClaudeSSEStreamParser {
    private struct ContentBlockInProgress {
        let type: String
        var toolUseId: String = ""
        var toolName: String = ""
        var text: String = ""
        var partialToolInputJSON: String = ""
        var decodedToolInput: [String: Any] = [:]
    }

    private var blocksByIndex: [Int: ContentBlockInProgress] = [:]
    private var stopReason: String?
    private(set) var hasReachedEndOfMessage = false

    init() {}

    /// Consumes one SSE line. Returns the accumulated text whenever a text delta arrived, so a
    /// caller can render progressively; nil for every other line.
    mutating func consume(line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]" else {
            hasReachedEndOfMessage = true
            return nil
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let eventType = eventPayload["type"] as? String else {
            return nil
        }

        switch eventType {
        case "content_block_start":
            guard let blockIndex = eventPayload["index"] as? Int,
                  let contentBlock = eventPayload["content_block"] as? [String: Any],
                  let blockType = contentBlock["type"] as? String else { return nil }
            var block = ContentBlockInProgress(type: blockType)
            if blockType == "tool_use" {
                block.toolUseId = contentBlock["id"] as? String ?? ""
                block.toolName = contentBlock["name"] as? String ?? ""
            } else if blockType == "text" {
                block.text = contentBlock["text"] as? String ?? ""
            }
            blocksByIndex[blockIndex] = block
            return nil

        case "content_block_delta":
            guard let blockIndex = eventPayload["index"] as? Int,
                  let delta = eventPayload["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return nil }
            if deltaType == "text_delta", let textChunk = delta["text"] as? String {
                var block = blocksByIndex[blockIndex] ?? ContentBlockInProgress(type: "text")
                block.text += textChunk
                blocksByIndex[blockIndex] = block
                return accumulatedText
            }
            if deltaType == "input_json_delta", let partialJSON = delta["partial_json"] as? String {
                var block = blocksByIndex[blockIndex] ?? ContentBlockInProgress(type: "tool_use")
                block.partialToolInputJSON += partialJSON
                blocksByIndex[blockIndex] = block
            }
            return nil

        case "content_block_stop":
            guard let blockIndex = eventPayload["index"] as? Int,
                  var block = blocksByIndex[blockIndex], block.type == "tool_use" else { return nil }
            // An empty tool input streams as no deltas at all; that is a valid `{}`.
            let inputJSON = block.partialToolInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if inputJSON.isEmpty {
                block.decodedToolInput = [:]
            } else if let inputData = inputJSON.data(using: .utf8),
                      let decodedInput = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
                block.decodedToolInput = decodedInput
            } else {
                // Leave the raw text so the tool layer can report a malformed call rather than
                // silently calling with nothing.
                block.decodedToolInput = ["_malformed_input_json": inputJSON]
            }
            blocksByIndex[blockIndex] = block
            return nil

        case "message_delta":
            if let delta = eventPayload["delta"] as? [String: Any],
               let reportedStopReason = delta["stop_reason"] as? String {
                stopReason = reportedStopReason
            }
            return nil

        case "message_stop":
            hasReachedEndOfMessage = true
            return nil

        default:
            return nil
        }
    }

    private var orderedBlocks: [ContentBlockInProgress] {
        blocksByIndex.keys.sorted().compactMap { blocksByIndex[$0] }
    }

    var accumulatedText: String {
        orderedBlocks.filter { $0.type == "text" }.map { $0.text }.joined()
    }

    func finishedTurn() -> ClaudeStreamedTurn {
        var toolUses: [ClaudeToolUseRequest] = []
        var assistantContentBlocks: [[String: Any]] = []

        for block in orderedBlocks {
            switch block.type {
            case "text":
                if !block.text.isEmpty {
                    assistantContentBlocks.append(["type": "text", "text": block.text])
                }
            case "tool_use":
                let toolUse = ClaudeToolUseRequest(id: block.toolUseId, name: block.toolName, input: block.decodedToolInput)
                toolUses.append(toolUse)
                assistantContentBlocks.append([
                    "type": "tool_use",
                    "id": toolUse.id,
                    "name": toolUse.name,
                    "input": toolUse.input
                ])
            default:
                continue
            }
        }

        return ClaudeStreamedTurn(
            text: accumulatedText,
            toolUses: toolUses,
            stopReason: stopReason,
            assistantContentBlocks: assistantContentBlocks
        )
    }
}
