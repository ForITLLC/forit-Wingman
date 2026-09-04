//
//  WingmanToolUseTests.swift
//  WingmanTests
//
//  Covers the deterministic parts of the Support skill: the tool allow-list and its argument
//  policy, the Anthropic SSE tool_use parsing, and the gateway response parsing. No network.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanToolUseTests {

    private let signedInAccount = WingmanSignedInAccount(displayName: "Sam Staff", emailAddress: "sam@forit.io")

    // MARK: - Allow-list

    @Test func onlyTheThreeSupportToolsAreDescribedToTheModel() {
        let describedToolNames = WingmanToolCatalog.modelToolDefinitions.compactMap { $0["name"] as? String }
        #expect(describedToolNames == ["support_listTickets", "support_addTicketNote", "forit_avops_search_flights"])

        let forbiddenToolNames = ["support_replyToTicket", "support_deleteTicket", "support_assignTicket", "support_bulkUpdateTickets", "support_provisioningSyncUser"]
        for forbiddenToolName in forbiddenToolNames {
            #expect(WingmanToolCatalog.descriptor(named: forbiddenToolName) == nil)
        }
        for definition in WingmanToolCatalog.modelToolDefinitions {
            let inputSchema = definition["input_schema"] as? [String: Any]
            #expect(inputSchema?["type"] as? String == "object")
        }
    }

    @Test func aToolOutsideTheAllowListIsRefusedBeforeAnyCall() {
        #expect(throws: WingmanToolRefusal.notOnAllowList(toolName: "support_replyToTicket")) {
            try WingmanToolCatalog.prepareCall(
                toolName: "support_replyToTicket",
                modelArguments: ["ticketId": "abc", "content": "Sending this to the customer"],
                signedInAccount: signedInAccount
            )
        }
    }

    // MARK: - Draft note policy

    @Test func aDraftReplyBecomesAPrefixedInternalNoteAttributedToTheUsersWingman() throws {
        let preparedCall = try WingmanToolCatalog.prepareCall(
            toolName: "support_addTicketNote",
            modelArguments: [
                "ticketId": "BB6D5990-CE2D-40A4-BA5D-6DECD53D2337",
                "content": "Hi, thanks for reporting this. We are looking into the accounting monitor now.",
                "external_source": "should-be-dropped",
                "author_email": "sam@forit.io",
            ],
            signedInAccount: signedInAccount
        )

        #expect(preparedCall.toolName == "support_addTicketNote")
        #expect(preparedCall.arguments["ticketId"] as? String == "BB6D5990-CE2D-40A4-BA5D-6DECD53D2337")
        #expect(preparedCall.arguments["content"] as? String == "DRAFT (Wingman): Hi, thanks for reporting this. We are looking into the accounting monitor now.")
        #expect(preparedCall.arguments["author_name"] as? String == "Wingman for Sam Staff <sam@forit.io>")
        #expect(preparedCall.arguments["external_source"] == nil)
        #expect(preparedCall.arguments["author_email"] == nil)
        #expect(preparedCall.arguments.count == 3)
    }

    @Test func theDraftPrefixIsAppliedOnceEvenWhenTheModelWroteItAlready() throws {
        let preparedCall = try WingmanToolCatalog.prepareCall(
            toolName: "support_addTicketNote",
            modelArguments: ["ticketId": "abc", "content": "DRAFT (Wingman): DRAFT (Wingman): Hello there."],
            signedInAccount: nil
        )
        #expect(preparedCall.arguments["content"] as? String == "DRAFT (Wingman): Hello there.")
        #expect(preparedCall.arguments["author_name"] as? String == "Wingman")
    }

    @Test func aDraftWithoutTicketIdOrContentIsRefused() {
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_addTicketNote", modelArguments: ["content": "Hello"], signedInAccount: signedInAccount)
        }
        #expect(throws: WingmanToolRefusal.self) {
            try WingmanToolCatalog.prepareCall(toolName: "support_addTicketNote", modelArguments: ["ticketId": "abc", "content": "   "], signedInAccount: signedInAccount)
        }
    }

    // MARK: - Read-only tool arguments

    @Test func ticketListArgumentsAreClampedAndUnknownKeysDropped() throws {
        let preparedCall = try WingmanToolCatalog.prepareCall(
            toolName: "support_listTickets",
            modelArguments: ["tenant": " gna ", "status": "active", "limit": 500, "search": "227", "page": 2, "priority": "high", "status_bogus": "x"],
            signedInAccount: signedInAccount
        )
        #expect(preparedCall.arguments["tenant"] as? String == "gna")
        #expect(preparedCall.arguments["status"] as? String == "active")
        #expect(preparedCall.arguments["limit"] as? Int == WingmanToolCatalog.maximumTicketsPerList)
        #expect(preparedCall.arguments["search"] as? String == "227")
        #expect(preparedCall.arguments["page"] as? Int == 2)
        #expect(preparedCall.arguments["priority"] == nil)
        #expect(preparedCall.arguments["status_bogus"] == nil)

        let defaultCall = try WingmanToolCatalog.prepareCall(
            toolName: "support_listTickets",
            modelArguments: ["status": "not-a-status"],
            signedInAccount: signedInAccount
        )
        #expect(defaultCall.arguments["limit"] as? Int == WingmanToolCatalog.defaultTicketsPerList)
        #expect(defaultCall.arguments["status"] == nil)
    }

    @Test func flightSearchArgumentsAreCappedToTheGatewayWindow() throws {
        let preparedCall = try WingmanToolCatalog.prepareCall(
            toolName: "forit_avops_search_flights",
            modelArguments: ["flight_number": "GGN101", "hours_ahead": 9999, "hours_back": -3, "status": "airborne", "tenant": "gna"],
            signedInAccount: signedInAccount
        )
        #expect(preparedCall.arguments["flight_number"] as? String == "GGN101")
        #expect(preparedCall.arguments["hours_ahead"] as? Double == 336)
        #expect(preparedCall.arguments["hours_back"] == nil)
        #expect(preparedCall.arguments["status"] as? String == "airborne")
        #expect(preparedCall.arguments["tenant"] == nil)
    }

    // MARK: - Result condensing

    @Test func ticketListResultsKeepOnlyTheFieldsTheModelNeeds() throws {
        let gatewayResultText = """
        {"tickets":[{"ticket_id":"BB6D","ticket_number":"FI-000227","subject":"accounting failing","status":"new","priority":"high","tenant_color":"#3B82F6","category_icon":"code","assigned_group_id":"9472","ai_summary":"Intermittent failures.","sla_breached_at":null,"requester_name":"Portfolio Monitor"}],"pagination":{"total":1,"page":1,"limit":10,"totalPages":1}}
        """
        let condensedText = WingmanToolCatalog.condenseResult(toolName: "support_listTickets", resultText: gatewayResultText)
        let condensedObject = try #require(JSONSerialization.jsonObject(with: Data(condensedText.utf8)) as? [String: Any])
        let tickets = try #require(condensedObject["tickets"] as? [[String: Any]])
        let firstTicket = try #require(tickets.first)

        #expect(firstTicket["ticket_number"] as? String == "FI-000227")
        #expect(firstTicket["ai_summary"] as? String == "Intermittent failures.")
        #expect(firstTicket["requester_name"] as? String == "Portfolio Monitor")
        #expect(firstTicket["tenant_color"] == nil)
        #expect(firstTicket["category_icon"] == nil)
        #expect(firstTicket["assigned_group_id"] == nil)
        #expect(firstTicket["sla_breached_at"] == nil)
        #expect((condensedObject["pagination"] as? [String: Any])?["total"] as? Int == 1)

        let untouchedText = WingmanToolCatalog.condenseResult(toolName: "forit_avops_search_flights", resultText: "{\"flights\":[]}")
        #expect(untouchedText == "{\"flights\":[]}")
    }

    // MARK: - Anthropic SSE parsing

    @Test func aStreamedToolUseTurnIsDecodedWithItsInputAndEchoBlocks() {
        let streamLines = [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01\",\"role\":\"assistant\"}}",
            "",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"let me \"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"check.\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"support_listTickets\",\"input\":{}}}",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"tenant\\\": \\\"g\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"na\\\", \\\"limit\\\": 5}\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":30}}",
            "data: {\"type\":\"message_stop\"}",
        ]

        var streamParser = ClaudeSSEStreamParser()
        var progressiveTexts: [String] = []
        for line in streamLines {
            if let accumulatedText = streamParser.consume(line: line) {
                progressiveTexts.append(accumulatedText)
            }
        }
        let streamedTurn = streamParser.finishedTurn()

        #expect(progressiveTexts == ["let me ", "let me check."])
        #expect(streamedTurn.text == "let me check.")
        #expect(streamedTurn.stopReason == "tool_use")
        #expect(streamedTurn.wantsToolCalls)
        #expect(streamedTurn.toolUses.count == 1)
        #expect(streamedTurn.toolUses.first?.id == "toolu_01")
        #expect(streamedTurn.toolUses.first?.name == "support_listTickets")
        #expect(streamedTurn.toolUses.first?.input["tenant"] as? String == "gna")
        #expect(streamedTurn.toolUses.first?.input["limit"] as? Int == 5)
        #expect(streamParser.hasReachedEndOfMessage)

        #expect(streamedTurn.assistantContentBlocks.count == 2)
        #expect(streamedTurn.assistantContentBlocks[0]["type"] as? String == "text")
        #expect(streamedTurn.assistantContentBlocks[1]["type"] as? String == "tool_use")
        #expect(streamedTurn.assistantContentBlocks[1]["id"] as? String == "toolu_01")
    }

    @Test func aToolUseWithNoInputDeltasDecodesToAnEmptyObject() {
        var streamParser = ClaudeSSEStreamParser()
        _ = streamParser.consume(line: "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_02\",\"name\":\"forit_avops_search_flights\",\"input\":{}}}")
        _ = streamParser.consume(line: "data: {\"type\":\"content_block_stop\",\"index\":0}")
        _ = streamParser.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}")
        let streamedTurn = streamParser.finishedTurn()

        #expect(streamedTurn.toolUses.first?.input.isEmpty == true)
        #expect(streamedTurn.text.isEmpty)
        #expect(streamedTurn.wantsToolCalls)
    }

    @Test func aPlainTextTurnHasNoToolCalls() {
        var streamParser = ClaudeSSEStreamParser()
        _ = streamParser.consume(line: "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
        _ = streamParser.consume(line: "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello there. [POINT:none]\"}}")
        _ = streamParser.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")
        _ = streamParser.consume(line: "data: {\"type\":\"message_stop\"}")
        let streamedTurn = streamParser.finishedTurn()

        #expect(streamedTurn.text == "hello there. [POINT:none]")
        #expect(streamedTurn.stopReason == "end_turn")
        #expect(!streamedTurn.wantsToolCalls)
        #expect(streamedTurn.assistantContentBlocks.count == 1)
    }

    // MARK: - Gateway response parsing

    @Test func aJSONToolCallResponseYieldsTheTextAndErrorFlag() throws {
        let responseBody = Data("""
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\\"tickets\\":[]}"}],"isError":false}}
        """.utf8)
        let jsonRPCResponse = try WingmanGatewayToolClient.parseJSONRPCResponse(body: responseBody, contentType: "application/json")
        let toolResult = try WingmanGatewayToolClient.toolResult(fromJSONRPCResponse: jsonRPCResponse)

        #expect(toolResult == WingmanGatewayToolResult(text: "{\"tickets\":[]}", isError: false))
    }

    @Test func anEventStreamToolCallResponseIsFoundAmongTheFrames() throws {
        let responseBody = Data("""
        event: message\r
        data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"working"}}\r
        \r
        event: message\r
        data: {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Ticket not found"}],"isError":true}}\r
        \r
        """.utf8)
        let jsonRPCResponse = try WingmanGatewayToolClient.parseJSONRPCResponse(body: responseBody, contentType: "text/event-stream; charset=utf-8")
        let toolResult = try WingmanGatewayToolClient.toolResult(fromJSONRPCResponse: jsonRPCResponse)

        #expect(toolResult.text == "Ticket not found")
        #expect(toolResult.isError)
    }

    @Test func anEventStreamWithoutAResponseIsAnInvalidResponse() {
        let responseBody = Data("event: ping\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n".utf8)
        #expect(throws: WingmanGatewayToolError.self) {
            try WingmanGatewayToolClient.parseJSONRPCResponse(body: responseBody, contentType: "text/event-stream")
        }
    }

    @Test func gatewayRefusalsMapToAccessErrorsWithTheChallengeDetail() throws {
        let challengeURL = try #require(URL(string: "https://gateway.example/mcp"))
        let forbiddenResponse = HTTPURLResponse(
            url: challengeURL,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["WWW-Authenticate": "Bearer error=\"insufficient_scope\", error_description=\"tools.write required\""]
        )
        let forbiddenError = WingmanGatewayToolClient.error(forStatusCode: 403, responseBody: Data(), httpResponse: forbiddenResponse)
        guard case .insufficientAccess(let forbiddenDetail) = forbiddenError else {
            Issue.record("expected insufficientAccess, got \(forbiddenError)")
            return
        }
        #expect(forbiddenDetail == "tools.write required")

        let deniedBody = Data("{\"error\":\"invalid_token\",\"error_description\":\"no gateway role\"}".utf8)
        let deniedError = WingmanGatewayToolClient.error(forStatusCode: 401, responseBody: deniedBody, httpResponse: nil)
        guard case .accessDenied(let deniedDetail) = deniedError else {
            Issue.record("expected accessDenied, got \(deniedError)")
            return
        }
        #expect(deniedDetail == "no gateway role")

        let otherError = WingmanGatewayToolClient.error(forStatusCode: 502, responseBody: Data("upstream down".utf8), httpResponse: nil)
        guard case .gatewayRejected(let statusCode, let otherDetail) = otherError else {
            Issue.record("expected gatewayRejected, got \(otherError)")
            return
        }
        #expect(statusCode == 502)
        #expect(otherDetail == "upstream down")
    }
}
