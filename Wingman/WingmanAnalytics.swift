//
//  WingmanAnalytics.swift
//  Wingman
//
//  Local analytics wrapper. Upstream sent these events to a hosted analytics SDK;
//  Wingman sends nothing off the machine. The event names are kept so the
//  call sites stay stable and so a ForIT-owned sink can be wired in later
//  without touching the pipeline code. Ordinary events are debug log lines (not persisted by
//  the unified log); failures are error-level lines with public fields so they can be read
//  back with `log show --predicate 'subsystem == "io.forit.wingman"'` after the fact.
//

import Foundation
import os

enum WingmanAnalytics {

    private static let logger = Logger(subsystem: "io.forit.wingman", category: "analytics")

    private static func record(_ eventName: String, properties: [String: String] = [:]) {
        let propertySummary = properties.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        logger.debug("event=\(eventName, privacy: .public) \(propertySummary, privacy: .private)")
    }

    /// Failures are logged at error level with public fields: debug lines are dropped by the
    /// unified log and private fields render as <private>, which made "see the error" unanswerable
    /// after the fact. Callers pass stable labels or error descriptions, never user content.
    private static func recordProblem(_ eventName: String, properties: [String: String] = [:]) {
        let propertySummary = properties.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        logger.error("event=\(eventName, privacy: .public) \(propertySummary, privacy: .public)")
    }

    /// A few events are worth keeping without being failures (a usage report leaving the Mac, a
    /// preference changing hands). Notice level is persisted by the unified log, debug is not.
    private static func recordMilestone(_ eventName: String, properties: [String: String] = [:]) {
        let propertySummary = properties.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        logger.notice("event=\(eventName, privacy: .public) \(propertySummary, privacy: .public)")
    }

    // MARK: - Setup

    static func configure() {
        // Nothing to configure: no third-party analytics SDK is loaded.
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        record("app_opened", properties: ["app_version": version])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        record("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        record("onboarding_replayed")
    }

    /// The onboarding hand-off finished.
    static func trackOnboardingVideoCompleted() {
        record("onboarding_completed")
    }

    /// The onboarding demo interaction where Wingman points at something.
    static func trackOnboardingDemoTriggered() {
        record("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All permissions (accessibility, screen recording, mic, screen content) are granted.
    static func trackAllPermissionsGranted() {
        record("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        record("permission_granted", properties: ["permission": permission])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        record("push_to_talk_started")
    }

    /// User released the shortcut; the transcript is being finalized.
    static func trackPushToTalkReleased() {
        record("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the model.
    /// Only the length is logged; the transcript itself never leaves the pipeline.
    static func trackUserMessageSent(transcript: String) {
        record("user_message_sent", properties: ["character_count": String(transcript.count)])
    }

    /// The model responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        record("ai_response_received", properties: ["character_count": String(response.count)])
    }

    /// The response included a [POINT:x,y:label] coordinate tag,
    /// so the cursor is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        record("element_pointed", properties: ["element_label": elementLabel ?? "unknown"])
    }

    // MARK: - Tools

    /// The model asked for a gateway tool and the app-side policy let it through.
    static func trackToolCalled(toolName: String) {
        record("tool_called", properties: ["tool": toolName])
    }

    /// The app refused a tool call before the gateway (not on the allow-list, bad arguments).
    static func trackToolRefused(toolName: String, reason: String) {
        recordProblem("tool_refused", properties: ["tool": toolName, "reason": reason])
    }

    /// The gateway refused or failed a tool call; `outcome` is a stable label, never the payload.
    static func trackToolFailed(toolName: String, outcome: String) {
        recordProblem("tool_failed", properties: ["tool": toolName, "outcome": outcome])
    }

    /// The answer is being read from a knowledge base article; `url` is the ForIT Support page the
    /// answer cites (decision 012). Public, so `log show` can prove which article was cited: the
    /// page address is a support link, never user content.
    static func trackKnowledgeBaseArticleCited(url: String) {
        recordMilestone("kb_article_cited", properties: ["url": url])
    }

    // MARK: - Usage sharing

    /// One turn's usage report reached the relay; `stored` is what the relay said it did with it.
    static func trackUsageReportSent(stored: Bool) {
        recordMilestone("usage_report_sent", properties: ["stored": String(stored)])
    }

    /// The report could not be delivered. It is dropped, never retried.
    static func trackUsageReportFailed(error: String) {
        recordProblem("usage_report_failed", properties: ["error": error])
    }

    /// The person flipped the "Share usage with ForIT" switch in the panel.
    static func trackUsageSharingChanged(enabled: Bool) {
        recordMilestone("usage_sharing_changed", properties: ["enabled": String(enabled)])
    }

    // MARK: - Sign-in

    /// The user completed an interactive ForIT sign-in. No account details are recorded.
    static func trackSignedIn() {
        record("signed_in")
    }

    // MARK: - Errors

    /// An error occurred during the model response pipeline.
    static func trackResponseError(error: String) {
        recordProblem("response_error", properties: ["error": error])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        recordProblem("tts_error", properties: ["error": error])
    }
}
