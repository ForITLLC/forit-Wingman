//
//  WingmanUpdaterDelegate.swift
//  Wingman
//
//  Sparkle's updater delegate, with two jobs a menu bar app needs and Sparkle's defaults do not do:
//
//  1. A background check that fails on the network is retried five minutes later rather than at the
//     next hourly check (decision 019). Sparkle records the check time even when the appcast could
//     not be fetched, so a check that lands in a network blip otherwise costs an hour. Seen on Ben's
//     MacBook on 2026-09-05: the 22:08Z check got "The Internet connection appears to be offline"
//     while Tailscale was restarting.
//
//  2. A downloaded update is installed as soon as Wingman is idle, not at the next quit (decision
//     020). Sparkle's silent update waits for the app to terminate, and a menu bar app is never
//     quit: Ben's MacBook downloaded 0.1.86 at 23:08Z on 2026-09-05 and was still running 0.1.68 an
//     hour later ("I still have a model selector. So you haven't managed to get this to my MacBook").
//

import Foundation
import Sparkle

enum WingmanUpdateCheckRetry {
    /// How long after a background check failed on the network the next one runs.
    static let delayAfterNetworkFailure: TimeInterval = 5 * 60

    /// Sparkle's `SUSparkleErrorDomain` codes for a feed it could not fetch (`SUAppcastError`) and
    /// a download that failed (`SUDownloadError`), from Sparkle's SUErrors.h. "No update
    /// available" is 1001 in the same domain and is not a failure.
    static let sparkleAppcastErrorCode = 1000
    static let sparkleDownloadErrorCode = 2001

    /// Whether a failed check is worth asking again about soon: the feed or the download failed,
    /// or whatever is underneath was a URL loading error (offline, DNS, timeout). Anything else (a
    /// bad signature, an installation problem, no update) is not fixed by asking again.
    static func isWorthRetryingSoon(errorDomain: String, errorCode: Int, underlyingErrorDomain: String?) -> Bool {
        if errorDomain == NSURLErrorDomain || underlyingErrorDomain == NSURLErrorDomain {
            return true
        }
        return errorDomain == SUSparkleErrorDomain
            && (errorCode == sparkleAppcastErrorCode || errorCode == sparkleDownloadErrorCode)
    }

    static func isWorthRetryingSoon(after error: Error) -> Bool {
        let failure = error as NSError
        let underlyingFailure = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        return isWorthRetryingSoon(
            errorDomain: failure.domain,
            errorCode: failure.code,
            underlyingErrorDomain: underlyingFailure?.domain
        )
    }
}

enum WingmanIdleUpdateInstall {
    /// How often a staged update asks again whether Wingman has gone idle.
    static let pollInterval: TimeInterval = 15

    /// Whether a downloaded update can be installed and the app relaunched right now without
    /// cutting anything off: no push-to-talk turn is under way (listening, thinking or speaking),
    /// no sign-in is waiting on the browser, and no voice quit is pending (that quit installs the
    /// update on its own, the way Sparkle always did).
    static func isSafeToInstallNow(
        voiceState: CompanionVoiceState,
        signInState: WingmanSignInState,
        quitPendingByVoice: Bool
    ) -> Bool {
        guard voiceState == .idle else { return false }
        guard signInState != .signingIn else { return false }
        return !quitPendingByVoice
    }
}

/// The updater delegate. Sparkle calls it on the main thread and holds it weakly, so the app
/// delegate keeps it alive.
final class WingmanUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Answers whether the app is idle enough to be replaced and relaunched this instant. The app
    /// delegate sets it from `CompanionManager`'s state; until then nothing is ever idle, so a
    /// staged update waits rather than relaunching an app whose state it cannot see.
    var isSafeToInstallUpdateNow: @MainActor () -> Bool = { false }

    private var pendingRetry: DispatchWorkItem?

    // MARK: Retry after a network failure (decision 019)

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard updateCheck == .updatesInBackground,
              let error,
              WingmanUpdateCheckRetry.isWorthRetryingSoon(after: error) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRetry(on: updater)
        }
    }

    private func scheduleRetry(on updater: SPUUpdater) {
        guard pendingRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self, weak updater] in
            self?.pendingRetry = nil
            updater?.checkForUpdatesInBackground()
        }
        pendingRetry = retry
        WingmanAnalytics.trackUpdateCheckRetryScheduled(delaySeconds: Int(WingmanUpdateCheckRetry.delayAfterNetworkFailure))
        DispatchQueue.main.asyncAfter(deadline: .now() + WingmanUpdateCheckRetry.delayAfterNetworkFailure, execute: retry)
    }

    // MARK: Install while idle (decision 020)

    /// Sparkle has downloaded and staged an update and would install it at the next quit. Taking
    /// it over: the update goes in, with no UI and a relaunch, the first moment Wingman is idle.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let stagedVersion = item.displayVersionString
        Task { @MainActor [weak self] in
            while let self, !self.isSafeToInstallUpdateNow() {
                try? await Task.sleep(for: .seconds(WingmanIdleUpdateInstall.pollInterval))
            }
            WingmanAnalytics.trackUpdateInstalledWhileIdle(version: stagedVersion)
            immediateInstallHandler()
        }
        return true
    }
}
