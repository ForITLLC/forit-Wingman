//
//  ElevenLabsTTSClient.swift
//  Wingman
//
//  Speaks the model's reply. First choice is ElevenLabs through the relay's /api/tts
//  (ForIT's key and voice stay server-side). When the relay reports that TTS is not
//  configured (501), the reply is spoken on-device with AVSpeechSynthesizer instead, so
//  the app is never silent because a vendor is switched off.
//
//  Replies are spoken sentence by sentence as they stream in: each sentence is queued with
//  `enqueueSentence`, its audio is fetched while earlier sentences play, and the caller waits
//  for the whole queue with `finishEnqueuedSpeech`. That is what lets the first words be heard
//  a second or two after the model starts writing instead of after the last word.
//

import AVFoundation
import Foundation

enum WingmanSpeechPlaybackError: Error {
    case playbackCouldNotStart
    case audioCouldNotBeDecoded
}

@MainActor
final class ElevenLabsTTSClient {
    private let relayTTSURL: URL
    private let bearerTokenProvider: WingmanBearerTokenProvider
    private let session: URLSession

    /// Called on the main actor when the first queued sentence of a reply starts to play, so the
    /// caller can move the cursor from the spinner to the responding state at that moment.
    var onQueuedPlaybackStarted: (@MainActor () -> Void)?

    /// The audio player for the sentence currently playing. Kept alive so the audio finishes
    /// even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private var audioPlaybackCompletionRelay: AudioPlaybackCompletionRelay?

    private let onDeviceSpeechSynthesizer = AVSpeechSynthesizer()

    /// Set the first time the relay answers 501 so later replies skip the round trip and go
    /// straight to on-device speech for the rest of this run.
    private var hasRelayReportedTTSUnavailable = false

    /// One sentence waiting to be spoken. The fetch starts as soon as a fetch slot is free and
    /// runs while earlier sentences play.
    private final class QueuedSentence {
        let text: String
        var audioFetchTask: Task<Data, Error>?
        init(text: String) {
            self.text = text
        }
    }

    private var queuedSentences: [QueuedSentence] = []
    private var runningAudioFetchCount = 0
    private var queuePlaybackTask: Task<Void, Error>?
    private var isQueuePlaybackRunning = false
    private var hasQueuedPlaybackStarted = false

    /// How many sentence fetches may run at once. Two keeps the next sentence ready while the
    /// current one plays without hammering the relay with the whole reply at once.
    private static let maximumConcurrentAudioFetches = 2

    init(relayTTSURL: URL, bearerTokenProvider: @escaping WingmanBearerTokenProvider) {
        self.relayTTSURL = relayTTSURL
        self.bearerTokenProvider = bearerTokenProvider

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Sentence queue

    /// Queues one sentence of the reply. Its audio fetch starts as soon as a slot is free and
    /// playback starts as soon as it is the head of the queue and its audio has arrived.
    func enqueueSentence(_ sentenceText: String) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }

        queuedSentences.append(QueuedSentence(text: trimmedSentenceText))
        startPendingAudioFetches()

