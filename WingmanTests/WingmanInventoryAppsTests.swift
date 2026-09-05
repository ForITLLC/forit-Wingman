//
//  WingmanInventoryAppsTests.swift
//  WingmanTests
//
//  Covers the inventory apps: the parsing of ForIT Support's list (only active rows with a usable
//  url survive), the grouping and the prompt section, and the store's persistence.
//

import Foundation
import Testing
@testable import Wingman

struct WingmanInventoryAppsTests {
    private let sampleResultText = """
    {"apps": [
      {"id": "a1", "name": "AVHR", "status": "active", "tenant_name": "XcelJet", "category": "HR", "url": "https://avhr.xceljet.com"},
      {"id": "a2", "name": "ForIT Support", "status": "active", "tenant_name": null, "url": "support.forit.io"},
      {"id": "a3", "name": "Old Portal", "status": "retired", "tenant_name": "XcelJet", "url": "https://old.xceljet.com"},
      {"id": "a4", "name": "No Address Yet", "status": "active", "tenant_name": "Great North", "url": null},
      {"id": 5, "name": "Crew Site", "status": "active", "tenant_name": "Great North", "url": "ftp://crew.greatnorthairlines.com"},
      {"id": "a6", "name": "AVHR", "status": "active", "tenant_name": "Great North", "url": "https://avhr.greatnorthairlines.com"},
      {"id": "a7", "name": "", "status": "active", "url": "https://nameless.example.com"}
    ]}
    """

    @Test func onlyActiveRowsWithAWebAddressSurvive() throws {
        let apps = try #require(WingmanInventoryApps.apps(fromForITSupportResultText: sampleResultText))
        #expect(apps.map(\.id) == ["a1", "a2", "a6"])
        #expect(apps[1].url.absoluteString == "https://support.forit.io")
        #expect(apps[1].tenantName == nil)
        #expect(apps[1].ownerLabel == "ForIT")
        #expect(apps[0].category == "HR")
    }

    @Test func aTopLevelListAndADataWrapperAreAccepted() {
        let listText = "[{\"id\": \"x\", \"name\": \"Site\", \"url\": \"https://x.example.com\"}]"
        #expect(WingmanInventoryApps.apps(fromForITSupportResultText: listText)?.count == 1)
        let dataText = "{\"data\": [{\"id\": \"x\", \"name\": \"Site\", \"url\": \"https://x.example.com\"}]}"
        #expect(WingmanInventoryApps.apps(fromForITSupportResultText: dataText)?.count == 1)
    }

    /// The shape for-Support ships since WO#1979 (2026-09-05): a row carries `hostnames`,
    /// `no_url_reason`, `tenant_slug`, `vendor` and `source` beside the fields Wingman reads, the
    /// list carries `count` and `synced_at`, and ForIT's own apps name "ForIT" as their tenant.
    /// Two of the seventeen live rows had `url` null with a reason; they are left out, not errors.
    private let liveResultTextFromForITSupport = """
    {"apps": [
      {"id": "E4A073F7-E854-4FF4-A79B-94F320F5B154", "name": "Microsoft 365 Business Premium", "category": "Productivity", "status": "active", "vendor": "Microsoft", "source": "manual", "url": "https://m365.cloud.microsoft/", "hostnames": ["m365.cloud.microsoft", "www.office.com"], "no_url_reason": null, "tenant_slug": "forit", "tenant_name": "ForIT", "updated_at": "2026-09-05T22:09:28.230Z"},
      {"id": "FAF1B262-E7C8-44CB-B264-99FCACBD27A4", "name": "Network", "category": "Network", "status": "active", "vendor": "IT Pilots", "source": "manual", "url": null, "hostnames": [], "no_url_reason": "Category row for the IT Pilots managed network (triage routing), not an application. No front door.", "tenant_slug": "great-north", "tenant_name": "Great North Airlines", "updated_at": "2026-09-05T22:09:28.230Z"},
      {"id": "1C78C562-90BE-46FC-A967-F94388AE2C5F", "name": "VMO", "category": "Operations", "status": "active", "vendor": "VMO Aviation Software", "source": "manual", "url": "https://vmo.aero/", "hostnames": ["vmo.aero", "api.ggn.vmo.cloud"], "no_url_reason": null, "tenant_slug": "great-north", "tenant_name": "Great North Airlines", "updated_at": "2026-09-05T22:09:28.230Z"}
    ], "count": 3, "synced_at": "2026-09-05T22:15:04.684Z"}
    """

