//
//  WingmanLoginItemTests.swift
//  WingmanTests
//
//  Covers the "Open at Login" switch (decision 017): on by default, registered at launch only
//  when wanted and missing, the switch persisting, and a service failure leaving it unchanged.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanLoginItemTests {
    private func throwawayUserDefaults() -> UserDefaults {
        let suiteName = "io.forit.wingman.tests.loginitem.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    /// Counts the register and unregister calls a preference makes.
    @MainActor
    private final class ServiceCalls {
        var registered = 0
        var unregistered = 0
        var registerFails = false
        struct Failure: Error {}

        func preference(userDefaults: UserDefaults) -> WingmanLoginItemPreference {
            WingmanLoginItemPreference(
                userDefaults: userDefaults,
                registerLoginItem: { [self] in
                    if registerFails { throw Failure() }
                    registered += 1
                },
                unregisterLoginItem: { [self] in unregistered += 1 }
            )
        }
    }

    @Test func onByDefaultAndNothingRegisteredUntilLaunchAsksForIt() {
        let calls = ServiceCalls()
        let preference = calls.preference(userDefaults: throwawayUserDefaults())
        #expect(preference.isEnabled)
        #expect(calls.registered == 0)
    }

    @Test func launchRegistersOnlyWhenWantedAndMissing() {
        let calls = ServiceCalls()
        let preference = calls.preference(userDefaults: throwawayUserDefaults())

        preference.registerAtLaunchIfWanted(isAlreadyRegistered: true)
        #expect(calls.registered == 0)

        preference.registerAtLaunchIfWanted(isAlreadyRegistered: false)
        #expect(calls.registered == 1)

        preference.setEnabled(false)
        preference.registerAtLaunchIfWanted(isAlreadyRegistered: false)
        #expect(calls.registered == 1)
        #expect(calls.unregistered == 1)
    }

    @Test func theSwitchPersistsAcrossInstances() {
        let userDefaults = throwawayUserDefaults()
        let calls = ServiceCalls()
        calls.preference(userDefaults: userDefaults).setEnabled(false)

        let reopened = calls.preference(userDefaults: userDefaults)
        #expect(!reopened.isEnabled)

        reopened.setEnabled(true)
        #expect(calls.registered == 1)
        #expect(calls.preference(userDefaults: userDefaults).isEnabled)
    }

    @Test func aServiceFailureLeavesTheSwitchWhereItWas() {
        let userDefaults = throwawayUserDefaults()
        let calls = ServiceCalls()
        let preference = calls.preference(userDefaults: userDefaults)
        preference.setEnabled(false)

        calls.registerFails = true
        preference.setEnabled(true)
        #expect(!preference.isEnabled)
        #expect(userDefaults.object(forKey: WingmanLoginItemPreference.userDefaultsKey) as? Bool == false)
    }
}
