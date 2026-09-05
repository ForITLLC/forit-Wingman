//
//  WingmanApp.swift
//  Wingman
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import SwiftUI
import Sparkle

@main
struct WingmanApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Wingman: Starting...")
        print("🎯 Wingman: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        WingmanAnalytics.configure()
        WingmanAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something: they haven't onboarded
        // yet, permissions were revoked, or they have not yet seen the usage sharing notice
        // (a Mac that onboarded before usage sharing existed sees it once, with a "Got it").
        if !companionManager.hasCompletedOnboarding
            || !companionManager.allPermissionsGranted
            || !companionManager.usageSharingPreference.hasAcknowledgedNotice {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        companionManager.loginItemPreference.registerAtLaunchIfWanted()
        startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Wingman: Sparkle updater failed to start: \(error)")
        }
    }
}
