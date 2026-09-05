//
//  WingmanUsageSharingTests.swift
//  WingmanTests
//
//  Covers usage sharing: the default-on preference and its persistence, the turn recorder's
//  timings and tool calls, the wire shape of the report the relay validates, and the relay's
//  "stored" answer. No network, no app running.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanUsageSharingTests {

    private func throwawayUserDefaults() -> UserDefaults {
        let suiteName = "io.forit.wingman.tests.usage.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    // MARK: - Preference

    @Test func sharingIsOnUntilThePersonSwitchesItOff() {
        let userDefaults = throwawayUserDefaults()
        let preference = WingmanUsageSharingPreference(userDefaults: userDefaults)
        #expect(preference.isEnabled == true)
        #expect(preference.hasAcknowledgedNotice == false)

        preference.setEnabled(false)
        preference.acknowledgeNotice()

        let reopened = WingmanUsageSharingPreference(userDefaults: userDefaults)
        #expect(reopened.isEnabled == false)
        #expect(reopened.hasAcknowledgedNotice == true)
    }

    @Test func theNoticeSaysWhatIsKeptAndWhatIsNot() {
        #expect(WingmanUsageSharingNotice.body.contains("what you ask Wingman and what it answers"))
        #expect(WingmanUsageSharingNotice.body.contains("never keeps your screen or your voice"))
        #expect(WingmanUsageSharingNotice.body.contains("turn this off"))
    }

    // MARK: - Recorder

    private let keyDown = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theRecorderMeasuresEachPhaseFromTheFinalTranscript() {
        let transcriptFinal = keyDown.addingTimeInterval(2.1)
        let recorder = WingmanTurnUsageRecorder(
            question: "how do I add a crew member in FL3XX",
            model: "claude-sonnet-5",
            pushToTalkKeyDownDate: keyDown,
            transcriptFinalisedAt: transcriptFinal,
            appVersion: "0.1.58",
            turnId: "turn-1"
        )
        recorder.noteModelRoundStarted()
        recorder.noteFirstModelText(at: transcriptFinal.addingTimeInterval(0.9))
        recorder.noteFirstModelText(at: transcriptFinal.addingTimeInterval(5.0)) // a later round never moves the first
        recorder.noteToolCall(name: "support_searchKbArticles", searchTerms: "crew member", outcome: .ok)
        recorder.noteModelRoundStarted()
        recorder.noteFirstSpeech(at: transcriptFinal.addingTimeInterval(3.25))
        recorder.noteAnswerComplete(at: transcriptFinal.addingTimeInterval(6.0))

        let report = recorder.makeReport(answer: "open the crew tab.", outcome: .answered, pointed: true, finishedAt: transcriptFinal.addingTimeInterval(9.4))

        #expect(report.turnId == "turn-1")
        #expect(report.askedAt == "2027-01-15T08:00:00.000Z")
        #expect(report.appVersion == "0.1.58")
        #expect(report.model == "claude-sonnet-5")
        #expect(report.question == "how do I add a crew member in FL3XX")
        #expect(report.answer == "open the crew tab.")
        #expect(report.modelRounds == 2)
        #expect(report.outcome == .answered)
        #expect(report.pointed == true)
        #expect(report.toolCalls == [WingmanUsageToolCall(name: "support_searchKbArticles", searchTerms: "crew member", outcome: .ok)])
        #expect(report.timings == WingmanUsageTimings(listeningMs: 2100, firstModelTextMs: 900, firstSpeechMs: 3250, answerCompleteMs: 6000, totalMs: 9400))
    }

    @Test func anInterruptedTurnReportsOnlyWhatHappened() {
        let recorder = WingmanTurnUsageRecorder(question: "hello", model: "claude-sonnet-5", pushToTalkKeyDownDate: nil, transcriptFinalisedAt: keyDown, appVersion: "0.1.58", turnId: "turn-2")
        recorder.noteModelRoundStarted()
        let report = recorder.makeReport(answer: "", outcome: .interrupted, pointed: false, finishedAt: keyDown.addingTimeInterval(0.5))
        #expect(report.timings == WingmanUsageTimings(listeningMs: nil, firstModelTextMs: nil, firstSpeechMs: nil, answerCompleteMs: nil, totalMs: 500))
        #expect(report.askedAt == "2027-01-15T08:00:00.000Z")
        #expect(report.toolCalls.isEmpty)
    }

    @Test func toolCallsStopAtTheRelaysLimit() {
        let recorder = WingmanTurnUsageRecorder(question: "hello", model: "claude-sonnet-5", pushToTalkKeyDownDate: nil, transcriptFinalisedAt: keyDown, appVersion: "0.1.58", turnId: "turn-3")
        for _ in 0..<(WingmanTurnUsageRecorder.maximumRecordedToolCalls + 5) {
            recorder.noteToolCall(name: "support_listTickets", searchTerms: nil, outcome: .ok)
        }
        #expect(recorder.makeReport(answer: "", outcome: .answered, pointed: false).toolCalls.count == WingmanTurnUsageRecorder.maximumRecordedToolCalls)
    }

    // MARK: - Wire shape

    @Test func theReportEncodesTheFieldNamesTheRelayValidates() throws {
        let recorder = WingmanTurnUsageRecorder(question: "hello", model: "claude-sonnet-5", pushToTalkKeyDownDate: keyDown, transcriptFinalisedAt: keyDown.addingTimeInterval(1), appVersion: "0.1.58", turnId: "turn-4")
        recorder.noteToolCall(name: "support_getKbArticle", searchTerms: nil, outcome: .error)
        let report = recorder.makeReport(answer: "hi", outcome: .failed, pointed: false, finishedAt: keyDown.addingTimeInterval(2))

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(json.keys) == ["turnId", "askedAt", "appVersion", "model", "question", "answer", "toolCalls", "modelRounds", "timings", "outcome", "pointed"])
        #expect(json["outcome"] as? String == "failed")
        let toolCalls = try #require(json["toolCalls"] as? [[String: Any]])
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["name"] as? String == "support_getKbArticle")
        #expect(toolCalls[0]["outcome"] as? String == "error")
        #expect(toolCalls[0]["searchTerms"] == nil) // nil is omitted, not sent as null
        let timings = try #require(json["timings"] as? [String: Any])
        #expect(timings["listeningMs"] as? Int == 1000)
        #expect(timings["totalMs"] as? Int == 1000)
        #expect(timings["firstSpeechMs"] == nil)
    }

    @Test func theRelaysAnswerSaysWhetherTheReportWasKept() {
        #expect(ClaudeAPI.usageReportWasStored(inResponseBody: Data(#"{"stored":true}"#.utf8)) == true)
        #expect(ClaudeAPI.usageReportWasStored(inResponseBody: Data(#"{"stored":false,"reason":"recording_off"}"#.utf8)) == false)
        #expect(ClaudeAPI.usageReportWasStored(inResponseBody: Data()) == false)
    }
}
