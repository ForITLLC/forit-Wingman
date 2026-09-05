//
//  WingmanAppFeedback.swift
//  Wingman
//
//  Feedback on a ForIT app, given by voice (decision 016; Ben, 2026-09-05: "if you look at
//  for-Forms, we have like give feedback on this app. I want them to basically be able to inject
//  feedback via this tool"). for-Forms' app-feedback form posts each submission to for-agile's
//  intake, which files a story under one "App Feedback" epic with the app as the functional area,
//  the text verbatim, a submitter footer and Source = app-feedback, so the daily digest that lists
//  form feedback lists it. Wingman files the same story through the gateway's for-agile tools with
//  the signed-in person's own token: the model calls send_app_feedback with the app's name and the
//  feedback in the person's words, and this file shapes the gateway calls (find the ForIT project,
//  find or create the epic, create the story) and reads their answers. send_app_feedback is not a
//  gateway tool: WingmanToolCatalog never lists it, and CompanionManager runs it.
//

import Foundation

/// What the model passes: the app the feedback is about and the feedback in the person's words.
struct WingmanAppFeedbackRequest: Equatable {
    let applicationName: String
    let feedback: String

    static let applicationArgumentKey = "application"
    static let feedbackArgumentKey = "feedback"

    /// nil when either value is missing or blank.
    static func parse(toolInput: [String: Any]) -> WingmanAppFeedbackRequest? {
        guard let applicationName = trimmedNonEmpty(toolInput[applicationArgumentKey] as? String),
              let feedback = trimmedNonEmpty(toolInput[feedbackArgumentKey] as? String) else {
            return nil
        }
        return WingmanAppFeedbackRequest(applicationName: applicationName, feedback: feedback)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

/// The two for-agile rows every piece of feedback hangs off: the ForIT project and the
/// "App Feedback" epic in it. Looked up on the first feedback after sign-in and kept in memory.
struct WingmanAppFeedbackAnchor: Equatable {
    let projectId: String
    let epicId: String
}

/// The story a piece of feedback became.
struct WingmanFiledAppFeedback: Equatable {
    let storyId: String
    /// The board number people quote ("story 183"); nil when the API did not return one.
    let storyDisplayId: String?
}

enum WingmanAppFeedback {
    static let toolName = "send_app_feedback"

    static let listProjectsToolName = "forit_agile_list_clients"
    static let listStoriesToolName = "forit_agile_list_stories"
    static let createStoryToolName = "forit_agile_create_story"
    static let requiredGatewayToolNames: Set<String> = [listProjectsToolName, listStoriesToolName, createStoryToolName]

    static let tenantSlug = "forit"
    static let preferredProjectName = "ForIT Master Plan"
    static let epicTitle = "App Feedback"
    /// The Source the for-Forms intake writes on its stories, so whatever lists form feedback by
    /// source lists Wingman's too.
    static let source = "app-feedback"
    static let producerLabel = "Wingman"
    static let maximumFeedbackCharacters = 4_000
    static let maximumTitleCharacters = 500
    static let maximumEpicsPerLookup = 500
    static let maximumApplicationNamesInPrompt = 100

    /// Offered only when the gateway exposes all three for-agile tools to the signed-in person.
    /// nil means the tools/list fetch failed and the whole catalog is being offered, so this is too.
    static func isAvailable(exposedGatewayToolNames: Set<String>?) -> Bool {
        guard let exposedGatewayToolNames else { return true }
        return requiredGatewayToolNames.isSubset(of: exposedGatewayToolNames)
    }

    /// The tool definition the model sees.
    static let modelToolDefinition: [String: Any] = [
        "name": toolName,
        "description": "Send the person's feedback about a ForIT app, or about Wingman itself, to the ForIT product team as one item on their board. Use it when they give feedback, a suggestion, a complaint, an idea or a wish about an app (\"I have feedback on Forms\", \"tell the team the pointer is too small\", \"suggestion for AVHR\"). Pass the app's name and the feedback in their own words. It files one item; it never emails anyone.",
        "input_schema": [
            "type": "object",
            "properties": [
                WingmanAppFeedbackRequest.applicationArgumentKey: [
                    "type": "string",
                    "description": "The app the feedback is about, by name: Wingman, or one of the ForIT and client apps named in the system prompt.",
                ],
                WingmanAppFeedbackRequest.feedbackArgumentKey: [
                    "type": "string",
                    "description": "What the person said, in their own words, as one piece of feedback. Not a summary.",
                ],
            ],
            "required": [WingmanAppFeedbackRequest.applicationArgumentKey, WingmanAppFeedbackRequest.feedbackArgumentKey],
        ],
    ]

    /// The prompt rules for feedback, plus the app names the team knows. Appended to the system
    /// prompt every turn.
    static func systemPromptSection(applicationNames: [String]) -> String {
        var seenLowercasedNames: Set<String> = ["wingman"]
        var knownNames = ["Wingman"]
        for applicationName in applicationNames {
            let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, seenLowercasedNames.insert(trimmedName.lowercased()).inserted else { continue }
            knownNames.append(trimmedName)
            if knownNames.count >= maximumApplicationNamesInPrompt { break }
        }
        return """


        feedback on an app:
        when the person gives feedback, a suggestion, a complaint, an idea or a wish about a forit app or about wingman itself ("i have feedback on forms", "tell the team the pointer is too small", "it would be nice if avhr remembered my filters"), call \(toolName) once with the app's name and the feedback in their own words, then tell them it is on the forit board with the story number the tool returns. when they do not name the app, ask which one before calling; if the app on screen is clearly one of the names below, use it and say so. never file feedback they did not give, never summarise it into something else, and never call the tool twice for the same feedback. the app names the team knows: \(knownNames.joined(separator: ", ")).
        """
    }

    // MARK: - Shaping the story (pure)

    /// The intake's title: "App feedback: " and the first non-empty line, cut at 500 characters.
    static func storyTitle(fromFeedback feedback: String) -> String {
        let firstLine = feedback
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Untitled feedback"
        return String(("App feedback: " + firstLine).prefix(maximumTitleCharacters))
    }

    /// The feedback verbatim (cut at 4,000 characters), then the intake's footer naming who
    /// submitted it and when, with "with Wingman" so the board can tell the two routes apart.
    static func storyDescription(feedback: String, submitter: WingmanSignedInAccount?, filedAt: Date) -> String {
        let clippedFeedback = String(feedback.prefix(maximumFeedbackCharacters))
        let filedAtText = ISO8601DateFormatter().string(from: filedAt)
        let submitterText: String
        if let submitter {
            submitterText = "\(submitter.displayName) (\(submitter.emailAddress))"
        } else {
            submitterText = "a signed-in person"
        }
        return "\(clippedFeedback)\n\n---\nSubmitted by \(submitterText) at \(filedAtText) with Wingman"
    }

    /// The ForIT project's id from `forit_agile_list_clients`: the ForIT Master Plan when the
    /// tenant has it, otherwise the tenant's first project. nil when the tenant has none.
    static func projectId(fromListProjectsResultText resultText: String) -> String? {
        guard let projectRows = objectList(named: "clients", in: resultText) else { return nil }
        let foritProjects = projectRows.filter { ($0["tenant"] as? String)?.lowercased() == tenantSlug }
        let chosenProject = foritProjects.first { ($0["name"] as? String) == preferredProjectName } ?? foritProjects.first
        return nonEmptyString(chosenProject?["clientId"])
    }

    /// The "App Feedback" epic's id from a `forit_agile_list_stories` answer (epics of the ForIT
    /// tenant): the one in the project when there is one, otherwise the first with that title.
    static func epicId(fromListStoriesResultText resultText: String, projectId: String) -> String? {
        guard let storyRows = objectList(named: "stories", in: resultText) else { return nil }
        let feedbackEpics = storyRows.filter { row in
            guard let title = row["title"] as? String else { return false }
            let titleMatches = title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(epicTitle) == .orderedSame
            let typeIsEpic = (row["type"] as? String).map { $0.lowercased() == "epic" } ?? true
            return titleMatches && typeIsEpic
        }
        let chosenEpic = feedbackEpics.first { nonEmptyString($0["clientId"]) == projectId } ?? feedbackEpics.first
        return nonEmptyString(chosenEpic?["id"])
    }

    /// The created row from a `forit_agile_create_story` answer: its id (top level or under
    /// task / item / story / data) and its display number. nil for an error answer.
    static func filedStory(fromCreateResultText resultText: String) -> WingmanFiledAppFeedback? {
        guard let resultObject = jsonObject(in: resultText), resultObject["error"] == nil else { return nil }
        let candidateObjects = [resultObject] + ["task", "item", "story", "data", "result"].compactMap { resultObject[$0] as? [String: Any] }
        for candidateObject in candidateObjects {
            if let storyId = nonEmptyString(candidateObject["id"] ?? candidateObject["taskId"]) {
                return WingmanFiledAppFeedback(storyId: storyId, storyDisplayId: nonEmptyString(candidateObject["displayId"]))
            }
        }
        return nil
    }

    /// The board's reason for refusing a create: every `errors[].message`, or `error` with its
    /// `detail`. nil when the answer carries none.
    static func errorMessage(fromResultText resultText: String) -> String? {
        guard let resultObject = jsonObject(in: resultText) else { return nil }
        if let errorRows = resultObject["errors"] as? [[String: Any]] {
            let messages = errorRows.compactMap { $0["message"] as? String }
            if !messages.isEmpty { return messages.joined(separator: "; ") }
        }
        guard let error = resultObject["error"] else { return nil }
        if let detail = resultObject["detail"] {
            return "\(error): \(detail)"
        }
        return "\(error)"
    }

    static let listStoriesArguments: [String: Any] = ["type": "epic", "tenant": tenantSlug, "limit": maximumEpicsPerLookup]

    static func epicCreateArguments(projectId: String) -> [String: Any] {
        [
            "title": epicTitle,
            "type": "epic",
            "app": producerLabel,
            "source": source,
            "tenant": tenantSlug,
            "clientId": projectId,
            "description": "Anchor epic for feedback given through Wingman and the ForIT app-feedback forms. Stories land here first; re-parent items that become real feature work.",
        ]
    }

    static func storyCreateArguments(
        request: WingmanAppFeedbackRequest,
        anchor: WingmanAppFeedbackAnchor,
        submitter: WingmanSignedInAccount?,
        filedAt: Date
    ) -> [String: Any] {
        var arguments: [String: Any] = [
            "title": storyTitle(fromFeedback: request.feedback),
            "type": "user-story",
            "app": producerLabel,
            "source": source,
            "tenant": tenantSlug,
            "clientId": anchor.projectId,
            "parentId": anchor.epicId,
            "functionalArea": request.applicationName,
            "description": storyDescription(feedback: request.feedback, submitter: submitter, filedAt: filedAt),
            "priority": "medium",
        ]
        if let submitter {
            arguments["createdBy"] = submitter.emailAddress
        }
        return arguments
    }

    // MARK: - Filing

    struct Outcome: Equatable {
        let resultText: String
        let isError: Bool
        /// A stable label for the Mac log and the usage report; never the feedback or the app.
        let analyticsOutcomeLabel: String
        /// The rows the manager should keep for the next feedback; nil drops what it had.
        let anchor: WingmanAppFeedbackAnchor?
        let filedStory: WingmanFiledAppFeedback?
    }

    enum AnchorResolution: Equatable {
        case resolved(WingmanAppFeedbackAnchor)
        case failed(reason: String, analyticsOutcomeLabel: String)
    }

    typealias GatewayToolCall = (_ toolName: String, _ arguments: [String: Any]) async throws -> WingmanGatewayToolResult

    /// Files one piece of feedback. A gateway access or transport error is thrown to the caller,
    /// which handles it the way it handles every gateway tool; every other failure comes back as
    /// an error outcome the model reads.
    static func perform(
        toolInput: [String: Any],
        signedInAccount: WingmanSignedInAccount?,
        cachedAnchor: WingmanAppFeedbackAnchor?,
        filedAt: Date = Date(),
        callGatewayTool: GatewayToolCall
    ) async throws -> Outcome {
        guard let request = WingmanAppFeedbackRequest.parse(toolInput: toolInput) else {
            return Outcome(
                resultText: "\(toolName) needs both \(WingmanAppFeedbackRequest.applicationArgumentKey) and \(WingmanAppFeedbackRequest.feedbackArgumentKey).",
                isError: true,
                analyticsOutcomeLabel: "malformed_request",
                anchor: cachedAnchor,
                filedStory: nil
            )
        }

        let anchor: WingmanAppFeedbackAnchor
        if let cachedAnchor {
            anchor = cachedAnchor
        } else {
            switch try await resolveAnchor(callGatewayTool: callGatewayTool) {
            case .resolved(let resolvedAnchor):
                anchor = resolvedAnchor
            case .failed(let reason, let analyticsOutcomeLabel):
                return Outcome(
                    resultText: "The feedback could not be filed: \(reason). Tell the person and offer to try again later.",
                    isError: true,
                    analyticsOutcomeLabel: analyticsOutcomeLabel,
                    anchor: nil,
                    filedStory: nil
                )
            }
        }

        let createArguments = storyCreateArguments(request: request, anchor: anchor, submitter: signedInAccount, filedAt: filedAt)
        let createResult = try await callGatewayTool(createStoryToolName, createArguments)
        guard !createResult.isError, let filedStory = filedStory(fromCreateResultText: createResult.text) else {
            let reason = errorMessage(fromResultText: createResult.text) ?? "the board did not accept it"
            // A parent the board no longer knows means the cached epic is gone: drop the anchor so
            // the next feedback looks it up again.
            let anchorIsStillGood = !reason.lowercased().contains("parent")
            return Outcome(
                resultText: "The feedback could not be filed: \(reason). Tell the person and offer to try again later.",
                isError: true,
                analyticsOutcomeLabel: createResult.isError
                    ? WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: createResult.text)
                    : "story_create_rejected",
                anchor: anchorIsStillGood ? anchor : nil,
                filedStory: nil
            )
        }

        let storyLabel = filedStory.storyDisplayId.map { "story \($0)" } ?? "a story"
        return Outcome(
            resultText: "Filed as \(storyLabel) under \(epicTitle) for \(request.applicationName): \"\(storyTitle(fromFeedback: request.feedback))\". Tell the person it is on the ForIT board.",
            isError: false,
            analyticsOutcomeLabel: "filed",
            anchor: anchor,
            filedStory: filedStory
        )
    }

    /// The ForIT project and its "App Feedback" epic, created when the project has none yet.
    static func resolveAnchor(callGatewayTool: GatewayToolCall) async throws -> AnchorResolution {
        let projectsResult = try await callGatewayTool(listProjectsToolName, [:])
        guard !projectsResult.isError, let projectId = projectId(fromListProjectsResultText: projectsResult.text) else {
            return .failed(
                reason: "the ForIT project was not found on the board",
                analyticsOutcomeLabel: projectsResult.isError
                    ? WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: projectsResult.text)
                    : "project_not_found"
            )
        }

        let epicsResult = try await callGatewayTool(listStoriesToolName, listStoriesArguments)
        guard !epicsResult.isError else {
            return .failed(
                reason: "the board's epics could not be read",
                analyticsOutcomeLabel: WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: epicsResult.text)
            )
        }
        if let existingEpicId = epicId(fromListStoriesResultText: epicsResult.text, projectId: projectId) {
            return .resolved(WingmanAppFeedbackAnchor(projectId: projectId, epicId: existingEpicId))
        }

