//
//  WingmanUpdaterDelegateTests.swift
//  WingmanTests
//
//  Covers the two pure rules behind the updater delegate: which failed update checks are retried
//  soon (decision 019), and when a staged update may be installed with a relaunch (decision 020).
//

import Foundation
import Testing
@testable import Wingman

struct WingmanUpdateRetryTests {
    /// The failure seen on Ben's MacBook on 2026-09-05 22:08Z, as Sparkle logged it.
    private let offlineFeedFailure = NSError(
        domain: "SUSparkleErrorDomain",
        code: 2001,
        userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while downloading the update. Please try again later.",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ]
    )

    @Test func anOfflineFeedFetchIsRetriedSoon() {
        #expect(WingmanUpdateCheckRetry.isWorthRetryingSoon(after: offlineFeedFailure))
    }

    @Test func aFeedOrDownloadFailureIsRetriedEvenWithoutAnUnderlyingError() {
        #expect(WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: "SUSparkleErrorDomain", errorCode: 1000, underlyingErrorDomain: nil))
        #expect(WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: "SUSparkleErrorDomain", errorCode: 2001, underlyingErrorDomain: nil))
        #expect(WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: NSURLErrorDomain, errorCode: NSURLErrorTimedOut, underlyingErrorDomain: nil))
    }

    @Test func noUpdateAndInstallationProblemsAreNotRetried() {
        // 1001 is SUNoUpdateError: the check worked and there was nothing new.
        #expect(!WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: "SUSparkleErrorDomain", errorCode: 1001, underlyingErrorDomain: nil))
        // 3000 is SUInstallationError: asking the feed again does not help.
        #expect(!WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: "SUSparkleErrorDomain", errorCode: 3000, underlyingErrorDomain: nil))
        #expect(!WingmanUpdateCheckRetry.isWorthRetryingSoon(errorDomain: NSCocoaErrorDomain, errorCode: 4, underlyingErrorDomain: nil))
        let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: 1001)
        #expect(!WingmanUpdateCheckRetry.isWorthRetryingSoon(after: noUpdate))
    }

    @Test func theRetryWaitsMinutesNotAnHour() {
        #expect(WingmanUpdateCheckRetry.delayAfterNetworkFailure == 300)
    }
}

struct WingmanIdleUpdateInstallTests {
    private let signedIn = WingmanSignInState.signedIn(WingmanSignedInAccount(displayName: "Ben Thomas", emailAddress: "b.thomas@forit.io"))

    @Test func anIdleSignedInAppInstallsNow() {
        #expect(WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .idle, signInState: signedIn, quitPendingByVoice: false))
        #expect(WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .idle, signInState: .signedOut, quitPendingByVoice: false))
    }

    @Test func aTurnInProgressWaits() {
        #expect(!WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .listening, signInState: signedIn, quitPendingByVoice: false))
        #expect(!WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .processing, signInState: signedIn, quitPendingByVoice: false))
        #expect(!WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .responding, signInState: signedIn, quitPendingByVoice: false))
    }

    @Test func aSignInWaitingOnTheBrowserWaits() {
        #expect(!WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .idle, signInState: .signingIn, quitPendingByVoice: false))
    }

    @Test func aPendingVoiceQuitLeavesTheInstallToThatQuit() {
        #expect(!WingmanIdleUpdateInstall.isSafeToInstallNow(voiceState: .idle, signInState: signedIn, quitPendingByVoice: true))
    }

    @Test func theIdleCheckRepeatsEveryFifteenSeconds() {
        #expect(WingmanIdleUpdateInstall.pollInterval == 15)
    }
}
