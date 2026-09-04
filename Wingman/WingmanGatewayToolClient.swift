//
//  WingmanGatewayToolClient.swift
//  Wingman
//
//  Calls for-mcp gateway tools over MCP Streamable HTTP with the signed-in user's own delegated
//  token (scope access_as_user). The relay is not involved: the gateway sees the person, applies
//  their app role, and audits the call under their identity.
//
//  Protocol shape (JSON-RPC 2.0 over POST):
//    initialize  -> may return an `mcp-session-id` header; the gateway runs stateless so it may not
//    tools/call  -> { result: { content: [{ type: "text", text }], isError } }
//  Responses come back either as JSON or as an SSE body; both are handled.
//

import Foundation

enum WingmanGatewayToolError: LocalizedError {
    /// 401: the token was rejected, the client is not allow-listed, or the user has no gateway role.
    case accessDenied(detail: String)
    /// 403 insufficient_scope: the user's role is below what the tool needs.
    case insufficientAccess(detail: String)
    case gatewayRejected(statusCode: Int, detail: String)
    case invalidResponse(detail: String)
    /// A JSON-RPC level error (unknown tool, bad params) rather than a tool that ran and failed.
    case remoteError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let detail):
            return "The ForIT gateway denied access: \(detail)"
        case .insufficientAccess(let detail):
            return "The ForIT gateway needs a higher access level: \(detail)"
        case .gatewayRejected(let statusCode, let detail):
            return "The ForIT gateway refused the call (\(statusCode)): \(detail)"
        case .invalidResponse(let detail):
            return "The ForIT gateway returned an unexpected response: \(detail)"
        case .remoteError(let code, let message):
            return "The ForIT gateway reported an error (\(code)): \(message)"
        }
    }
}

/// What a tool produced. `isError` mirrors MCP's flag: the tool ran and reported a failure the
/// model should read (e.g. "ticket not found"), as opposed to a transport error, which throws.
struct WingmanGatewayToolResult: Equatable {
    let text: String
    let isError: Bool
}

final class WingmanGatewayToolClient {
    static let mcpProtocolVersion = "2025-06-18"

    private let gatewayMCPURL: URL
    private let bearerTokenProvider: WingmanBearerTokenProvider
    private let urlSession: URLSession

    /// Set from the initialize response when the gateway hands one out; nil on a stateless gateway.
    private var mcpSessionId: String?
    private var hasInitialized = false
    private var nextRequestId = 1

    init(gatewayMCPURL: URL, bearerTokenProvider: @escaping WingmanBearerTokenProvider) {
        self.gatewayMCPURL = gatewayMCPURL
        self.bearerTokenProvider = bearerTokenProvider

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Public

    func callTool(named toolName: String, arguments: [String: Any]) async throws -> WingmanGatewayToolResult {
        if !hasInitialized {
            try await initializeSession()
        }

        do {
            let response = try await sendJSONRPC(method: "tools/call", params: ["name": toolName, "arguments": arguments])
            return try Self.toolResult(fromJSONRPCResponse: response)
        } catch WingmanGatewayToolError.gatewayRejected(let statusCode, _) where statusCode == 404 && mcpSessionId != nil {
            // The gateway forgot our session (restart, scale-out). Start over once.
            hasInitialized = false
            mcpSessionId = nil
            try await initializeSession()
            let response = try await sendJSONRPC(method: "tools/call", params: ["name": toolName, "arguments": arguments])
            return try Self.toolResult(fromJSONRPCResponse: response)
        }
    }

    // MARK: - MCP session

    private func initializeSession() async throws {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let initializeParams: [String: Any] = [
            "protocolVersion": Self.mcpProtocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "ForIT Wingman", "version": appVersion],
        ]
        _ = try await sendJSONRPC(method: "initialize", params: initializeParams)
        hasInitialized = true

        // The spec asks the client to confirm; a stateless gateway ignores it, so a failure
        // here is not worth failing the tool call over.
        try? await sendNotification(method: "notifications/initialized")
    }

