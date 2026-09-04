//
//  ElevenLabsTTSClient.swift
//  Wingman
//
//  Speaks the model's reply. First choice is ElevenLabs through the relay's /api/tts
//  (ForIT's key and voice stay server-side). When the relay reports that TTS is not
//  configured (501), the reply is spoken on-device with AVSpeechSynthesizer instead, so
//  the app is never silent because a vendor is switched off.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let relayTTSURL: URL
    private let bearerTokenProvider: WingmanBearerTokenProvider
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    private let onDeviceSpeechSynthesizer = AVSpeechSynthesizer()

    /// Set the first time the relay answers 501 so later replies skip the round trip and go
    /// straight to on-device speech for the rest of this run.
    private var hasRelayReportedTTSUnavailable = false

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

    /// Speaks `text`, via the relay when it offers TTS and on-device otherwise.
    /// Throws on network or decoding errors other than "TTS not configured". Cancellation-safe.
    func speakText(_ text: String) async throws {
        if !hasRelayReportedTTSUnavailable {
            do {
                try await speakThroughRelay(text)
                return
            } catch WingmanRelayError.relayRejected(let statusCode, _) where statusCode == 501 {
                hasRelayReportedTTSUnavailable = true
                print("🔊 TTS: relay reports no voice configured; using on-device speech from now on")
            }
        }

        try Task.checkCancellation()
        speakOnDevice(text)
    }

    private func speakThroughRelay(_ text: String) async throws {
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

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 Relay TTS: playing \(data.count / 1024)KB audio")
    }

    private func speakOnDevice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        onDeviceSpeechSynthesizer.speak(utterance)
        print("🔊 On-device TTS: speaking \(text.count) characters")
    }

    /// Whether TTS audio is currently playing back (from either source).
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || onDeviceSpeechSynthesizer.isSpeaking
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if onDeviceSpeechSynthesizer.isSpeaking {
            onDeviceSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
}
