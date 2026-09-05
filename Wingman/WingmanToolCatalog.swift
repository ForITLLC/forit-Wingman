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
    static let searchKnowledgeBaseToolName = "support_searchKbArticles"
    static let readKnowledgeBaseArticleToolName = "support_getKbArticle"

    /// Knowledge base searches default to ForIT's own tenant, where the FL3XX and internal how-to
    /// articles live. A client's slug (for example planet-nine) searches that client's articles
    /// plus the global ones instead. The default is applied here, not left to the gateway, so a
    /// search with no tenant can never widen to "every tenant" if the API's default changes.
    static let defaultKnowledgeBaseTenantSlug = "forit"
    static let maximumKnowledgeBaseSearchResults = 10
    static let defaultKnowledgeBaseSearchResults = 5

    /// An article body longer than this is cut before it reaches the model. The relay caps a tool
    /// result at 64 KB, and a spoken answer never needs more than the first few thousand words.
    static let maximumKnowledgeBaseArticleCharacters = 12_000
    static let knowledgeBaseArticleTruncationNotice = "\n\n[article cut here by Wingman; the url has the rest]"

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
        WingmanToolDescriptor(
            name: searchKnowledgeBaseToolName,
            description: "Search the ForIT support knowledge base: how-to and reference articles for the systems ForIT supports, including FL3XX (the flight operations and scheduling platform) and ForIT's own products. Call this before answering any \"how do I\", \"where is\", \"why does\" or setup question about FL3XX or another supported system; never describe a procedure from memory. Returns the best-matching published articles with article_id, title, summary and a link. Then read the best match with \(readKnowledgeBaseArticleToolName) before answering.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "q": ["type": "string", "description": "What the user wants to know, as a few keywords, e.g. \"TSA secure flight activation\" or \"crew duty limits\"."],
                    "tenant": ["type": "string", "description": "Tenant slug whose articles to search. Omit for ForIT's own knowledge base (\(defaultKnowledgeBaseTenantSlug)), which holds the FL3XX articles; give a client's slug only when the user asks about that client's own procedures."],
                    "limit": ["type": "integer", "description": "Results, 1 to \(maximumKnowledgeBaseSearchResults). Default \(defaultKnowledgeBaseSearchResults)."],
                ],
                "required": ["q"],
            ],
            minimumAccessLevel: .viewer
        ),
        WingmanToolDescriptor(
            name: readKnowledgeBaseArticleToolName,
            description: "Read one knowledge base article in full, by the article_id from \(searchKnowledgeBaseToolName). Answer from the article's steps in your own words and name the article so the user can open it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "articleId": ["type": "string", "description": "The article_id (UUID) from \(searchKnowledgeBaseToolName)."],
                ],
                "required": ["articleId"],
            ],
            minimumAccessLevel: .viewer
        ),
    ]

    /// What the model is told it can call. Nothing outside `tools` ever appears here.
    static var modelToolDefinitions: [[String: Any]] {
        tools.map { $0.modelDefinition }
    }

    /// The definitions to send for one turn: the catalog narrowed to what the gateway's `tools/list`
    /// exposes to this user. A catalog tool the gateway does not have (the knowledge base tools before
    /// for-Support ships them, say) is left out, so the model is never offered a tool that can only
    /// fail. nil means the list could not be fetched. If nothing overlaps, the list is taken to be
    /// wrong (an empty answer, a different manifest) and the whole catalog is offered.
    static func modelToolDefinitions(exposedByGateway gatewayToolNames: Set<String>?) -> [[String: Any]] {
        guard let gatewayToolNames else { return modelToolDefinitions }
        let exposedTools = tools.filter { gatewayToolNames.contains($0.name) }
        guard !exposedTools.isEmpty else { return modelToolDefinitions }
        return exposedTools.map { $0.modelDefinition }
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
        signedInAccount: WingmanSignedInAccount?,
        vocabulary: WingmanVocabulary = WingmanVocabulary.builtIn
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
        case searchKnowledgeBaseToolName:
            return WingmanPreparedToolCall(toolName: toolName, arguments: try prepareSearchKnowledgeBaseArguments(modelArguments, vocabulary: vocabulary))
        case readKnowledgeBaseArticleToolName:
            return WingmanPreparedToolCall(toolName: toolName, arguments: try prepareReadKnowledgeBaseArticleArguments(modelArguments))
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

    private static func prepareSearchKnowledgeBaseArguments(
        _ modelArguments: [String: Any],
        vocabulary: WingmanVocabulary
    ) throws -> [String: Any] {
        guard let searchText = nonEmptyString(modelArguments["q"]) else {
            throw WingmanToolRefusal.invalidArguments(toolName: searchKnowledgeBaseToolName, reason: "q (what to search for) is required.")
        }
        // for-Support matches every word of `q` against the title, summary and body, so a whole
        // spoken question ("how do I create a quote in FL3XX?") either finds nothing or ranks the
        // marketing pages that happen to contain "how" and "do" above the how-to. The gateway gets
        // the keywords only.
        var gatewayArguments: [String: Any] = ["q": searchKeywords(from: searchText, vocabulary: vocabulary)]
        // A product name is never a tenant: "search FL3XX for TSA" must not become tenant "fl3xx"
        // (a 404 from for-Support). Any term the vocabulary knows falls back to the default tenant.
        let requestedTenantSlug = nonEmptyString(modelArguments["tenant"])?.lowercased()
        if let requestedTenantSlug, !vocabulary.containsTerm(matching: requestedTenantSlug) {
            gatewayArguments["tenant"] = requestedTenantSlug
        } else {
            gatewayArguments["tenant"] = defaultKnowledgeBaseTenantSlug
        }
        let requestedLimit = integerValue(modelArguments["limit"]) ?? defaultKnowledgeBaseSearchResults
        gatewayArguments["limit"] = min(max(requestedLimit, 1), maximumKnowledgeBaseSearchResults)
        return gatewayArguments
    }

    /// Words that carry no search meaning on their own: question words, articles, pronouns,
    /// auxiliaries, the prepositions a spoken question is built from, and the verbs people use to
    /// ask ("show me", "I want to know"). Every word that survives must match an article.
    static let knowledgeBaseSearchFillerWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its", "my", "me", "i", "we", "our", "you", "your",
        "they", "their", "them", "he", "she", "his", "her", "who", "what", "which", "where", "when", "why", "how",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "doing", "done", "can", "could",
        "would", "should", "will", "shall", "may", "might", "must", "have", "has", "had", "having",
        "to", "of", "in", "on", "at", "for", "from", "with", "without", "into", "onto", "about", "by", "as", "via",
        "and", "or", "but", "if", "then", "so", "than", "not", "no",
        "please", "want", "wants", "need", "needs", "like", "just", "go", "get", "tell", "show", "find", "know",
        "there", "here", "some", "any", "all", "one", "way", "thing", "something", "someone", "anything",
    ]

    /// The keywords of a knowledge base query: the words of `searchText` minus the filler words,
    /// minus the taught product names (every FL3XX article already contains "FL3XX" and a ForIT
    /// how-to never does), with surrounding punctuation and a possessive "'s" dropped. When nothing
    /// meaningful is left (the person asked only "what is FL3XX?") the text is sent as spoken so
    /// the search still runs.
    static func searchKeywords(from searchText: String, vocabulary: WingmanVocabulary) -> String {
        let spokenWords = searchText
            .components(separatedBy: .whitespacesAndNewlines)
            .map { spokenWord -> String in
                var bareWord = spokenWord.trimmingCharacters(in: .punctuationCharacters)
                for possessiveSuffix in ["'s", "\u{2019}s"] where bareWord.hasSuffix(possessiveSuffix) {
                    bareWord.removeLast(possessiveSuffix.count)
                }
                return bareWord
            }
            .filter { !$0.isEmpty }
        let keywords = spokenWords.filter { spokenWord in
            !knowledgeBaseSearchFillerWords.contains(spokenWord.lowercased())
                && !vocabulary.containsTerm(matching: spokenWord)
        }
        if keywords.isEmpty {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return keywords.joined(separator: " ")
    }

    private static func prepareReadKnowledgeBaseArticleArguments(_ modelArguments: [String: Any]) throws -> [String: Any] {
        guard let articleId = nonEmptyString(modelArguments["articleId"]) else {
            throw WingmanToolRefusal.invalidArguments(toolName: readKnowledgeBaseArticleToolName, reason: "articleId is required; find the article with \(searchKnowledgeBaseToolName) first.")
        }
        return ["articleId": articleId]
    }

    // MARK: - Result condensing

    /// Fields of a ticket the model needs to answer or draft. Everything else the gateway
    /// returns (colours, icons, internal ids) is dropped to keep tool results small.
    private static let ticketFieldsKeptForModel = [
        "ticket_id", "ticket_number", "subject", "status", "priority", "tenant_name", "tenant_slug",
        "requester_name", "requester_email", "agent_name", "group_name", "category_name",
        "created_at", "updated_at", "last_message_at", "last_message_by", "sla_due_at", "sla_breached_at", "ai_summary",
    ]

    /// Fields of a knowledge base article the model needs to pick one and cite it. The body is
    /// handled separately: search results never carry it, a read carries it capped.
    private static let knowledgeBaseArticleFieldsKeptForModel = [
        "article_id", "title", "slug", "summary", "ai_summary", "category_name", "tenant_slug", "is_global", "tags", "updated_at", "url",
    ]

    /// Reduces a gateway tool result to what the model needs. Unknown shapes pass through
    /// untouched, so a gateway change never makes a tool unusable.
    static func condenseResult(toolName: String, resultText: String) -> String {
        switch toolName {
        case listTicketsToolName:
            return condenseTicketListResult(resultText) ?? resultText
        case searchKnowledgeBaseToolName:
            return condenseKnowledgeBaseSearchResult(resultText) ?? resultText
        case readKnowledgeBaseArticleToolName:
            return condenseKnowledgeBaseArticleResult(resultText) ?? resultText
        default:
            return resultText
        }
    }

    private static func condenseTicketListResult(_ resultText: String) -> String? {
        guard let resultObject = jsonObject(fromResultText: resultText),
              let tickets = resultObject["tickets"] as? [[String: Any]] else {
            return nil
        }
        let condensedTickets = tickets.map { keepFields(ticketFieldsKeptForModel, of: $0) }
        var condensedResult: [String: Any] = ["tickets": condensedTickets]
        if let pagination = resultObject["pagination"] {
            condensedResult["pagination"] = pagination
        }
        return jsonText(fromResultObject: condensedResult)
    }

    private static func condenseKnowledgeBaseSearchResult(_ resultText: String) -> String? {
        guard let resultObject = jsonObject(fromResultText: resultText),
              let articles = resultObject["articles"] as? [[String: Any]] else {
            return nil
        }
        let condensedArticles = articles.map { keepFields(knowledgeBaseArticleFieldsKeptForModel, of: $0) }
        var condensedResult: [String: Any] = ["articles": condensedArticles]
        for fieldName in ["tenant", "total"] {
            if let value = resultObject[fieldName], !(value is NSNull) {
                condensedResult[fieldName] = value
            }
        }
        return jsonText(fromResultObject: condensedResult)
    }

    private static func condenseKnowledgeBaseArticleResult(_ resultText: String) -> String? {
        guard let resultObject = jsonObject(fromResultText: resultText),
              let article = resultObject["article"] as? [String: Any] else {
            return nil
        }
        var condensedArticle = keepFields(knowledgeBaseArticleFieldsKeptForModel, of: article)
        // Plain text reads better aloud than the stored HTML or markdown; fall back to the stored
        // body when the plain rendering is missing.
        let articleBody = nonEmptyString(article["content_plain"]) ?? nonEmptyString(article["content"]) ?? ""
        if articleBody.count > maximumKnowledgeBaseArticleCharacters {
            condensedArticle["content"] = String(articleBody.prefix(maximumKnowledgeBaseArticleCharacters)) + knowledgeBaseArticleTruncationNotice
        } else {
            condensedArticle["content"] = articleBody
        }
        return jsonText(fromResultObject: ["article": condensedArticle])
    }

    private static func keepFields(_ fieldNames: [String], of sourceObject: [String: Any]) -> [String: Any] {
        var keptObject: [String: Any] = [:]
        for fieldName in fieldNames {
            if let value = sourceObject[fieldName], !(value is NSNull) {
                keptObject[fieldName] = value
            }
        }
        return keptObject
    }

    private static func jsonObject(fromResultText resultText: String) -> [String: Any]? {
        guard let resultData = resultText.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
    }

    private static func jsonText(fromResultObject resultObject: [String: Any]) -> String? {
        guard let resultData = try? JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys]) else { return nil }
        return String(data: resultData, encoding: .utf8)
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
