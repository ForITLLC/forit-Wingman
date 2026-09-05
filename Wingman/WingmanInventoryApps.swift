//
//  WingmanInventoryApps.swift
//  Wingman
//
//  The ForIT and client sites Wingman can open: the active apps in the ForIT Support inventory
//  that carry a url (proposal `docs/common-proposed/for-support-inventory-app-url.md`, for-Support
//  WO#1979). `CompanionManager` fetches the list through the gateway tool `support_listInventoryApps`
//  after sign-in and hourly, never on a spoken turn's critical path and never described to the
//  model; the panel's Apps section lists them with an Open button, and the model gets them in the
//  system prompt so "open the XcelJet AVHR site" becomes an `open_on_this_mac` call with that url.
//  An app without a url is left out: there is nothing to open. Wingman keeps no other copy of the
//  inventory and writes nothing to it.
//

import Foundation

/// One inventory app that can be opened.
struct WingmanInventoryApp: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// The client the app belongs to; nil for ForIT's own apps.
    let tenantName: String?
    let category: String?
    let url: URL

    /// Who the app is for, as the panel groups it and the model is told.
    var ownerLabel: String {
        tenantName ?? "ForIT"
    }
}

/// The apps of one owner (ForIT or a client), as the panel lists them.
struct WingmanInventoryAppGroup: Identifiable, Equatable {
    let owner: String
    let apps: [WingmanInventoryApp]
    var id: String { owner }
}

enum WingmanInventoryApps {
    static let foritSupportToolName = "support_listInventoryApps"
    /// Only active apps are offered; the launcher never opens a retired or pending one.
    static let toolArguments: [String: Any] = ["status": "active"]
    /// The system prompt lists this many at most.
    static let maximumAppsInPrompt = 100

    /// The apps in a `support_listInventoryApps` result that have a url. nil when the text is not
    /// the route's shape at all (the gateway's error text, say), so a bad answer is logged rather
    /// than emptying the list. Rows without a usable http(s) url are skipped; a row with a status
    /// other than active is skipped too, in case the filter was ignored.
    static func apps(fromForITSupportResultText resultText: String) -> [WingmanInventoryApp]? {
        guard let resultData = resultText.data(using: .utf8),
              let resultObject = try? JSONSerialization.jsonObject(with: resultData) else {
            return nil
        }
        let appObjects: [[String: Any]]
        if let topLevelList = resultObject as? [[String: Any]] {
            appObjects = topLevelList
        } else if let container = resultObject as? [String: Any],
                  let listedApps = (container["apps"] ?? container["data"] ?? container["items"]) as? [[String: Any]] {
            appObjects = listedApps
        } else {
            return nil
        }

        var apps: [WingmanInventoryApp] = []
        for appObject in appObjects {
            let name = trimmed(appObject["name"] as? String)
            guard let name else { continue }
            if let status = trimmed(appObject["status"] as? String), status.lowercased() != "active" {
                continue
            }
            guard let urlText = trimmed(appObject["url"] as? String),
                  let url = WingmanLauncher.websiteURL(fromSpokenAddress: urlText) else {
                continue
            }
            let identifier: String
            if let idText = trimmed(appObject["id"] as? String) {
                identifier = idText
            } else if let idNumber = appObject["id"] as? NSNumber {
                identifier = idNumber.stringValue
            } else {
                identifier = url.absoluteString
            }
            let tenantName = trimmed(appObject["tenant_name"] as? String)
                ?? trimmed(appObject["tenantName"] as? String)
                ?? trimmed(appObject["tenant"] as? String)
            apps.append(WingmanInventoryApp(
                id: identifier,
                name: name,
                tenantName: tenantName,
                category: trimmed(appObject["category"] as? String),
                url: url
            ))
        }
        return apps
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// ForIT's own apps first, then each client alphabetically; apps by name within a group.
    static func groupedByOwner(_ apps: [WingmanInventoryApp]) -> [WingmanInventoryAppGroup] {
        let groups = Dictionary(grouping: apps, by: \.ownerLabel)
        let orderedOwners = groups.keys.sorted { firstOwner, secondOwner in
            if firstOwner == "ForIT" { return true }
            if secondOwner == "ForIT" { return false }
            return firstOwner.localizedCaseInsensitiveCompare(secondOwner) == .orderedAscending
        }
        return orderedOwners.map { owner in
            let sortedApps = groups[owner, default: []].sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return WingmanInventoryAppGroup(owner: owner, apps: sortedApps)
        }
    }

    /// The sites for the system prompt, or an empty string when there are none.
    static func systemPromptSection(apps: [WingmanInventoryApp]) -> String {
        guard !apps.isEmpty else { return "" }
        let orderedApps = groupedByOwner(apps).flatMap(\.apps)
        let listedApps = orderedApps.prefix(maximumAppsInPrompt).map { app in
            "\(app.name) (\(app.ownerLabel)) \(app.url.absoluteString)"
        }
        var section = "\nforit and client sites from the support inventory (open one with open_on_this_mac, passing its address exactly as written here): "
        section += listedApps.joined(separator: "; ")
        let unlistedCount = orderedApps.count - listedApps.count
        if unlistedCount > 0 {
            section += "; and \(unlistedCount) more"
        }
        return section
    }
}

/// What the last fetch found, kept on disk so the panel has the list at launch.
private struct WingmanStoredInventoryApps: Codable {
    let apps: [WingmanInventoryApp]
    let fetchedAt: Date
}

/// Owns the inventory app list on this Mac. ForIT Support is the source of truth: `CompanionManager`
/// fetches it and hands it to `replaceWithAppsFromForITSupport`; nothing is added or removed here.
@MainActor
final class WingmanInventoryAppStore: ObservableObject {
    @Published private(set) var apps: [WingmanInventoryApp]
    /// When the list was last fetched; nil until the first successful fetch.
    @Published private(set) var fetchedAt: Date?

