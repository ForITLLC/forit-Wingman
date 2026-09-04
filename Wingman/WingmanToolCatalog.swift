//
//  WingmanToolCatalog.swift
//  Wingman
//
//  The static allow-list of for-mcp gateway tools the model may call, and the app-side policy
//  applied to every call before it leaves the machine (docs/PERMISSIONS.md 3).
//
//  Only the tools listed here are ever described to the model, so the model cannot call
//  anything else even if the gateway would allow it. The policy is deterministic code, not a
//  prompt: a "draft reply" is always an internal note prefixed "DRAFT (Wingman): ", never a
//  customer-visible reply, whatever the model asked for.
//

import Foundation

/// The gateway app role a tool needs. Named in the spoken refusal when the gateway answers 403.
enum WingmanToolAccessLevel: String {
    case viewer = "Viewer"
    case operatorLevel = "Operator"
}

/// One gateway tool the model may call. The same name is used for the model and for the
/// gateway's `tools/call`.
struct WingmanToolDescriptor {
    let name: String
    let description: String
    /// JSON schema (type object) sent to the model as `input_schema`.
    let inputSchema: [String: Any]
    let minimumAccessLevel: WingmanToolAccessLevel

    /// The Anthropic tool definition: `name`, `description`, `input_schema`.
    var modelDefinition: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": inputSchema,
        ]
    }
}

/// Why the app refused a tool call before it reached the gateway. The message is returned to
/// the model as an error tool_result so it can tell the user in its own words.
enum WingmanToolRefusal: Error, Equatable {
    case notOnAllowList(toolName: String)
    case invalidArguments(toolName: String, reason: String)

    var modelFacingMessage: String {
        switch self {
        case .notOnAllowList(let toolName):
            return "\(toolName) is not something Wingman can do."
        case .invalidArguments(let toolName, let reason):
            return "\(toolName) was not called: \(reason)"
        }
    }
}

/// A tool call after the app-side policy ran: the gateway tool name and the exact arguments.
struct WingmanPreparedToolCall {
    let toolName: String
    let arguments: [String: Any]
}

enum WingmanToolCatalog {
    /// Every note Wingman writes starts with this, so nobody mistakes it for a sent reply.
    static let draftNotePrefix = "DRAFT (Wingman): "

    /// Ticket lists are read aloud; more than this is noise for the ear and for the context.
    static let maximumTicketsPerList = 25
    static let defaultTicketsPerList = 10

    static let listTicketsToolName = "support_listTickets"
    static let addTicketNoteToolName = "support_addTicketNote"
    static let searchFlightsToolName = "forit_avops_search_flights"