    private func sendNotification(method: String) async throws {
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": method]
        var request = try await makeAuthorizedRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: notification)
        _ = try await urlSession.data(for: request)
    }

    private func sendJSONRPC(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestId = nextRequestId
        nextRequestId += 1

        let jsonRPCRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params,
        ]

        var request = try await makeAuthorizedRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonRPCRequest)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WingmanGatewayToolError.invalidResponse(detail: "not an HTTP response")
        }

        if let sessionIdFromGateway = httpResponse.value(forHTTPHeaderField: "mcp-session-id"), !sessionIdFromGateway.isEmpty {
            mcpSessionId = sessionIdFromGateway
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.error(forStatusCode: httpResponse.statusCode, responseBody: responseData, httpResponse: httpResponse)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "content-type")
        let jsonRPCResponse = try Self.parseJSONRPCResponse(body: responseData, contentType: contentType)

        if let error = jsonRPCResponse["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown error"
            throw WingmanGatewayToolError.remoteError(code: code, message: message)
        }
        return jsonRPCResponse
    }

    private func makeAuthorizedRequest() async throws -> URLRequest {
        let bearerToken = try await bearerTokenProvider()
        var request = URLRequest(url: gatewayMCPURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.mcpProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let mcpSessionId {
            request.setValue(mcpSessionId, forHTTPHeaderField: "mcp-session-id")
        }
        return request
    }

    // MARK: - Pure parsing (unit-tested)

    /// Maps a non-2xx gateway answer to the error the pipeline reacts to. 401 and 403 carry the
    /// reason in `WWW-Authenticate` (error_description) or in a JSON body.
    static func error(forStatusCode statusCode: Int, responseBody: Data, httpResponse: HTTPURLResponse?) -> WingmanGatewayToolError {
        let detail = failureDetail(
            responseBody: responseBody,
            wwwAuthenticateHeader: httpResponse?.value(forHTTPHeaderField: "www-authenticate")
        )
        switch statusCode {
        case 401:
            return .accessDenied(detail: detail)
        case 403:
            return .insufficientAccess(detail: detail)
        default:
            return .gatewayRejected(statusCode: statusCode, detail: detail)
        }
    }

    /// Prefers the `error_description="..."` of a WWW-Authenticate challenge, then a JSON body's
    /// `error_description` / `message` / `error`, then the raw body.
    static func failureDetail(responseBody: Data, wwwAuthenticateHeader: String?) -> String {
        if let wwwAuthenticateHeader,
           let descriptionRange = wwwAuthenticateHeader.range(of: "error_description=\"") {
            let afterPrefix = wwwAuthenticateHeader[descriptionRange.upperBound...]
            if let closingQuoteIndex = afterPrefix.firstIndex(of: "\"") {
                let description = String(afterPrefix[..<closingQuoteIndex])
                if !description.isEmpty { return description }
            }
        }
        if let bodyObject = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            for key in ["error_description", "message", "detail", "error"] {
                if let value = bodyObject[key] as? String, !value.isEmpty { return value }
            }
        }
        let bodyText = String(data: responseBody, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bodyText.isEmpty ? "no details" : String(bodyText.prefix(300))
    }

    /// Streamable HTTP answers a POST either with `application/json` (one JSON-RPC object) or with
    /// `text/event-stream` (SSE frames whose `data:` lines are JSON-RPC objects). Returns the first
    /// object that is a response (has `result` or `error`).
    static func parseJSONRPCResponse(body: Data, contentType: String?) throws -> [String: Any] {
        let isEventStream = contentType?.lowercased().contains("text/event-stream") ?? false

        if !isEventStream {
            guard let jsonObject = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw WingmanGatewayToolError.invalidResponse(detail: "body is not a JSON object")
            }
            return jsonObject
        }

        guard let bodyText = String(data: body, encoding: .utf8) else {
            throw WingmanGatewayToolError.invalidResponse(detail: "event stream is not UTF-8")
        }

        // An SSE `data:` payload may span several `data:` lines within one frame; frames are
        // separated by a blank line.
        var currentFrameDataLines: [String] = []
        var responseObjects: [[String: Any]] = []

        func finishFrame() {
            guard !currentFrameDataLines.isEmpty else { return }
            let payloadText = currentFrameDataLines.joined(separator: "\n")
            currentFrameDataLines = []
            if let payloadData = payloadText.data(using: .utf8),
               let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                responseObjects.append(payloadObject)
            }
        }

        for rawLine in bodyText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                finishFrame()
            } else if line.hasPrefix("data:") {
                var dataText = String(line.dropFirst("data:".count))
                if dataText.hasPrefix(" ") { dataText.removeFirst() }
                currentFrameDataLines.append(dataText)
            }
            // `event:`, `id:`, `:` comment lines carry nothing we need.
        }
        finishFrame()

        guard let responseObject = responseObjects.first(where: { $0["result"] != nil || $0["error"] != nil }) else {
            throw WingmanGatewayToolError.invalidResponse(detail: "event stream carried no JSON-RPC response")
        }
        return responseObject
    }

    /// Reads a `tools/call` result: the text blocks joined, and MCP's `isError` flag.
    static func toolResult(fromJSONRPCResponse jsonRPCResponse: [String: Any]) throws -> WingmanGatewayToolResult {
        guard let result = jsonRPCResponse["result"] as? [String: Any] else {
            throw WingmanGatewayToolError.invalidResponse(detail: "tools/call response has no result")
        }
        let contentBlocks = result["content"] as? [[String: Any]] ?? []
        let textParts: [String] = contentBlocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let isError = result["isError"] as? Bool ?? false

        var text = textParts.joined(separator: "\n")
        if text.isEmpty, let structuredContent = result["structuredContent"],
           let structuredData = try? JSONSerialization.data(withJSONObject: structuredContent, options: [.sortedKeys]),
           let structuredText = String(data: structuredData, encoding: .utf8) {
            text = structuredText
        }
        if text.isEmpty {
            text = isError ? "The tool failed without a message." : "The tool returned nothing."
        }
        return WingmanGatewayToolResult(text: text, isError: isError)
    }
}
