//
//  WingmanUpdateRetryTests.swift
//  WingmanTests
//
//  Covers which failed update checks are retried soon (decision 019): a feed or download failure
//  and anything with a URL loading error underneath, never "no update" or an installation problem.
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