    static let tools: [WingmanToolDescriptor] = [
        WingmanToolDescriptor(
            name: listTicketsToolName,
            description: "List ForIT support tickets. Filter by tenant slug (the client, e.g. \"forit\" or \"gna\"), status (\"active\" means not closed or resolved), or search by ticket number (e.g. \"FI-000227\" or \"227\") or subject words. Returns each ticket's id, number, subject, status, priority, requester, assigned agent, SLA due time and an AI summary. Always call this for any ticket question; never answer about tickets from memory.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "tenant": ["type": "string", "description": "Tenant slug of the client, e.g. forit or gna. Omit for every client."],
                    "status": [
                        "type": "string",
                        "enum": ["active", "new", "open", "in_progress", "pending_customer", "pending_vendor", "pending_internal", "resolved", "closed"],
                        "description": "active = not closed or resolved. Use active unless the user asks otherwise.",
                    ],
                    "search": ["type": "string", "description": "Ticket number or words from the subject."],
                    "limit": ["type": "integer", "description": "Results per page, 1 to \(maximumTicketsPerList). Default \(defaultTicketsPerList)."],
                    "page": ["type": "integer", "description": "Page number, default 1."],
                ],
                "required": [],
            ],
            minimumAccessLevel: .viewer
        ),
        WingmanToolDescriptor(
            name: addTicketNoteToolName,
            description: "Save a DRAFT reply on a support ticket as an internal note. The note is visible to ForIT staff only, is never emailed and never reaches the requester; the app prefixes it with \"DRAFT (Wingman): \". Use it when the user asks you to draft a reply or a response to a ticket. Get the ticket's id from \(listTicketsToolName) first. Write the reply text itself as the content, addressed to the requester, ready for the staff member to review and send.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "ticketId": ["type": "string", "description": "The ticket's id (UUID) from \(listTicketsToolName), not the ticket number."],
                    "content": ["type": "string", "description": "The draft reply text, plain text."],
                ],
                "required": ["ticketId", "content"],
            ],
            minimumAccessLevel: .operatorLevel
        ),
        WingmanToolDescriptor(
            name: searchFlightsToolName,
            description: "Search the airline operations tenant's flight schedule and live status (synced hourly from the ops system). Call this for any question about flights, today's schedule, delays, cancellations or aircraft movements; never answer those from memory. Default window: past 6 hours to next 24 hours. All times are UTC. Returns per-flight status (scheduled, airborne, landed, cancelled) and delay minutes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "flight_number": ["type": "string", "description": "Flight number with or without the airline prefix, e.g. GGN101 or 101."],
                    "airport": ["type": "string", "description": "Airport code as ops writes it, e.g. YZF. Matches origin or destination."],
                    "aircraft_reg": ["type": "string", "description": "Aircraft registration, e.g. C-FABC or FABC."],
                    "status": ["type": "string", "enum": ["scheduled", "airborne", "landed", "cancelled"]],
                    "hours_back": ["type": "number", "description": "Window start, hours before now. Default 6, max 336."],
                    "hours_ahead": ["type": "number", "description": "Window end, hours after now. Default 24, max 336."],
                ],
                "required": [],
            ],
            minimumAccessLevel: .viewer
        ),
    ]

    /// What the model is told it can call. Nothing outside `tools` ever appears here.
    static var modelToolDefinitions: [[String: Any]] {
        tools.map { $0.modelDefinition }
    }

    static func descriptor(named toolName: String) -> WingmanToolDescriptor? {
        tools.first { $0.name == toolName }
    }

    /// Runs the app-side policy on a model-requested call. Unknown tools and malformed
    /// arguments are refused here, before any network call. Keys the schema does not list are
    /// dropped rather than forwarded, so the model cannot smuggle gateway options through.
    static func prepareCall(
        toolName: String,
        modelArguments: [String: Any],
        signedInAccount: WingmanSignedInAccount?
    ) throws -> WingmanPreparedToolCall {
        guard descriptor(named: toolName) != nil else {
            throw WingmanToolRefusal.notOnAllowList(toolName: toolName)
        }

        switch toolName {
        case listTicketsToolName:
            return WingmanPreparedToolCall(toolName: toolName, arguments: prepareListTicketsArguments(modelArguments))
        case addTicketNoteToolName:
            return WingmanPreparedToolCall(
                toolName: toolName,
                arguments: try prepareDraftNoteArguments(modelArguments, signedInAccount: signedInAccount)
            )
        case searchFlightsToolName:
            return WingmanPreparedToolCall(toolName: toolName, arguments: prepareSearchFlightsArguments(modelArguments))
        default:
            throw WingmanToolRefusal.notOnAllowList(toolName: toolName)
        }
    }

    private static let listTicketsStatusValues: Set<String> = [
        "active", "new", "open", "in_progress", "pending_customer", "pending_vendor", "pending_internal", "resolved", "closed",
    ]

    private static func prepareListTicketsArguments(_ modelArguments: [String: Any]) -> [String: Any] {
        var gatewayArguments: [String: Any] = [:]
        if let tenant = nonEmptyString(modelArguments["tenant"]) {
            gatewayArguments["tenant"] = tenant
        }
        if let status = nonEmptyString(modelArguments["status"]), listTicketsStatusValues.contains(status) {
            gatewayArguments["status"] = status
        }
        if let search = nonEmptyString(modelArguments["search"]) {
            gatewayArguments["search"] = search
        }
        let requestedLimit = integerValue(modelArguments["limit"]) ?? defaultTicketsPerList
        gatewayArguments["limit"] = min(max(requestedLimit, 1), maximumTicketsPerList)
        if let page = integerValue(modelArguments["page"]), page >= 1 {
            gatewayArguments["page"] = page
        }
        return gatewayArguments
    }

    private static func prepareDraftNoteArguments(
        _ modelArguments: [String: Any],
        signedInAccount: WingmanSignedInAccount?
    ) throws -> [String: Any] {
        guard let ticketId = nonEmptyString(modelArguments["ticketId"]) else {
            throw WingmanToolRefusal.invalidArguments(toolName: addTicketNoteToolName, reason: "ticketId is required; look the ticket up with \(listTicketsToolName) first.")
        }
        guard let draftText = nonEmptyString(modelArguments["content"]) else {
            throw WingmanToolRefusal.invalidArguments(toolName: addTicketNoteToolName, reason: "content (the draft reply text) is required.")
        }

        // The prefix is the app's, applied once even if the model already wrote it.
        var draftBody = draftText
        while draftBody.hasPrefix(draftNotePrefix) {
            draftBody = String(draftBody.dropFirst(draftNotePrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The gateway records the note under the ForIT Automation identity; author_name is the
        // label kept beside it so a reader knows which person's Wingman wrote the draft.
        let authorLabel: String
        if let signedInAccount {
            authorLabel = "Wingman for \(signedInAccount.displayName) <\(signedInAccount.emailAddress)>"
        } else {
            authorLabel = "Wingman"
        }

        return [
            "ticketId": ticketId,
            "content": draftNotePrefix + draftBody,
            "author_name": authorLabel,
        ]
    }

    private static let searchFlightsStatusValues: Set<String> = ["scheduled", "airborne", "landed", "cancelled"]

    private static func prepareSearchFlightsArguments(_ modelArguments: [String: Any]) -> [String: Any] {
        var gatewayArguments: [String: Any] = [:]
        for stringKey in ["flight_number", "airport", "aircraft_reg"] {
            if let value = nonEmptyString(modelArguments[stringKey]) {
                gatewayArguments[stringKey] = value
            }
        }
        if let status = nonEmptyString(modelArguments["status"]), searchFlightsStatusValues.contains(status) {
            gatewayArguments["status"] = status
        }
        for hoursKey in ["hours_back", "hours_ahead"] {
            if let hours = doubleValue(modelArguments[hoursKey]), hours > 0 {
                gatewayArguments[hoursKey] = min(hours, 336)
            }
        }
        return gatewayArguments
    }

    // MARK: - Result condensing

    /// Fields of a ticket the model needs to answer or draft. Everything else the gateway
    /// returns (colours, icons, internal ids) is dropped to keep tool results small.
    private static let ticketFieldsKeptForModel = [
        "ticket_id", "ticket_number", "subject", "status", "priority", "tenant_name", "tenant_slug",
        "requester_name", "requester_email", "agent_name", "group_name", "category_name",
        "created_at", "updated_at", "last_message_at", "last_message_by", "sla_due_at", "sla_breached_at", "ai_summary",
    ]

    /// Reduces a gateway tool result to what the model needs. Unknown shapes pass through
    /// untouched, so a gateway change never makes a tool unusable.
    static func condenseResult(toolName: String, resultText: String) -> String {
        guard toolName == listTicketsToolName,
              let resultData = resultText.data(using: .utf8),
              let resultObject = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let tickets = resultObject["tickets"] as? [[String: Any]] else {
            return resultText
        }

        let condensedTickets: [[String: Any]] = tickets.map { ticket in
            var condensedTicket: [String: Any] = [:]
            for fieldName in ticketFieldsKeptForModel {
                if let value = ticket[fieldName], !(value is NSNull) {
                    condensedTicket[fieldName] = value
                }
            }
            return condensedTicket
        }

        var condensedResult: [String: Any] = ["tickets": condensedTickets]
        if let pagination = resultObject["pagination"] {
            condensedResult["pagination"] = pagination
        }

        guard let condensedData = try? JSONSerialization.data(withJSONObject: condensedResult, options: [.sortedKeys]),
              let condensedText = String(data: condensedData, encoding: .utf8) else {
            return resultText
        }
        return condensedText
    }

    // MARK: - Argument coercion

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let stringValue = value as? String else { return nil }
        let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return Double(intValue) }
        if let stringValue = value as? String { return Double(stringValue) }
        return nil
    }
}
