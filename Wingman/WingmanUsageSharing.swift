//
//  WingmanUsageSharing.swift
//  Wingman
//
//  Usage sharing (.ai/decisions.md 010). On by default, disclosed in the panel before the first
//  question, and the person can switch it off there at any time. When it is on, one report per
//  spoken turn goes to the relay (POST /api/usage): the question, the spoken answer, the model,
//  which tools ran (and the keywords of a knowledge base search), how many model rounds it took,
//  and how long each phase lasted. Never the screenshot, the audio, or a tool result.
//

import Foundation

// MARK: - Preference

/// The two switches behind the panel's usage sharing section, persisted in UserDefaults:
/// whether this Mac shares usage, and whether the person has seen the disclosure.
@MainActor
final class WingmanUsageSharingPreference: ObservableObject {
    static let sharesUsageDefaultsKey = "sharesUsageWithForIT"
    static let hasAcknowledgedNoticeDefaultsKey = "hasAcknowledgedUsageSharingNotice"

    /// On unless the person switched it off. A missing key means "never decided", which is on.
    @Published private(set) var isEnabled: Bool

    /// True once the person has seen the disclosure: they pressed Start under it, or "Got it" on a
    /// Mac that had already onboarded before usage sharing existed.
    @Published private(set) var hasAcknowledgedNotice: Bool

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if userDefaults.object(forKey: Self.sharesUsageDefaultsKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = userDefaults.bool(forKey: Self.sharesUsageDefaultsKey)
        }
        self.hasAcknowledgedNotice = userDefaults.bool(forKey: Self.hasAcknowledgedNoticeDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.sharesUsageDefaultsKey)
    }

    func acknowledgeNotice() {
        hasAcknowledgedNotice = true
        userDefaults.set(true, forKey: Self.hasAcknowledgedNoticeDefaultsKey)
    }
}

/// The words the panel shows. Kept beside the report so a change to what is sent is a change here too.
enum WingmanUsageSharingNotice {
    static let title = "Usage shared with ForIT"
    static let body = "ForIT keeps what you ask Wingman and what it answers, which tools it used and how long each step took, to see where Wingman helps and where it is slow. It never keeps your screen or your voice. You can turn this off here at any time."
    static let switchLabel = "Share usage with ForIT"
}

// MARK: - Report

enum WingmanUsageToolOutcome: String, Codable {
    case ok
    case error
    case refused
}

enum WingmanUsageTurnOutcome: String, Codable {
    case answered
    case failed
    case interrupted
}

struct WingmanUsageToolCall: Codable, Equatable {
    var name: String
    /// The keywords sent to the knowledge base search; nil for every other tool.
    var searchTerms: String?
    var outcome: WingmanUsageToolOutcome
}

/// Milliseconds from the moment the transcript was final (the person stopped speaking and
/// started waiting), except `listeningMs`, which is how long the push-to-talk key was held.
struct WingmanUsageTimings: Codable, Equatable {
    var listeningMs: Int?
    var firstModelTextMs: Int?
    var firstSpeechMs: Int?
    var answerCompleteMs: Int?
    var totalMs: Int?
}

/// One spoken turn as the relay's /api/usage accepts it (relay/src/usage.ts). Field names are the
/// wire names; the relay drops anything else, so nothing beyond these is ever sent.
struct WingmanUsageReport: Codable, Equatable {
    var turnId: String
    var askedAt: String
    var appVersion: String
    var model: String
    var question: String
    var answer: String
    var toolCalls: [WingmanUsageToolCall]
    var modelRounds: Int
    var timings: WingmanUsageTimings
    var outcome: WingmanUsageTurnOutcome
    var pointed: Bool
}

// MARK: - Recorder

/// Collects one turn's facts while the pipeline runs and produces the report at the end. Created
/// when the transcript is final, handed through the tool loop, and dropped with the turn.
@MainActor
final class WingmanTurnUsageRecorder {
    /// The relay refuses more than this many tool calls in one report; the turn cap makes it unreachable.
    static let maximumRecordedToolCalls = 24

    let turnId: String
    let question: String
    let model: String
    private let appVersion: String
    private let pushToTalkKeyDownDate: Date?
    private let transcriptFinalisedAt: Date
    private var modelRounds = 0
    private var firstModelTextAt: Date?
    private var firstSpeechAt: Date?
    private var answerCompleteAt: Date?
    private var toolCalls: [WingmanUsageToolCall] = []

    init(
        question: String,
        model: String,
        pushToTalkKeyDownDate: Date?,
        transcriptFinalisedAt: Date = Date(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        turnId: String = UUID().uuidString
    ) {
        self.question = question
        self.model = model
        self.pushToTalkKeyDownDate = pushToTalkKeyDownDate
        self.transcriptFinalisedAt = transcriptFinalisedAt
        self.appVersion = appVersion
        self.turnId = turnId
    }

    /// One call to the relay's /api/chat; a turn with tools has several.
    func noteModelRoundStarted() {
        modelRounds += 1
    }

    func noteFirstModelText(at date: Date = Date()) {
        if firstModelTextAt == nil { firstModelTextAt = date }
    }

    func noteFirstSpeech(at date: Date = Date()) {
        if firstSpeechAt == nil { firstSpeechAt = date }
    }

    /// The model's final reply is complete (speech may still be playing).
    func noteAnswerComplete(at date: Date = Date()) {
        if answerCompleteAt == nil { answerCompleteAt = date }
    }

    func noteToolCall(name: String, searchTerms: String?, outcome: WingmanUsageToolOutcome) {
        guard toolCalls.count < Self.maximumRecordedToolCalls else { return }
        toolCalls.append(WingmanUsageToolCall(name: name, searchTerms: searchTerms, outcome: outcome))
    }

    func makeReport(answer: String, outcome: WingmanUsageTurnOutcome, pointed: Bool, finishedAt: Date = Date()) -> WingmanUsageReport {
        let timings = WingmanUsageTimings(
            listeningMs: pushToTalkKeyDownDate.map { Self.milliseconds(from: $0, to: transcriptFinalisedAt) },
            firstModelTextMs: firstModelTextAt.map { Self.milliseconds(from: transcriptFinalisedAt, to: $0) },
            firstSpeechMs: firstSpeechAt.map { Self.milliseconds(from: transcriptFinalisedAt, to: $0) },
            answerCompleteMs: answerCompleteAt.map { Self.milliseconds(from: transcriptFinalisedAt, to: $0) },
            totalMs: Self.milliseconds(from: transcriptFinalisedAt, to: finishedAt)
        )
        return WingmanUsageReport(
            turnId: turnId,
            askedAt: Self.iso8601Formatter.string(from: pushToTalkKeyDownDate ?? transcriptFinalisedAt),
            appVersion: appVersion,
            model: model,
            question: question,
            answer: answer,
            toolCalls: toolCalls,
            modelRounds: modelRounds,
            timings: timings,
            outcome: outcome,
            pointed: pointed
        )
    }

    private static func milliseconds(from startDate: Date, to endDate: Date) -> Int {
        max(0, Int((endDate.timeIntervalSince(startDate) * 1000).rounded()))
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