    private let inventoryAppsFileURL: URL

    /// The default file: ~/Library/Application Support/io.forit.wingman/inventory-apps.json.
    /// `nonisolated` for the same reason as the vocabulary store's default: it is evaluated as a
    /// default argument, outside the main actor, and touches no state.
    nonisolated static func defaultInventoryAppsFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory
            .appendingPathComponent("io.forit.wingman", isDirectory: true)
            .appendingPathComponent("inventory-apps.json")
    }

    init(inventoryAppsFileURL: URL = WingmanInventoryAppStore.defaultInventoryAppsFileURL()) {
        self.inventoryAppsFileURL = inventoryAppsFileURL
        if let storedApps = Self.loadStoredApps(from: inventoryAppsFileURL) {
            self.apps = storedApps.apps
            self.fetchedAt = storedApps.fetchedAt
        } else {
            self.apps = []
            self.fetchedAt = nil
        }
    }

    /// True when the list should be fetched again: never fetched, or `maximumAge` or older.
    func isDueForRefresh(maximumAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= maximumAge
    }

    /// Replaces the list with what ForIT Support returned and writes it to disk. An empty list is
    /// kept as such: unlike the vocabulary, "no active app has a url yet" is a fact worth showing
    /// (the Apps section stays hidden) rather than a reason to keep a stale list.
    func replaceWithAppsFromForITSupport(_ fetchedApps: [WingmanInventoryApp], fetchedAt: Date) {
        apps = fetchedApps
        self.fetchedAt = fetchedAt
        saveStoredApps()
    }

    private static func loadStoredApps(from fileURL: URL) -> WingmanStoredInventoryApps? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WingmanStoredInventoryApps.self, from: data)
    }

    private func saveStoredApps() {
        guard let fetchedAt else { return }
        do {
            let directoryURL = inventoryAppsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(WingmanStoredInventoryApps(apps: apps, fetchedAt: fetchedAt))
            try data.write(to: inventoryAppsFileURL, options: [.atomic])
        } catch {
            print("⚠️ Could not save the inventory apps to \(inventoryAppsFileURL.path): \(error)")
        }
    }
}