    @Test func theShapeForITSupportShipsParsesAndIgnoresTheFieldsWingmanDoesNotUse() throws {
        let apps = try #require(WingmanInventoryApps.apps(fromForITSupportResultText: liveResultTextFromForITSupport))
        #expect(apps.map(\.name) == ["Microsoft 365 Business Premium", "VMO"])
        #expect(apps[0].ownerLabel == "ForIT")
        #expect(apps[0].url.absoluteString == "https://m365.cloud.microsoft/")
        #expect(apps[1].tenantName == "Great North Airlines")
        #expect(apps[1].category == "Operations")
        let groups = WingmanInventoryApps.groupedByOwner(apps)
        #expect(groups.map(\.owner) == ["ForIT", "Great North Airlines"])
    }

    @Test func textThatIsNotTheRouteShapeIsNil() {
        #expect(WingmanInventoryApps.apps(fromForITSupportResultText: "HTTP 401 from upstream") == nil)
        #expect(WingmanInventoryApps.apps(fromForITSupportResultText: "{\"error\": \"nope\"}") == nil)
        #expect(WingmanInventoryApps.apps(fromForITSupportResultText: "{\"apps\": []}") == [])
    }

    @Test func groupsPutForITFirstThenClientsAlphabetically() throws {
        let apps = try #require(WingmanInventoryApps.apps(fromForITSupportResultText: sampleResultText))
        let groups = WingmanInventoryApps.groupedByOwner(apps)
        #expect(groups.map(\.owner) == ["ForIT", "Great North", "XcelJet"])
        #expect(groups[1].apps.map(\.name) == ["AVHR"])
    }

    @Test func promptSectionNamesEachSiteWithItsOwnerAndAddress() throws {
        let apps = try #require(WingmanInventoryApps.apps(fromForITSupportResultText: sampleResultText))
        let section = WingmanInventoryApps.systemPromptSection(apps: apps)
        #expect(section.contains("ForIT Support (ForIT) https://support.forit.io"))
        #expect(section.contains("AVHR (XcelJet) https://avhr.xceljet.com"))
        #expect(section.contains("open_on_this_mac"))
        #expect(WingmanInventoryApps.systemPromptSection(apps: []).isEmpty)
    }

    @Test func promptSectionIsCapped() {
        let manyApps = (1...130).map { index in
            WingmanInventoryApp(id: "\(index)", name: "Site \(index)", tenantName: nil, category: nil, url: URL(string: "https://site\(index).example.com")!)
        }
        let section = WingmanInventoryApps.systemPromptSection(apps: manyApps)
        #expect(section.hasSuffix("; and 30 more"))
    }

    @Test @MainActor func storeStartsEmptyRoundTripsAndKeepsAnEmptyList() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WingmanInventoryAppsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("inventory-apps.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let emptyStore = WingmanInventoryAppStore(inventoryAppsFileURL: fileURL)
        #expect(emptyStore.apps.isEmpty)
        #expect(emptyStore.isDueForRefresh(maximumAge: 3600))

        let apps = try #require(WingmanInventoryApps.apps(fromForITSupportResultText: sampleResultText))
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        emptyStore.replaceWithAppsFromForITSupport(apps, fetchedAt: fetchedAt)
        #expect(!emptyStore.isDueForRefresh(maximumAge: 3600, now: fetchedAt.addingTimeInterval(600)))
        #expect(emptyStore.isDueForRefresh(maximumAge: 3600, now: fetchedAt.addingTimeInterval(3600)))

        let reloadedStore = WingmanInventoryAppStore(inventoryAppsFileURL: fileURL)
        #expect(reloadedStore.apps == apps)
        #expect(reloadedStore.fetchedAt == fetchedAt)

        reloadedStore.replaceWithAppsFromForITSupport([], fetchedAt: fetchedAt.addingTimeInterval(7200))
        let reloadedAgain = WingmanInventoryAppStore(inventoryAppsFileURL: fileURL)
        #expect(reloadedAgain.apps.isEmpty)
        #expect(reloadedAgain.fetchedAt == fetchedAt.addingTimeInterval(7200))
    }
}
