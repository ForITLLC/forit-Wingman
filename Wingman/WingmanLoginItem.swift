//
//  WingmanLoginItem.swift
//  Wingman
//
//  "Open at Login" (decision 017). Ben, 2026-09-05: "if they press the key while wingman's not
//  open, can that restart it?" Nothing can: a quit app has no process to hear the key. The nearest
//  thing is to make sure Wingman is running whenever the Mac is, so the app registers itself as a
//  login item at launch unless the person switched that off in the panel. macOS also lists it
//  under System Settings > General > Login Items, where it can be turned off as well.
//

import Combine
import Foundation
import ServiceManagement

/// The "Open at Login" switch, persisted in UserDefaults (missing = on) and applied through
/// `SMAppService`. The two closures exist so tests can stand in for the service.
@MainActor
final class WingmanLoginItemPreference: ObservableObject {
    static let userDefaultsKey = "opensAtLogin"
    static let switchLabel = "Open at Login"

    @Published private(set) var isEnabled: Bool

    private let userDefaults: UserDefaults
    private let registerLoginItem: () throws -> Void
    private let unregisterLoginItem: () throws -> Void

    init(
        userDefaults: UserDefaults = .standard,
        registerLoginItem: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregisterLoginItem: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.userDefaults = userDefaults
        self.registerLoginItem = registerLoginItem
        self.unregisterLoginItem = unregisterLoginItem
        // Missing means on: every Mac that had Wingman before the switch existed was already
        // registered at each launch, and a fresh install should be too.
        isEnabled = userDefaults.object(forKey: Self.userDefaultsKey) as? Bool ?? true
    }

    /// Registers the login item at launch when the switch is on and macOS does not have it yet.
    /// A switch that is off registers nothing, and nothing is ever unregistered here: a person
    /// who turned Wingman off in System Settings keeps that choice until they use the panel.
    func registerAtLaunchIfWanted(isAlreadyRegistered: Bool = SMAppService.mainApp.status == .enabled) {
        guard isEnabled, !isAlreadyRegistered else { return }
        do {
            try registerLoginItem()
            print("🎯 Wingman: Registered as login item")
        } catch {
            print("⚠️ Wingman: Failed to register as login item: \(error)")
        }
    }

    /// The panel switch. The service is updated first, so a failure leaves the switch where it
    /// was instead of showing a state macOS does not have.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try registerLoginItem()
            } else {
                try unregisterLoginItem()
            }
        } catch {
            print("⚠️ Wingman: Could not \(enabled ? "register" : "unregister") the login item: \(error)")
            return
        }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.userDefaultsKey)
    }
}
