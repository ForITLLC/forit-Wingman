//
//  WingmanLauncherTests.swift
//  WingmanTests
//
//  Covers the launcher's pure parts: which web addresses it will open, how a spoken application
//  name finds an installed application, the scan of an Applications folder, the tool input
//  parsing and the system prompt section. Opening itself goes through NSWorkspace and is not
//  exercised here.
//

import Foundation
import Testing
@testable import Wingman

struct WingmanLauncherTests {
    private func installed(_ displayName: String, folderName: String? = nil) -> WingmanInstalledApplication {
        WingmanInstalledApplication(
            displayName: displayName,
            folderName: folderName ?? displayName,
            bundleIdentifier: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/\(folderName ?? displayName).app")
        )
    }

    private var sampleCatalog: WingmanInstalledApplicationCatalog {
        WingmanInstalledApplicationCatalog(
            applications: [
                installed("Chrome", folderName: "Google Chrome"),
                installed("Google Chrome Canary"),
                installed("Microsoft Teams"),
                installed("Safari"),
                installed("Slack"),
                installed("Visual Studio Code"),
                installed("Xcode"),
            ],
            scannedAt: Date()
        )
    }

    // MARK: Web addresses

    @Test func bareSiteNameGetsHTTPS() {
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "xceljet.com")?.absoluteString == "https://xceljet.com")
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: " support.forit.io/tickets ")?.absoluteString == "https://support.forit.io/tickets")
    }

    @Test func spokenDotBecomesADot() {
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "xceljet dot com")?.absoluteString == "https://xceljet.com")
    }

    @Test func fullHTTPAddressesAreKept() {
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "http://localhost:3000/health")?.absoluteString == "http://localhost:3000/health")
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "HTTPS://Support.forit.io")?.host == "Support.forit.io")
    }

    @Test func onlyWebSchemesAreOpened() {
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "file:///etc/passwd") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "ftp://files.example.com") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "javascript:alert(1)") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "mailto:someone@example.com") == nil)
    }

    @Test func addressesWithSignInDetailsOrNoRealHostAreRefused() {
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "https://user:secret@example.com") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "the forit support site") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "intranet") == nil)
        #expect(WingmanLauncher.websiteURL(fromSpokenAddress: "") == nil)
    }

    // MARK: Matching an installed application

    @Test func exactNameMatchesRegardlessOfCaseAndSuffix() {
        #expect(sampleCatalog.application(matchingSpokenName: "slack")?.displayName == "Slack")
        #expect(sampleCatalog.application(matchingSpokenName: "Slack.app")?.displayName == "Slack")
        #expect(sampleCatalog.application(matchingSpokenName: "XCODE")?.displayName == "Xcode")
    }

    @Test func folderNameCountsAsAName() {
        #expect(sampleCatalog.application(matchingSpokenName: "google chrome")?.displayName == "Chrome")
    }

    @Test func spacesAreOptional() {
        #expect(sampleCatalog.application(matchingSpokenName: "vs code") == nil)
        #expect(sampleCatalog.application(matchingSpokenName: "visualstudiocode")?.displayName == "Visual Studio Code")
    }

    @Test func aWholeWordPicksTheShortestName() {
        #expect(sampleCatalog.application(matchingSpokenName: "chrome")?.displayName == "Chrome")
        #expect(sampleCatalog.application(matchingSpokenName: "teams")?.displayName == "Microsoft Teams")
        #expect(sampleCatalog.application(matchingSpokenName: "canary")?.displayName == "Google Chrome Canary")
    }

    @Test func aPrefixMatchesOnlyFromThreeCharacters() {
        #expect(sampleCatalog.application(matchingSpokenName: "saf")?.displayName == "Safari")
        #expect(sampleCatalog.application(matchingSpokenName: "sa") == nil)
    }

    @Test func nothingCloseGivesNilAndNoSuggestions() {
        #expect(sampleCatalog.application(matchingSpokenName: "photoshop") == nil)
        #expect(sampleCatalog.namesClose(toSpokenName: "photoshop").isEmpty)
    }

    @Test func closeNamesShareAWordOrAPrefix() {
        let closeNames = sampleCatalog.namesClose(toSpokenName: "google docs")
        #expect(closeNames.contains("Chrome"))
        #expect(closeNames.contains("Google Chrome Canary"))
        #expect(!closeNames.contains("Safari"))
    }

    // MARK: Scanning a folder

    @Test func scanFindsAppBundlesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WingmanLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Zed.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Acme Notes.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Not An App"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        defer { try? FileManager.default.removeItem(at: folder) }

        let catalog = WingmanInstalledApplicationCatalog.scan(folders: [folder])

        #expect(catalog.applications.map(\.displayName) == ["Acme Notes", "Zed"])
        #expect(catalog.applications.map(\.folderName) == ["Acme Notes", "Zed"])
        #expect(catalog.scannedAt != nil)
        #expect(catalog.application(matchingSpokenName: "zed")?.bundleURL.lastPathComponent == "Zed.app")
    }

    @Test func aMissingFolderIsSkipped() {
        let catalog = WingmanInstalledApplicationCatalog.scan(folders: [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")])
        #expect(catalog.applications.isEmpty)
        #expect(catalog.scannedAt != nil)
    }

    @Test func rescanIsDueBeforeTheFirstScanAndAfterTheMaximumAge() {
        #expect(WingmanInstalledApplicationCatalog.empty.isDueForRescan(maximumAge: 600))
        let scanned = WingmanInstalledApplicationCatalog(applications: [], scannedAt: Date(timeIntervalSinceNow: -300))
        #expect(!scanned.isDueForRescan(maximumAge: 600))
        #expect(scanned.isDueForRescan(maximumAge: 60))
    }

    // MARK: Tool input

    @Test func toolInputNamesExactlyOneTarget() {
        #expect(WingmanLauncherRequest.parse(toolInput: ["application": " Slack "]) == .application(spokenName: "Slack"))
        #expect(WingmanLauncherRequest.parse(toolInput: ["website": "xceljet.com"]) == .website(spokenAddress: "xceljet.com"))
        #expect(WingmanLauncherRequest.parse(toolInput: ["application": "Slack", "website": "xceljet.com"]) == nil)
        #expect(WingmanLauncherRequest.parse(toolInput: ["application": ""]) == nil)
        #expect(WingmanLauncherRequest.parse(toolInput: [:]) == nil)
    }

    @Test func toolDefinitionHasTheModelFacingShape() {
        let definition = WingmanLauncher.modelToolDefinition
        #expect(definition["name"] as? String == "open_on_this_mac")
        let schema = definition["input_schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?.keys.sorted() == ["application", "website"])
    }

    // MARK: Prompt section

    @Test func promptSectionListsInstalledNamesAndCapsThem() {
        let section = WingmanLauncher.systemPromptSection(installedApplications: sampleCatalog)
        #expect(section.contains("open_on_this_mac"))
        #expect(section.contains("Chrome, Google Chrome Canary, Microsoft Teams, Safari, Slack, Visual Studio Code, Xcode"))
        #expect(!section.contains("more"))

        let manyApplications = (1...250).map { installed("App \($0)") }
        let bigCatalog = WingmanInstalledApplicationCatalog(applications: manyApplications, scannedAt: Date())
        let bigSection = bigCatalog.systemPromptSection()
        #expect(bigSection.contains("App 200"))
        #expect(!bigSection.contains("App 201,"))
        #expect(bigSection.hasSuffix(", and 50 more"))
    }

    @Test func promptSectionIsSilentBeforeTheFirstScan() {
        #expect(WingmanInstalledApplicationCatalog.empty.systemPromptSection().isEmpty)
        #expect(WingmanLauncher.systemPromptSection(installedApplications: .empty).contains("opening things on this mac"))
    }
}
