//
//  WingmanTicketFilingTests.swift
//  WingmanTests
//
//  Covers filing a support ticket for a customer by voice (.ai/decisions.md 011): the spoken
//  consent vocabulary mirrored from for-Support, the two-call policy in the tool catalog (preview,
//  then confirm only with a held preview and a go-ahead in this turn's transcript), the tenant and
//  directory lookups, and the condensing of what for-Support answers. No network.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanTicketFilingTests {

    private let signedInAccount = WingmanSignedInAccount(displayName: "Sam Staff", emailAddress: "sam@forit.io")

    private let previewRequest: [String: Any] = [
        "tenantId": "3f2c0d1e-0000-4000-8000-000000000001",
        "requesterEmail": "Pat.Pilot@PlanetNine.example",
        "requesterName": "Pat Pilot",
        "subject": "Cannot open the crew roster",
        "description": "Since Monday the roster tab in FL3XX shows a blank page. Tried Safari and Chrome.",
        "priority": "HIGH",
    ]

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func heldPreview(ageInSeconds: TimeInterval = 30) -> WingmanPendingTicketPreview {
        WingmanPendingTicketPreview(
            confirmationToken: "tok-123",
            gatewayArguments: ["tenantId": "t-1", "subject": "Cannot open the crew roster", "source": "api"],
            previewedAt: Date().addingTimeInterval(-ageInSeconds),
            tenantName: "Planet Nine"
        )
    }

    // MARK: - Spoken consent (the mirror of for-Support's sendRailConsent.ts)

    @Test func theActionWordIsApprovalAndABareYesIsNot() {
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "go ahead") == .approve)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "Yes, create it.") == .approve)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "ship it") == .approve)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "yes") == .hold)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "sounds right") == .hold)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "") == .hold)
    }

    @Test func aNoWinsOverAGoAheadAndAQuestionIsNeverConsent() {
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "no, don't create it") == .deny)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "cancel that") == .deny)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "go ahead, it's not urgent") == .deny)
        #expect(WingmanSpokenConsent.verdict(forSpokenWords: "should I go ahead?") == .hold)
    }

    // MARK: - The three tools in the catalog

    @Test func theTicketFilingToolsAreDescribedWithTheRightAccessLevels() {
        #expect(WingmanToolCatalog.descriptor(named: "support_listTenants")?.minimumAccessLevel == .viewer)
        #expect(WingmanToolCatalog.descriptor(named: "support_listInventoryUsers")?.minimumAccessLevel == .viewer)
        #expect(WingmanToolCatalog.descriptor(named: "support_createTicket")?.minimumAccessLevel == .operatorLevel)

        let createTicketSchema = WingmanToolCatalog.descriptor(named: "support_createTicket")?.inputSchema
        let requiredKeys = createTicketSchema?["required"] as? [String]
        #expect(requiredKeys == ["tenantId", "requesterEmail", "subject", "description"])
    }

    @Test func theTenantListTakesNoArgumentsAndThePersonLookupNeedsBoth() throws {
        let tenantListCall = try WingmanToolCatalog.prepareCall(toolName: "support_listTenants", modelArguments: ["status": "active"], signedInAccount: signedInAccount)
        #expect(tenantListCall.arguments.isEmpty)

        let personCall = try WingmanToolCatalog.prepareCall(toolName: "support_listInventoryUsers", modelArguments: ["tenant": "t-1", "search": "Pat", "limit": 500], signedInAccount: signedInAccount)
        #expect(personCall.arguments.keys.sorted() == ["search", "tenant"])

        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_listInventoryUsers", modelArguments: ["tenant": "t-1"], signedInAccount: signedInAccount)
        }
    }

    // MARK: - The preview call

    @Test func thePreviewCallCarriesTheTicketWithoutATokenAndSaysWhoFiledIt() throws {
        let call = try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: previewRequest, signedInAccount: signedInAccount)
        #expect(call.arguments["tenantId"] as? String == "3f2c0d1e-0000-4000-8000-000000000001")
        let requester = call.arguments["requester"] as? [String: Any]
        #expect(requester?["email"] as? String == "pat.pilot@planetnine.example")
        #expect(requester?["displayName"] as? String == "Pat Pilot")
        #expect(call.arguments["subject"] as? String == "Cannot open the crew roster")
        #expect(call.arguments["priority"] as? String == "high")
        #expect(call.arguments["source"] as? String == "api")
        #expect(call.arguments["confirmation_token"] == nil)
        #expect(call.arguments["consent"] == nil)

        let description = try #require(call.arguments["description"] as? String)
        #expect(description.hasPrefix("Since Monday the roster tab"))
        #expect(description.hasSuffix("Filed by Sam Staff (sam@forit.io) with Wingman."))
    }

    @Test func anUnknownPriorityBecomesMediumAndTheFiledByLineIsNotDoubled() throws {
        var request = previewRequest
        request["priority"] = "asap"
        request["description"] = "Blank roster page.\n\nFiled by Sam Staff (sam@forit.io) with Wingman."
        let call = try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: request, signedInAccount: signedInAccount)
        #expect(call.arguments["priority"] as? String == "medium")
        let description = try #require(call.arguments["description"] as? String)
        #expect(description.components(separatedBy: "Filed by Sam Staff").count == 2)
    }

    @Test func aPreviewWithoutARealEmailAddressOrAClientIsRefused() {
        var missingClient = previewRequest
        missingClient.removeValue(forKey: "tenantId")
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: missingClient, signedInAccount: signedInAccount)
        }
        var guessedEmail = previewRequest
        guessedEmail["requesterEmail"] = "Pat Pilot"
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: guessedEmail, signedInAccount: signedInAccount)
        }
        #expect(WingmanToolCatalog.looksLikeEmailAddress("pat@planetnine.example"))
        #expect(!WingmanToolCatalog.looksLikeEmailAddress("@planetnine.example"))
        #expect(!WingmanToolCatalog.looksLikeEmailAddress("pat@planetnine"))
    }

    // MARK: - The confirming call

    @Test func confirmingResendsTheHeldPreviewWithTheTokenAndThePersonsWords() throws {
        var confirmRequest = previewRequest
        confirmRequest["confirm"] = true
        confirmRequest["subject"] = "A retyped subject the model changed"
        let call = try WingmanToolCatalog.prepareCall(
            toolName: "support_createTicket",
            modelArguments: confirmRequest,
            signedInAccount: signedInAccount,
            spokenTranscript: "  go ahead and create it ",
            pendingTicketPreview: heldPreview()
        )
        // The previewed arguments are what goes, never the model's retyping.
        #expect(call.arguments["subject"] as? String == "Cannot open the crew roster")
        #expect(call.arguments["tenantId"] as? String == "t-1")
        #expect(call.arguments["confirmation_token"] as? String == "tok-123")
        #expect(call.arguments["consent"] as? String == "go ahead and create it")
    }

    @Test func confirmingWithoutAHeldPreviewOrWithAStaleOneIsRefused() {
        let confirmRequest: [String: Any] = ["confirm": true]
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: confirmRequest, signedInAccount: signedInAccount, spokenTranscript: "go ahead", pendingTicketPreview: nil)
        }
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: confirmRequest, signedInAccount: signedInAccount, spokenTranscript: "go ahead", pendingTicketPreview: heldPreview(ageInSeconds: 11 * 60))
        }
    }

    @Test func confirmingNeedsTheWordsAndANoIsADecline() {
        let confirmRequest: [String: Any] = ["confirm": true]
        do {
            _ = try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: confirmRequest, signedInAccount: signedInAccount, spokenTranscript: "yes", pendingTicketPreview: heldPreview())
            Issue.record("a bare yes filed the ticket")
        } catch let refusal as WingmanToolRefusal {
            guard case .ticketFilingNotConfirmed(let reason) = refusal else {
                Issue.record("wrong refusal for a bare yes: \(refusal)")
                return
            }
            #expect(reason.contains("go ahead"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        do {
            _ = try WingmanToolCatalog.prepareCall(toolName: "support_createTicket", modelArguments: confirmRequest, signedInAccount: signedInAccount, spokenTranscript: "no, cancel it", pendingTicketPreview: heldPreview())
            Issue.record("a no filed the ticket")
        } catch let refusal as WingmanToolRefusal {
            #expect(refusal == .ticketFilingDeclined)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - What for-Support answers

    private let previewResultText = """
    {"requires_confirmation":true,"preview":{"tenantName":"Planet Nine","requester":{"email":"pat.pilot@planetnine.example","displayName":"Pat Pilot"},"subject":"Cannot open the crew roster","description":"Blank page.","priority":"high","source":"api","willEmailRequester":true},"confirmation_token":"tok-123","message":"Confirm to create."}
    """

    @Test func thePreviewIsHeldWithItsTokenAndTheModelNeverSeesTheToken() throws {
        let sentArguments: [String: Any] = ["tenantId": "t-1", "subject": "Cannot open the crew roster"]
        let preview = try #require(WingmanToolCatalog.pendingTicketPreview(fromCreateTicketResultText: previewResultText, gatewayArgumentsSent: sentArguments))
        #expect(preview.confirmationToken == "tok-123")
        #expect(preview.tenantName == "Planet Nine")
        #expect(preview.gatewayArguments["subject"] as? String == "Cannot open the crew roster")
        #expect(preview.isUsable())
        #expect(!preview.isUsable(at: Date().addingTimeInterval(WingmanPendingTicketPreview.maximumAge + 1)))

        let condensed = try jsonObject(WingmanToolCatalog.condenseResult(toolName: "support_createTicket", resultText: previewResultText))
        #expect(condensed["confirmation_token"] == nil)
        #expect(condensed["requires_confirmation"] as? Bool == true)
        let condensedPreview = condensed["preview"] as? [String: Any]
        #expect(condensedPreview?["tenantName"] as? String == "Planet Nine")
        #expect(condensedPreview?["willEmailRequester"] == nil)
        #expect((condensed["message"] as? String)?.contains("go ahead") == true)
    }

    @Test func aCreatedTicketKeepsItsNumberAndIsNotAPreview() throws {
        let createdResultText = """
        {"success":true,"ticket":{"ticket_id":"11111111-2222-4333-8444-555555555555","ticket_number":"PN-000012","status":"open","priority":"high","subject":"Cannot open the crew roster","tenant_id":"t-1","requester_email":"pat.pilot@planetnine.example","created_at":"2026-09-05T12:00:00Z"},"createdBy":"automation@forit.io"}
        """
        #expect(WingmanToolCatalog.isCreatedTicketResult(createdResultText))
        #expect(WingmanToolCatalog.pendingTicketPreview(fromCreateTicketResultText: createdResultText, gatewayArgumentsSent: [:]) == nil)
        let condensed = try jsonObject(WingmanToolCatalog.condenseResult(toolName: "support_createTicket", resultText: createdResultText))
        let ticket = condensed["ticket"] as? [String: Any]
        #expect(ticket?["ticket_number"] as? String == "PN-000012")
        #expect(ticket?["requester_email"] == nil)
        #expect(condensed["createdBy"] == nil)
    }

    @Test func aSendRailHoldTellsTheModelToGetTheWords() {
        let holdResultText = "HTTP error 409: Conflict - {'error': 'send_rail_hold', 'holdId': 'h-1', 'message': 'Consent needed'}"
        #expect(WingmanToolCatalog.condenseResult(toolName: "support_createTicket", resultText: holdResultText) == WingmanToolCatalog.ticketHeldByForSupportMessage)
        #expect(WingmanToolCatalog.isSendRailHoldResult(holdResultText))
        #expect(!WingmanToolCatalog.isCreatedTicketResult(holdResultText))
    }

    @Test func tenantAndPersonResultsAreCutToWhatTheModelNeeds() throws {
        let tenantsResultText = """
        {"tenants":[{"tenant_id":"t-1","tenant_name":"Planet Nine","slug":"pn","status":"active","created_at":"2026-01-01","entra_tenant_id":"e-1"}]}
        """
        let condensedTenants = try jsonObject(WingmanToolCatalog.condenseResult(toolName: "support_listTenants", resultText: tenantsResultText))
        let firstTenant = (condensedTenants["tenants"] as? [[String: Any]])?.first
        #expect(firstTenant?.keys.sorted() == ["slug", "tenant_id", "tenant_name"])

        let peopleRows = (1...12).map { index in
            "{\"display_name\":\"Person \(index)\",\"email\":\"p\(index)@planetnine.example\",\"job_title\":\"Pilot\",\"department\":\"Ops\",\"tenant_name\":\"Planet Nine\",\"account_enabled\":true,\"device_count\":3,\"app_count\":9}"
        }.joined(separator: ",")
        let peopleResultText = "{\"users\":[\(peopleRows)],\"tenants\":[{\"tenant_id\":\"t-1\"}],\"count\":12,\"foritTenantId\":\"f-1\"}"
        let condensedPeople = try jsonObject(WingmanToolCatalog.condenseResult(toolName: "support_listInventoryUsers", resultText: peopleResultText))
        let people = try #require(condensedPeople["users"] as? [[String: Any]])
        #expect(people.count == 10)
        #expect(condensedPeople["count"] as? Int == 12)
        #expect(people.first?["device_count"] == nil)
        #expect(people.first?["email"] as? String == "p1@planetnine.example")
        #expect(condensedPeople["foritTenantId"] == nil)
    }
}
