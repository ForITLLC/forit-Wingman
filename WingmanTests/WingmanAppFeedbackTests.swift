//
//  WingmanAppFeedbackTests.swift
//  WingmanTests
//
//  Covers feedback by voice (decision 016): the tool input, the story's title and description,
//  the reading of the three gateway answers, the arguments sent, and the filing sequence with
//  a stubbed gateway (cached anchor, lookup, epic creation, a rejected create).
//

import Foundation
import Testing
@testable import Wingman

/// A gateway that answers each tool from a queue and records what it was asked.
final class StubbedGateway {
    private(set) var calls: [(toolName: String, arguments: [String: Any])] = []
    private var queuedAnswers: [String: [WingmanGatewayToolResult]] = [:]

    func answer(_ toolName: String, with text: String, isError: Bool = false) {
        queuedAnswers[toolName, default: []].append(WingmanGatewayToolResult(text: text, isError: isError))
    }

    func call(_ toolName: String, _ arguments: [String: Any]) async throws -> WingmanGatewayToolResult {
        calls.append((toolName, arguments))
        guard var answers = queuedAnswers[toolName], !answers.isEmpty else {
            return WingmanGatewayToolResult(text: "{\"error\": \"unexpected call to \(toolName)\"}", isError: true)
        }
        let nextAnswer = answers.removeFirst()
        queuedAnswers[toolName] = answers
        return nextAnswer
    }
}

struct WingmanAppFeedbackTests {
    private let submitter = WingmanSignedInAccount(displayName: "Christine Shiomi", emailAddress: "c.shiomi@forit.io")
    private let filedAt = Date(timeIntervalSince1970: 1_788_649_200)
    private let anchor = WingmanAppFeedbackAnchor(projectId: "8044B9FA-8D21-4D55-AD37-9599E35E7703", epicId: "EPIC-1")

    private let projectsAnswer = """
    {"clients": [
      {"clientId": "A6236B4D-E97A-4252-9920-44E754FF104C", "name": "Crew Records App", "tenant": "forit"},
      {"clientId": "8044B9FA-8D21-4D55-AD37-9599E35E7703", "name": "ForIT Master Plan", "tenant": "forit"},
      {"clientId": "AAA1BEF9-CF5C-402F-99CE-84CC8AE8BA64", "name": "Great North Master Plan", "tenant": "greatnorth"}
    ], "total": 3}
    """

    private let epicsAnswerWithFeedbackEpic = """
    {"stories": [
      {"id": "OTHER", "title": "Inventory improvement loop", "type": "epic", "tenant": "forit", "clientId": "8044B9FA-8D21-4D55-AD37-9599E35E7703"},
      {"id": "GNA-EPIC", "title": "App Feedback", "type": "epic", "tenant": "greatnorth", "clientId": "AAA1BEF9-CF5C-402F-99CE-84CC8AE8BA64"},
      {"id": "EPIC-1", "title": "app feedback", "type": "epic", "tenant": "forit", "clientId": "8044B9FA-8D21-4D55-AD37-9599E35E7703"}
    ], "total": 3, "returned": 3}
    """

    private let epicsAnswerWithoutFeedbackEpic = """
    {"stories": [
      {"id": "OTHER", "title": "Inventory improvement loop", "type": "epic", "tenant": "forit", "clientId": "8044B9FA-8D21-4D55-AD37-9599E35E7703"}
    ], "total": 1, "returned": 1}
    """

    // MARK: Input