        let epicResult = try await callGatewayTool(createStoryToolName, epicCreateArguments(projectId: projectId))
        guard !epicResult.isError, let createdEpic = filedStory(fromCreateResultText: epicResult.text) else {
            let reason = errorMessage(fromResultText: epicResult.text) ?? "no answer"
            return .failed(
                reason: "the \(epicTitle) epic could not be created (\(reason))",
                analyticsOutcomeLabel: epicResult.isError
                    ? WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: epicResult.text)
                    : "epic_create_rejected"
            )
        }
        return .resolved(WingmanAppFeedbackAnchor(projectId: projectId, epicId: createdEpic.storyId))
    }

    // MARK: - JSON helpers

    private static func jsonObject(in resultText: String) -> [String: Any]? {
        guard let resultData = resultText.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: resultData) else {
            return nil
        }
        return parsedObject as? [String: Any]
    }

    /// The list under `key` in an object answer, or the answer itself when it is a bare list.
    private static func objectList(named key: String, in resultText: String) -> [[String: Any]]? {
        guard let resultData = resultText.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: resultData) else {
            return nil
        }
        if let bareList = parsedObject as? [[String: Any]] {
            return bareList
        }
        return (parsedObject as? [String: Any])?[key] as? [[String: Any]]
    }

    /// A string or a number as a non-empty string; nil for anything else.
    private static func nonEmptyString(_ value: Any?) -> String? {
        if let stringValue = value as? String {
            let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }
}
