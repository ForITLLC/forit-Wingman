//
//  CompanionManager.swift
//  Wingman
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false


    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// The user's ForIT sign-in. Every relay call carries its id_token; without a signed-in
    /// account nothing is captured or sent (push-to-talk is refused in handleShortcutTransition).
    let signInManager = WingmanEntraSignInManager()

    /// The terms the user has taught Wingman (FL3XX said as "Flex", and whatever they add in the
    /// panel). Applied on this Mac to speech recognition, the transcript, the prompt and the voice.
    let vocabularyStore = WingmanVocabularyStore()

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(
            relayChatURL: WingmanServiceConfiguration.relayChatURL,
            model: selectedModel,
            bearerTokenProvider: { [signInManager] in try await signInManager.validIdToken() }
        )
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(
            relayTTSURL: WingmanServiceConfiguration.relayTTSURL,
            bearerTokenProvider: { [signInManager] in try await signInManager.validIdToken() }
        )
    }()

    /// Support and flight tools run against the for-mcp gateway with the user's own gateway
    /// token, never through the relay, so the gateway audits each call under the person's name.
    private lazy var gatewayToolClient: WingmanGatewayToolClient = {
        return WingmanGatewayToolClient(
            gatewayMCPURL: WingmanServiceConfiguration.gatewayMCPURL,
            bearerTokenProvider: { [signInManager] in try await signInManager.validGatewayAccessToken() }
        )
    }()

    /// Set when the gateway refused a tool call for this user (no gateway role, or a role below
    /// what the tool needs). Shown in the panel until the next successful turn; the spoken reply
    /// for that turn is the fixed refusal from docs/PERMISSIONS.md 4, not model text.
    @Published private(set) var gatewayAccessProblemMessage: String?

    /// How many tool rounds one spoken question may spend before the model must answer with what
    /// it has. Listing, then looking one ticket up, then drafting is three.
    private static let maximumToolRoundsPerTurn = 4

    /// What the gateway's `tools/list` exposed to the signed-in person, which account it was fetched
    /// for, and when. nil until the first successful fetch; see `toolDefinitionsForThisTurn`.
    private var gatewayExposedToolNames: Set<String>?
    private var gatewayExposedToolNamesAccountEmail: String?
    private var gatewayExposedToolNamesFetchedAt: Date?
    private static let gatewayToolListMaximumAge: TimeInterval = 15 * 60

    /// The background `tools/list` refresh started when the push-to-talk key goes down, so the
    /// turn does not wait for it after the key comes up. nil when none is running.
    private var gatewayToolListRefreshTask: Task<Void, Never>?

    /// Cuts the reply into sentences for text-to-speech while it streams. Reset for every model
    /// call; held here (not in a local) because the stream callback is @Sendable and cannot
    /// mutate a captured local.
    private var spokenSentenceSplitter = WingmanSpokenSentenceSplitter()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var vocabularyCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = WingmanServiceConfiguration.normalisedModelId(
        UserDefaults.standard.string(forKey: "selectedClaudeModel")
    )

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Wingman cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isWingmanCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isWingmanCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isWingmanCursorEnabled")

    func setWingmanCursorEnabled(_ enabled: Bool) {
        isWingmanCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isWingmanCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Wingman start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindVocabularyToSpeechRecognition()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // Pick the previous sign-in back up from the keychain-held refresh token.
        Task { await signInManager.restoreSessionIfPossible() }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isWingmanCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .wingmanDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        WingmanAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .wingmanDismissPanel, object: nil)
        WingmanAnalytics.trackOnboardingReplayed()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            WingmanAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            WingmanAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            WingmanAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            WingmanAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    WingmanAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isWingmanCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Nothing is captured or sent without a signed-in ForIT account. The relay would
            // refuse the call anyway; refusing here keeps the microphone and screen untouched
            // and opens the panel so the user sees the sign-in row.
            guard signInManager.isSignedIn else {
                NotificationCenter.default.post(name: .wingmanShowPanel, object: nil)
                return
            }

            // The user is about to speak for a few seconds: use that time to wake the relay's
            // worker and to refresh the gateway tool list if it is stale, so neither sits on
            // the critical path once the key comes up.
            claudeAPI.warmUpRelay()
            refreshGatewayToolListIfStale()

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isWingmanCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .wingmanDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            WingmanAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        // Spoken forms become the canonical spelling ("Flex" -> "FL3XX") before the
                        // model, the knowledge base or a tool sees the words.
                        let canonicalTranscript = self.vocabularyStore.vocabulary.canonicalisingSpokenForms(in: finalTranscript)
                        self.lastTranscript = canonicalTranscript
                        print("🗣️ Companion received transcript: \(canonicalTranscript)")
                        WingmanAnalytics.trackUserMessageSent(transcript: canonicalTranscript)
                        self.sendTranscriptToClaudeWithScreenshot(transcript: canonicalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            WingmanAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Vocabulary

    /// Keeps Apple Speech's contextual keyterms in step with the taught vocabulary, so a term the
    /// user adds in the panel is favoured by the recogniser on the very next push-to-talk.
    private func bindVocabularyToSpeechRecognition() {
        vocabularyCancellable = vocabularyStore.$vocabulary
            .receive(on: DispatchQueue.main)
            .sink { [weak self] vocabulary in
                self?.buddyDictationManager.updateContextualKeyterms(vocabulary.transcriptionKeyterms())
            }
    }

    /// The system prompt for this turn: the fixed companion prompt plus the taught vocabulary.
    private var voiceSystemPromptForThisTurn: String {
        Self.companionVoiceResponseSystemPrompt + vocabularyStore.vocabulary.systemPromptSection()
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're wingman, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    forit support:
    you also work the forit help desk alongside the signed-in staff member, and you have a handful of tools. they are the only way you know anything about tickets, flights or how a supported system works: never guess a ticket, a status, a summary, a flight or a procedure from memory or from the screenshot alone when a tool can answer.
    - support_listTickets lists tickets. filter by tenant slug for a client (forit, gna, wma and so on), status "active" for open work, or search by ticket number. ticket numbers look like "FI-000227"; the user will usually say just the digits ("two twenty seven"), so search those digits and pick the ticket whose number ends with them. search also matches subject words, so ignore hits whose number doesn't match.
    - support_addTicketNote saves a draft reply on a ticket as an internal note. use it when the user asks you to draft a reply or a response. write the reply itself as the content, addressed to the requester, in a professional tone and normal capitalisation (this is written, not spoken). the app marks it "DRAFT (Wingman):" and it is never sent; afterwards tell the user the draft is on the ticket as an internal note for them to review and send.
    - forit_avops_search_flights answers any flight question for the airline ops tenant: today's schedule, delays, cancellations, a specific flight or airport.
    - support_searchKbArticles searches the forit knowledge base, which holds the fl3xx articles (fl3xx is the flight operations and scheduling platform forit supports) and forit's own how-tos. any "how do i", "where is", "why does" or setup question about fl3xx or another supported system starts here, then support_getKbArticle reads the best match in full. answer from the article in your own words, name the article so they can open it, and keep to the steps that matter. if nothing relevant comes back, say the knowledge base has nothing on it yet and stop there: never invent a fl3xx procedure, menu, setting or field.
    - if a tool named here is missing from your tool list, that part isn't connected yet: say so instead of answering as if you had looked.
    you cannot send replies, close, assign, delete or bulk-update tickets, or change user accounts. if asked, say the draft or the note is as far as you go and the staff member finishes it in the support portal.
    when summarising a ticket say who raised it, what it is about, its status and what is blocking it, in a sentence or two. for a list give the count and the two or three that matter most (breached or nearest sla, highest priority), not every ticket. say ticket numbers as digits, like "ticket two twenty seven". a tool error means you say what failed; never invent the answer.

    element pointing:
    you have a small light-blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                gatewayAccessProblemMessage = nil

                // Sentences are spoken while the reply streams; the spinner gives way to the
                // responding state the moment the first one starts to play.
                elevenLabsTTSClient.onQueuedPlaybackStarted = { [weak self] in
                    self?.voiceState = .responding
                }

                let fullResponseText = try await runModelTurnWithGatewayTools(
                    labeledImages: labeledImages,
                    transcript: transcript
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                // If speech already started, the state is responding, which shows the
                // triangle too, so only the spinner needs replacing.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate && voiceState == .processing {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    WingmanAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                WingmanAnalytics.trackAIResponseReceived(response: spokenText)

                // The reply was queued for speech sentence by sentence as it streamed (see
                // runModelTurnWithGatewayTools); wait here until the last sentence has played.
                do {
                    try await elevenLabsTTSClient.finishEnqueuedSpeech()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    WingmanAnalytics.trackTTSError(error: error.localizedDescription)
                    print("⚠️ ElevenLabs TTS error: \(error)")
                    speakCreditsErrorFallback()
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch let relayError as WingmanRelayError where relayError.isNotAuthorized {
                // The relay no longer accepts this sign-in: drop it locally and send the
                // user back to the panel instead of retrying with the same token.
                WingmanAnalytics.trackResponseError(error: relayError.localizedDescription)
                print("⚠️ Companion response refused by the relay: \(relayError)")
                signInManager.handleUnauthorizedResponse()
                speakSignInRequiredFallback()
                NotificationCenter.default.post(name: .wingmanShowPanel, object: nil)
            } catch let signInError as WingmanSignInError {
                WingmanAnalytics.trackResponseError(error: signInError.localizedDescription)
                print("⚠️ Companion response needs a sign-in: \(signInError)")
                speakSignInRequiredFallback()
                NotificationCenter.default.post(name: .wingmanShowPanel, object: nil)
            } catch {
                WingmanAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Gateway tool loop

    /// What one model-requested tool call came to. An access problem ends the turn with a fixed
    /// spoken refusal; anything else goes back to the model as a tool_result.
    private enum GatewayToolOutcome {
        case result(text: String, isError: Bool)
        case accessProblem(spokenReply: String, panelMessage: String)
    }

    /// Runs the model over the conversation, executing any gateway tools it asks for, until it
    /// answers in text. The history holds only spoken exchanges (transcript + reply); the tool
    /// rounds of a turn are not carried into later turns, which keeps the context small and
    /// means a stale tool result is never reasoned from twice.
    private func runModelTurnWithGatewayTools(
        labeledImages: [(data: Data, label: String)],
        transcript: String
    ) async throws -> String {
        var messages: [[String: Any]] = []
        for exchange in conversationHistory {
            messages.append(["role": "user", "content": exchange.userTranscript])
            messages.append(["role": "assistant", "content": exchange.assistantResponse])
        }
        messages.append([
            "role": "user",
            "content": ClaudeAPI.userMessageContentBlocks(images: labeledImages, userPrompt: transcript)
        ])

        let toolDefinitions = await toolDefinitionsForThisTurn()

        for _ in 0..<Self.maximumToolRoundsPerTurn {
            spokenSentenceSplitter = WingmanSpokenSentenceSplitter()
            let streamedTurn = try await claudeAPI.streamTurn(
                systemPrompt: voiceSystemPromptForThisTurn,
                messages: messages,
                tools: toolDefinitions,
                toolChoice: ["type": "auto"],
                onTextChunk: { [weak self] accumulatedText in
                    self?.enqueueSentencesReadyToSpeak(inAccumulatedText: accumulatedText)
                }
            )
            guard !Task.isCancelled else { throw CancellationError() }
            // A tool round's text ("Let me check the tickets.") is spoken too, so the user hears
            // something while the tool runs instead of a silent spinner.
            enqueueRemainingSpeech(inAccumulatedText: streamedTurn.text)
            guard streamedTurn.wantsToolCalls else {
                return streamedTurn.text
            }

            messages.append(["role": "assistant", "content": streamedTurn.assistantContentBlocks])

            var toolResultBlocks: [[String: Any]] = []
            for toolUse in streamedTurn.toolUses {
                let outcome = await executeGatewayTool(toolUse)
                guard !Task.isCancelled else { throw CancellationError() }
                switch outcome {
                case .accessProblem(let spokenReply, let panelMessage):
                    gatewayAccessProblemMessage = panelMessage
                    NotificationCenter.default.post(name: .wingmanShowPanel, object: nil)
                    // Fixed text that never streamed, so it is queued for speech here.
                    elevenLabsTTSClient.enqueueSentence(spokenReply)
                    return spokenReply + " [POINT:none]"
                case .result(let text, let isError):
                    toolResultBlocks.append([
                        "type": "tool_result",
                        "tool_use_id": toolUse.id,
                        "content": text,
                        "is_error": isError
                    ])
                }
            }
            messages.append(["role": "user", "content": toolResultBlocks])
        }

        // The round cap is spent: one last turn with tools still declared (the transcript holds
        // tool blocks, which the API only accepts alongside tool definitions) but none allowed.
        spokenSentenceSplitter = WingmanSpokenSentenceSplitter()
        let finalTurn = try await claudeAPI.streamTurn(
            systemPrompt: voiceSystemPromptForThisTurn,
            messages: messages,
            tools: toolDefinitions,
            toolChoice: ["type": "none"],
            onTextChunk: { [weak self] accumulatedText in
                self?.enqueueSentencesReadyToSpeak(inAccumulatedText: accumulatedText)
            }
        )
        guard !Task.isCancelled else { throw CancellationError() }
        enqueueRemainingSpeech(inAccumulatedText: finalTurn.text)
        return finalTurn.text
    }

    /// Hands every sentence that is complete in the streamed reply so far to the speech queue.
    /// The on-screen text keeps the canonical spelling; only what is spoken is rewritten so the
    /// voice says "Flex" rather than spelling out F-L-3-X-X.
    private func enqueueSentencesReadyToSpeak(inAccumulatedText accumulatedText: String) {
        for readySentence in spokenSentenceSplitter.sentencesReady(inAccumulatedText: accumulatedText) {
            elevenLabsTTSClient.enqueueSentence(vocabularyStore.vocabulary.pronouncingCanonicalSpellings(in: readySentence))
        }
    }

    /// Hands the tail of a finished reply (text after the last sentence boundary) to the queue.
    private func enqueueRemainingSpeech(inAccumulatedText accumulatedText: String) {
        if let remainingText = spokenSentenceSplitter.flushRemaining(inAccumulatedText: accumulatedText) {
            elevenLabsTTSClient.enqueueSentence(vocabularyStore.vocabulary.pronouncingCanonicalSpellings(in: remainingText))
        }
    }

    /// The tool definitions for this turn: the catalog narrowed to what the gateway's `tools/list`
    /// exposes to the signed-in person. The list is cached per account and refreshed after
    /// `gatewayToolListMaximumAge`, so a tool for-Support ships later shows up without restarting
    /// the app. A failed `tools/list` is logged and the whole catalog is offered instead, so a
    /// gateway hiccup costs at most a "that failed" on one tool, never the spoken question.
    private func toolDefinitionsForThisTurn() async -> [[String: Any]] {
        if let refreshAlreadyRunning = gatewayToolListRefreshTask {
            // Started when the key went down; usually finished by now.
            await refreshAlreadyRunning.value
        } else if !isCachedGatewayToolListUsable {
            await fetchGatewayToolList()
        }
        return WingmanToolCatalog.modelToolDefinitions(exposedByGateway: gatewayExposedToolNames)
    }

    /// Whether the cached `tools/list` belongs to the signed-in account and is young enough.
    private var isCachedGatewayToolListUsable: Bool {
        let signedInEmail = signInManager.signedInAccount?.emailAddress
        let cachedListIsForThisAccount = gatewayExposedToolNamesAccountEmail == signedInEmail
        let cachedListIsFresh = gatewayExposedToolNamesFetchedAt.map { Date().timeIntervalSince($0) < Self.gatewayToolListMaximumAge } ?? false
        return gatewayExposedToolNames != nil && cachedListIsForThisAccount && cachedListIsFresh
    }

    /// Starts a background `tools/list` refresh when the cache is stale and none is running.
    /// Called when the push-to-talk key goes down; `toolDefinitionsForThisTurn` joins it.
    private func refreshGatewayToolListIfStale() {
        guard !isCachedGatewayToolListUsable, gatewayToolListRefreshTask == nil else { return }
        gatewayToolListRefreshTask = Task { [weak self] in
            await self?.fetchGatewayToolList()
            self?.gatewayToolListRefreshTask = nil
        }
    }

    private func fetchGatewayToolList() async {
        let signedInEmail = signInManager.signedInAccount?.emailAddress
        do {
            let exposedToolNames = try await gatewayToolClient.listToolNames()
            gatewayExposedToolNames = exposedToolNames
            gatewayExposedToolNamesAccountEmail = signedInEmail
            gatewayExposedToolNamesFetchedAt = Date()
            let hiddenToolNames = WingmanToolCatalog.tools.map(\.name).filter { !exposedToolNames.contains($0) }
            if !hiddenToolNames.isEmpty {
                print("ℹ️ Gateway does not expose \(hiddenToolNames.joined(separator: ", ")); not offered to the model")
            }
        } catch {
            print("⚠️ Gateway tools/list failed, offering the whole catalog: \(error)")
        }
    }

    /// Applies the app-side policy (allow-list, argument rewriting) and calls the gateway.
    /// Sign-in failures propagate so the caller's existing sign-in handling runs; everything else
    /// becomes an outcome the model or the fixed refusal can speak.
    private func executeGatewayTool(_ toolUse: ClaudeToolUseRequest) async -> GatewayToolOutcome {
        let preparedCall: WingmanPreparedToolCall
        do {
            preparedCall = try WingmanToolCatalog.prepareCall(
                toolName: toolUse.name,
                modelArguments: toolUse.input,
                signedInAccount: signInManager.signedInAccount,
                vocabulary: vocabularyStore.vocabulary
            )
        } catch let refusal as WingmanToolRefusal {
            WingmanAnalytics.trackToolRefused(toolName: toolUse.name, reason: refusal.modelFacingMessage)
            print("🛑 Tool refused by the app: \(refusal.modelFacingMessage)")
            return .result(text: refusal.modelFacingMessage, isError: true)
        } catch {
            return .result(text: "\(toolUse.name) was not called: \(error.localizedDescription)", isError: true)
        }

        WingmanAnalytics.trackToolCalled(toolName: preparedCall.toolName)
        print("🔧 Gateway tool: \(preparedCall.toolName) \(preparedCall.arguments.keys.sorted())")

        do {
            let toolResult = try await gatewayToolClient.callTool(named: preparedCall.toolName, arguments: preparedCall.arguments)
            let condensedText = WingmanToolCatalog.condenseResult(toolName: preparedCall.toolName, resultText: toolResult.text)
            if toolResult.isError {
                // The label carries the HTTP status the gateway reported (tool_error_http_401), never
                // the error body, so the Mac log says why a tool failed without holding any data.
                WingmanAnalytics.trackToolFailed(
                    toolName: preparedCall.toolName,
                    outcome: WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: toolResult.text)
                )
            }
            return .result(text: condensedText, isError: toolResult.isError)
        } catch let gatewayError as WingmanGatewayToolError {
            let signedInEmail = signInManager.signedInAccount?.emailAddress ?? "this account"
            switch gatewayError {
            case .accessDenied(let detail):
                WingmanAnalytics.trackToolFailed(toolName: preparedCall.toolName, outcome: "access_denied")
                print("🛑 Gateway access denied: \(detail)")
                return .accessProblem(
                    spokenReply: "I can't do that with your current access.",
                    panelMessage: "Wingman access denied for \(signedInEmail). Ask a ForIT admin for a gateway role."
                )
            case .insufficientAccess(let detail):
                WingmanAnalytics.trackToolFailed(toolName: preparedCall.toolName, outcome: "insufficient_access")
                print("🛑 Gateway needs a higher role: \(detail)")
                let requiredLevel = WingmanToolCatalog.descriptor(named: preparedCall.toolName)?.minimumAccessLevel.rawValue ?? "a higher"
                return .accessProblem(
                    spokenReply: "That needs \(requiredLevel) access.",
                    panelMessage: "\(preparedCall.toolName) needs \(requiredLevel) access on the ForIT gateway; \(signedInEmail) has less."
                )
            default:
                WingmanAnalytics.trackToolFailed(toolName: preparedCall.toolName, outcome: "gateway_error")
                print("⚠️ Gateway tool error: \(gatewayError)")
                return .result(text: "\(preparedCall.toolName) failed: \(gatewayError.localizedDescription)", isError: true)
            }
        } catch {
            WingmanAnalytics.trackToolFailed(toolName: preparedCall.toolName, outcome: "transport_error")
            print("⚠️ Gateway tool transport error: \(error)")
            return .result(text: "\(preparedCall.toolName) failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Wingman" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isWingmanCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "The Wingman service is not available right now. Please contact ForIT support."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Spoken when a request could not be made because no ForIT account is signed in or the
    /// sign-in expired. Uses the system voice so it works without the relay.
    private func speakSignInRequiredFallback() {
        let utterance = "Sign in to Wingman with your ForIT account from the menu bar, then try again."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Starts the onboarding hand-off. Upstream played a hosted intro video
    /// here; Wingman ships no hosted media, so it goes straight to the
    /// "try talking" prompt. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        showOnboardingVideo = false
        onboardingVideoOpacity = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WingmanAnalytics.trackOnboardingVideoCompleted()
            self.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're wingman, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