    @Test func bothArgumentsAreRequired() {
        #expect(WingmanAppFeedbackRequest.parse(toolInput: ["application": "Forms", "feedback": " the export is slow "]) ==
                WingmanAppFeedbackRequest(applicationName: "Forms", feedback: "the export is slow"))
        #expect(WingmanAppFeedbackRequest.parse(toolInput: ["application": "Forms"]) == nil)
        #expect(WingmanAppFeedbackRequest.parse(toolInput: ["application": "  ", "feedback": "x"]) == nil)
        #expect(WingmanAppFeedbackRequest.parse(toolInput: ["feedback": "x"]) == nil)
    }

    @Test func toolDefinitionNamesTheToolAndRequiresBothArguments() throws {
        let definition = WingmanAppFeedback.modelToolDefinition
        #expect(definition["name"] as? String == "send_app_feedback")
        let schema = try #require(definition["input_schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["application", "feedback"])
    }

    @Test func offeredOnlyWhenTheGatewayExposesAllThreeAgileTools() {
        #expect(WingmanAppFeedback.isAvailable(exposedGatewayToolNames: nil))
        #expect(WingmanAppFeedback.isAvailable(exposedGatewayToolNames: ["forit_agile_list_clients", "forit_agile_list_stories", "forit_agile_create_story", "support_listTickets"]))
        #expect(!WingmanAppFeedback.isAvailable(exposedGatewayToolNames: ["forit_agile_list_clients", "forit_agile_list_stories"]))
    }

    @Test func promptSectionNamesWingmanAndTheAppsOnce() {
        let section = WingmanAppFeedback.systemPromptSection(applicationNames: ["AVHR", "Forms", "avhr", " ", "Wingman"])
        #expect(section.contains("the app names the team knows: Wingman, AVHR, Forms."))
        #expect(section.contains("send_app_feedback"))
    }

    // MARK: Shaping

    @Test func titleIsTheFirstNonEmptyLineWithThePrefix() {
        #expect(WingmanAppFeedback.storyTitle(fromFeedback: "\n  The pointer is too small.\nSecond line") == "App feedback: The pointer is too small.")
        #expect(WingmanAppFeedback.storyTitle(fromFeedback: "   ") == "App feedback: Untitled feedback")
        let longTitle = WingmanAppFeedback.storyTitle(fromFeedback: String(repeating: "a", count: 600))
        #expect(longTitle.count == 500)
    }

    @Test func descriptionIsVerbatimWithTheSubmitterFooter() {
        let description = WingmanAppFeedback.storyDescription(feedback: "The pointer is too small.", submitter: submitter, filedAt: filedAt)
        #expect(description == "The pointer is too small.\n\n---\nSubmitted by Christine Shiomi (c.shiomi@forit.io) at 2026-09-05T23:00:00Z with Wingman")
        let anonymous = WingmanAppFeedback.storyDescription(feedback: "x", submitter: nil, filedAt: filedAt)
        #expect(anonymous.hasSuffix("Submitted by a signed-in person at 2026-09-05T23:00:00Z with Wingman"))
    }

    @Test func descriptionCutsFeedbackAtTheCap() {
        let description = WingmanAppFeedback.storyDescription(feedback: String(repeating: "b", count: 5_000), submitter: nil, filedAt: filedAt)
        #expect(description.hasPrefix(String(repeating: "b", count: 4_000) + "\n\n---\n"))
    }

    @Test func projectIsTheForITMasterPlanWhenPresent() {
        #expect(WingmanAppFeedback.projectId(fromListProjectsResultText: projectsAnswer) == "8044B9FA-8D21-4D55-AD37-9599E35E7703")
        let onlyCrew = "{\"clients\": [{\"clientId\": \"CREW\", \"name\": \"Crew Records App\", \"tenant\": \"forit\"}]}"
        #expect(WingmanAppFeedback.projectId(fromListProjectsResultText: onlyCrew) == "CREW")
        let noForIT = "{\"clients\": [{\"clientId\": \"GNA\", \"name\": \"Great North Master Plan\", \"tenant\": \"greatnorth\"}]}"
        #expect(WingmanAppFeedback.projectId(fromListProjectsResultText: noForIT) == nil)
        #expect(WingmanAppFeedback.projectId(fromListProjectsResultText: "not json") == nil)
    }

    @Test func epicMatchesTheTitleCaseInsensitivelyAndPrefersTheProject() {
        #expect(WingmanAppFeedback.epicId(fromListStoriesResultText: epicsAnswerWithFeedbackEpic, projectId: "8044B9FA-8D21-4D55-AD37-9599E35E7703") == "EPIC-1")
        #expect(WingmanAppFeedback.epicId(fromListStoriesResultText: epicsAnswerWithFeedbackEpic, projectId: "SOMEWHERE-ELSE") == "GNA-EPIC")
        #expect(WingmanAppFeedback.epicId(fromListStoriesResultText: epicsAnswerWithoutFeedbackEpic, projectId: "8044B9FA-8D21-4D55-AD37-9599E35E7703") == nil)
    }

    @Test func createdRowIsReadFromTheTopLevelOrANestedObject() {
        #expect(WingmanAppFeedback.filedStory(fromCreateResultText: "{\"id\": \"S1\", \"displayId\": \"183\", \"title\": \"x\"}") ==
                WingmanFiledAppFeedback(storyId: "S1", storyDisplayId: "183"))
        #expect(WingmanAppFeedback.filedStory(fromCreateResultText: "{\"task\": {\"id\": \"S2\", \"displayId\": 184}}") ==
                WingmanFiledAppFeedback(storyId: "S2", storyDisplayId: "184"))
        #expect(WingmanAppFeedback.filedStory(fromCreateResultText: "{\"taskId\": \"S3\"}") ==
                WingmanFiledAppFeedback(storyId: "S3", storyDisplayId: nil))
        #expect(WingmanAppFeedback.filedStory(fromCreateResultText: "{\"error\": \"validation_failed\", \"errors\": []}") == nil)
        #expect(WingmanAppFeedback.filedStory(fromCreateResultText: "{}") == nil)
    }

    @Test func errorMessageJoinsTheBoardsReasons() {
        #expect(WingmanAppFeedback.errorMessage(fromResultText: "{\"error\": \"validation_failed\", \"errors\": [{\"field\": \"functionalArea\", \"message\": \"functional area is required\"}, {\"message\": \"parent not found\"}]}") ==
                "functional area is required; parent not found")
        #expect(WingmanAppFeedback.errorMessage(fromResultText: "{\"error\": \"for-agile API HTTP 500\", \"detail\": \"boom\"}") == "for-agile API HTTP 500: boom")
        #expect(WingmanAppFeedback.errorMessage(fromResultText: "{\"id\": \"S1\"}") == nil)
    }

    @Test func storyArgumentsCarryTheIntakeShape() {
        let request = WingmanAppFeedbackRequest(applicationName: "AVHR", feedback: "Remember my filters.")
        let arguments = WingmanAppFeedback.storyCreateArguments(request: request, anchor: anchor, submitter: submitter, filedAt: filedAt)
        #expect(arguments["title"] as? String == "App feedback: Remember my filters.")
        #expect(arguments["type"] as? String == "user-story")
        #expect(arguments["source"] as? String == "app-feedback")
        #expect(arguments["app"] as? String == "Wingman")
        #expect(arguments["tenant"] as? String == "forit")
        #expect(arguments["clientId"] as? String == anchor.projectId)
        #expect(arguments["parentId"] as? String == anchor.epicId)
        #expect(arguments["functionalArea"] as? String == "AVHR")
        #expect(arguments["createdBy"] as? String == "c.shiomi@forit.io")
        #expect((arguments["description"] as? String)?.hasPrefix("Remember my filters.\n\n---\nSubmitted by") == true)
    }

    // MARK: Filing

    @Test func aCachedAnchorGoesStraightToTheCreate() async throws {
        let gateway = StubbedGateway()
        gateway.answer("forit_agile_create_story", with: "{\"id\": \"S1\", \"displayId\": \"183\"}")
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Wingman", "feedback": "The pointer is too small."],
            signedInAccount: submitter, cachedAnchor: anchor, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(!outcome.isError)
        #expect(outcome.analyticsOutcomeLabel == "filed")
        #expect(outcome.anchor == anchor)
        #expect(outcome.filedStory == WingmanFiledAppFeedback(storyId: "S1", storyDisplayId: "183"))
        #expect(outcome.resultText.contains("story 183"))
        #expect(gateway.calls.map(\.toolName) == ["forit_agile_create_story"])
    }

    @Test func withoutAnAnchorTheProjectAndEpicAreLookedUp() async throws {
        let gateway = StubbedGateway()
        gateway.answer("forit_agile_list_clients", with: projectsAnswer)
        gateway.answer("forit_agile_list_stories", with: epicsAnswerWithFeedbackEpic)
        gateway.answer("forit_agile_create_story", with: "{\"id\": \"S1\", \"displayId\": \"183\"}")
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Forms", "feedback": "x"],
            signedInAccount: submitter, cachedAnchor: nil, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(!outcome.isError)
        #expect(outcome.anchor == anchor)
        #expect(gateway.calls.map(\.toolName) == ["forit_agile_list_clients", "forit_agile_list_stories", "forit_agile_create_story"])
        #expect(gateway.calls[1].arguments["type"] as? String == "epic")
        #expect(gateway.calls[1].arguments["tenant"] as? String == "forit")
    }

    @Test func aMissingEpicIsCreatedFirst() async throws {
        let gateway = StubbedGateway()
        gateway.answer("forit_agile_list_clients", with: projectsAnswer)
        gateway.answer("forit_agile_list_stories", with: epicsAnswerWithoutFeedbackEpic)
        gateway.answer("forit_agile_create_story", with: "{\"id\": \"NEW-EPIC\", \"displayId\": \"190\"}")
        gateway.answer("forit_agile_create_story", with: "{\"id\": \"S9\", \"displayId\": \"191\"}")
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Forms", "feedback": "x"],
            signedInAccount: submitter, cachedAnchor: nil, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(!outcome.isError)
        #expect(outcome.anchor == WingmanAppFeedbackAnchor(projectId: anchor.projectId, epicId: "NEW-EPIC"))
        #expect(gateway.calls.count == 4)
        #expect(gateway.calls[2].arguments["type"] as? String == "epic")
        #expect(gateway.calls[2].arguments["title"] as? String == "App Feedback")
        #expect(gateway.calls[3].arguments["parentId"] as? String == "NEW-EPIC")
    }

    @Test func aRejectedCreateIsAnErrorTheModelReadsAndAGoneParentDropsTheAnchor() async throws {
        let gateway = StubbedGateway()
        gateway.answer("forit_agile_create_story", with: "{\"error\": \"validation_failed\", \"errors\": [{\"field\": \"parentId\", \"message\": \"parent not found\"}]}")
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Forms", "feedback": "x"],
            signedInAccount: submitter, cachedAnchor: anchor, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(outcome.isError)
        #expect(outcome.analyticsOutcomeLabel == "story_create_rejected")
        #expect(outcome.anchor == nil)
        #expect(outcome.resultText.contains("parent not found"))
    }

    @Test func aGatewayErrorResultKeepsTheAnchorAndCarriesTheStatusLabel() async throws {
        let gateway = StubbedGateway()
        gateway.answer("forit_agile_create_story", with: "Error calling tool: HTTP 502 from upstream", isError: true)
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Forms", "feedback": "x"],
            signedInAccount: submitter, cachedAnchor: anchor, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(outcome.isError)
        #expect(outcome.anchor == anchor)
        #expect(outcome.analyticsOutcomeLabel == WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "Error calling tool: HTTP 502 from upstream"))
    }

    @Test func malformedInputNeverReachesTheGateway() async throws {
        let gateway = StubbedGateway()
        let outcome = try await WingmanAppFeedback.perform(
            toolInput: ["application": "Forms"],
            signedInAccount: submitter, cachedAnchor: anchor, filedAt: filedAt, callGatewayTool: gateway.call
        )
        #expect(outcome.isError)
        #expect(outcome.analyticsOutcomeLabel == "malformed_request")
        #expect(gateway.calls.isEmpty)
    }
}
