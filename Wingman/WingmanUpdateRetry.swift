//
//  WingmanUpdateRetry.swift
//  Wingman
//
//  A background update check that fails on the network is retried a few minutes later rather
//  than at the next hourly check (decision 019). Sparkle records the check time even when the
//  appcast could not be fetched, so a check that lands in a network blip otherwise costs an hour
//  before Wingman looks again. Seen on Ben's MacBook on 2026-09-05: the 22:08Z check got "The
//  Internet connection appears to be offline" while Tailscale was restarting, and 0.1.78, in the
//  appcast since 22:06Z, was not fetched until the next check.
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

/// Sparkle's updater delegate: after a background check fails on the network, asks Sparkle to
/// check again in five minutes. At most one retry is pending; a retry that fails again schedules
/// the next, so an outage of hours costs one small request every five minutes. Sparkle calls its
/// delegate on the main thread and the pending item is only touched there.
final class WingmanUpdateCheckRetryDelegate: NSObject, SPUUpdaterDelegate {
    private var pendingRetry: DispatchWorkItem?

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
}