        if queuePlaybackTask == nil {
            isQueuePlaybackRunning = true
            queuePlaybackTask = Task { [weak self] in
                guard let self else { return }
                defer { self.isQueuePlaybackRunning = false }
                do {
                    try await self.playQueuedSentencesUntilEmpty()
                } catch {
                    // A failed sentence ends the reply; what is still queued must not keep
                    // `isPlaying` true forever.
                    self.discardQueuedSentences()
                    throw error
                }
            }
        }
    }

    /// Waits until every queued sentence has been spoken. Throws the first network or playback
    /// error, or `CancellationError` when playback was stopped. Returns at once when nothing was
    /// queued.
    func finishEnqueuedSpeech() async throws {
        guard let playbackTask = queuePlaybackTask else { return }
        defer {
            queuePlaybackTask = nil
            hasQueuedPlaybackStarted = false
        }
        try await playbackTask.value
        try Task.checkCancellation()
    }

    private func playQueuedSentencesUntilEmpty() async throws {
        while let nextSentence = queuedSentences.first {
            try Task.checkCancellation()

            if hasRelayReportedTTSUnavailable {
                queuedSentences.removeFirst()
                nextSentence.audioFetchTask?.cancel()
                noteQueuedPlaybackStartedIfNeeded()
                speakOnDevice(nextSentence.text)
                continue
            }

            if nextSentence.audioFetchTask == nil {
                startPendingAudioFetches()
            }
            guard let audioFetchTask = nextSentence.audioFetchTask else {
                // Fetches are handed out in queue order, so the head always has one; this only
                // keeps a logic slip from turning into a busy loop.
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            do {
                let audioData = try await audioFetchTask.value
                try Task.checkCancellation()
                queuedSentences.removeFirst()
                startPendingAudioFetches()
                noteQueuedPlaybackStartedIfNeeded()
                try await playAudioDataToCompletion(audioData)
            } catch WingmanRelayError.relayRejected(let statusCode, _) where statusCode == 501 {
                hasRelayReportedTTSUnavailable = true
                print("🔊 TTS: relay reports no voice configured; using on-device speech from now on")
                // The loop comes back to this sentence and speaks it on-device.
            }
        }

        // On-device speech is fire-and-forget; wait for it here so the caller's "finished"
        // means the same thing for both voices.
        while onDeviceSpeechSynthesizer.isSpeaking {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func startPendingAudioFetches() {
        guard !hasRelayReportedTTSUnavailable else { return }
        for queuedSentence in queuedSentences where queuedSentence.audioFetchTask == nil {
            guard runningAudioFetchCount < Self.maximumConcurrentAudioFetches else { return }
            runningAudioFetchCount += 1
            let sentenceText = queuedSentence.text
            queuedSentence.audioFetchTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                defer { self.runningAudioFetchCount -= 1 }
                return try await self.fetchAudioThroughRelay(for: sentenceText)
            }
        }
    }

    private func noteQueuedPlaybackStartedIfNeeded() {
        guard !hasQueuedPlaybackStarted else { return }
        hasQueuedPlaybackStarted = true
        onQueuedPlaybackStarted?()
    }

    // MARK: - Relay

    private func fetchAudioThroughRelay(for text: String) async throws -> Data {
        let bearerToken = try await bearerTokenProvider()

        var request = URLRequest(url: relayTTSURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WingmanRelayError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = WingmanRelayError.message(fromRelayBody: String(data: data, encoding: .utf8) ?? "")
            if httpResponse.statusCode == 401 {
                throw WingmanRelayError.notAuthorized(message: errorMessage)
            }
            throw WingmanRelayError.relayRejected(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        return data
    }

    // MARK: - Playback

    /// Plays one sentence's audio and returns when it has finished (or throws when it could not
    /// start or decode). `stopPlayback` resumes the wait early with a `CancellationError`.
    private func playAudioDataToCompletion(_ audioData: Data) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: audioData)
        } catch {
            throw WingmanSpeechPlaybackError.audioCouldNotBeDecoded
        }

        let completionRelay = AudioPlaybackCompletionRelay()
        player.delegate = completionRelay
        audioPlayer = player
        audioPlaybackCompletionRelay = completionRelay
        print("🔊 Relay TTS: playing \(audioData.count / 1024)KB audio")

        defer {
            if audioPlayer === player {
                audioPlayer = nil
                audioPlaybackCompletionRelay = nil
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completionRelay.store(continuation)
            if !player.play() {
                completionRelay.finish(throwing: WingmanSpeechPlaybackError.playbackCouldNotStart)
            }
        }
    }

    private func speakOnDevice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        onDeviceSpeechSynthesizer.speak(utterance)
        print("🔊 On-device TTS: speaking \(text.count) characters")
    }

    /// Whether speech is in progress from either voice, including sentences still queued.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false)
            || onDeviceSpeechSynthesizer.isSpeaking
            || !queuedSentences.isEmpty
            || isQueuePlaybackRunning
    }

    private func discardQueuedSentences() {
        for queuedSentence in queuedSentences {
            queuedSentence.audioFetchTask?.cancel()
        }
        queuedSentences.removeAll()
    }

    /// Stops any in-progress playback immediately and drops every queued sentence.
    func stopPlayback() {
        queuePlaybackTask?.cancel()
        queuePlaybackTask = nil
        hasQueuedPlaybackStarted = false
        discardQueuedSentences()

        // AVAudioPlayer.stop() does not call the delegate, so the waiting loop is released here.
        audioPlaybackCompletionRelay?.finish(throwing: CancellationError())
        audioPlaybackCompletionRelay = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if onDeviceSpeechSynthesizer.isSpeaking {
            onDeviceSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
}

/// Bridges AVAudioPlayer's delegate callbacks to one async wait. The continuation is resumed at
/// most once, whether the audio finished, failed to decode, or was stopped by the client.
private final class AudioPlaybackCompletionRelay: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func store(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        lock.unlock()
        if let error {
            pendingContinuation?.resume(throwing: error)
        } else {
            pendingContinuation?.resume()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(throwing: error ?? WingmanSpeechPlaybackError.audioCouldNotBeDecoded)
    }
}
