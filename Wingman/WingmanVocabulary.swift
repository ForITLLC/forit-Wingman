//
//  WingmanVocabulary.swift
//  Wingman
//
//  Terms Wingman knows: how each one is written, how people say it and what it means. ForIT Support
//  is the source of truth for the list (Ben, 2026-09-05: "I still hate that you have a dictionary
//  where you can delete terms from versus something that's pulled in from ForIT support"): the app
//  pulls it through the gateway after sign-in and again once it is an hour old, and nothing is
//  added or removed on the Mac. Until Support has published a list, the built-in seed (FL3XX said
//  as "Flex", Ben: "fl3xx is Flex, how can we train on that?") applies. The vocabulary is used in
//  four places, all pure functions here so they can be unit-tested without the app running:
//    1. Apple Speech contextual keyterms, so the recogniser favours these spellings.
//    2. The transcript: every spoken form is rewritten to the canonical spelling before the model
//       sees it, so "how do I turn on TSA screening in Flex" reaches the model as "... in FL3XX".
//    3. The system prompt: a vocabulary section so the model knows what the terms mean and uses
//       the canonical spelling in tool calls.
//    4. Spoken replies: the canonical spelling is replaced by the first spoken form before
//       text-to-speech, so the reply says "Flex" instead of spelling out F-L-3-X-X.
//  The last list fetched is kept as a JSON file in Application Support so a launch without the
//  gateway still knows the terms.
//

import Combine
import Foundation

/// One taught term.
struct WingmanVocabularyTerm: Codable, Equatable, Identifiable {
    var id: UUID

    /// The spelling the model, the knowledge base and the tools use, e.g. "FL3XX".
    var canonicalSpelling: String

    /// What people say for it, e.g. ["Flex"]. The first spoken form is also how spoken replies
    /// pronounce the term.
    var spokenForms: [String]

    /// One line for the model about what the term is, e.g. "the flight operations and scheduling
    /// platform ForIT supports". May be empty.
    var meaning: String

    init(id: UUID = UUID(), canonicalSpelling: String, spokenForms: [String], meaning: String) {
        self.id = id
        self.canonicalSpelling = canonicalSpelling
        self.spokenForms = spokenForms
        self.meaning = meaning
    }
}

/// The whole taught vocabulary and the four ways it is applied.
struct WingmanVocabulary: Codable, Equatable {
    var terms: [WingmanVocabularyTerm]

    /// What a fresh install starts with. FL3XX is the flight operations platform ForIT supports and
    /// the one term Ben asked for by name.
    static let builtInTerms: [WingmanVocabularyTerm] = [
        WingmanVocabularyTerm(
            canonicalSpelling: "FL3XX",
            spokenForms: ["Flex"],
            meaning: "the flight operations and scheduling platform ForIT supports; its how-to articles are in the ForIT knowledge base"
        )
    ]

    static let builtIn = WingmanVocabulary(terms: builtInTerms)

    // MARK: - 1. Speech recognition keyterms

    /// Every canonical spelling and every spoken form, in vocabulary order, for Apple Speech's
    /// contextual strings. Blank entries are dropped; the dictation manager de-duplicates.
    func transcriptionKeyterms() -> [String] {
        var keyterms: [String] = []
        for term in terms {
            keyterms.append(term.canonicalSpelling)
            keyterms.append(contentsOf: term.spokenForms)
        }
        return keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 2. Transcript rewrite

    /// The transcript with every spoken form replaced by its canonical spelling. Whole words only,
    /// case-insensitive, longest spoken form first so "Flex ops" cannot eat "Flex". A spoken form
    /// that equals its canonical spelling is left alone.
    func canonicalisingSpokenForms(in transcript: String) -> String {
        var rewrittenTranscript = transcript
        for (spokenForm, canonicalSpelling) in spokenFormReplacementsLongestFirst() {
            rewrittenTranscript = Self.replacingWholeWords(
                matching: spokenForm,
                with: canonicalSpelling,
                in: rewrittenTranscript
            )
        }
        return rewrittenTranscript
    }

    private func spokenFormReplacementsLongestFirst() -> [(spokenForm: String, canonicalSpelling: String)] {
        var replacements: [(spokenForm: String, canonicalSpelling: String)] = []
        for term in terms {
            let canonicalSpelling = term.canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalSpelling.isEmpty else { continue }
            for spokenForm in term.spokenForms {
                let trimmedSpokenForm = spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSpokenForm.isEmpty,
                      trimmedSpokenForm.caseInsensitiveCompare(canonicalSpelling) != .orderedSame else { continue }
                replacements.append((spokenForm: trimmedSpokenForm, canonicalSpelling: canonicalSpelling))
            }
        }
        return replacements.sorted { $0.spokenForm.count > $1.spokenForm.count }
    }

    // MARK: - 4. Pronunciation for spoken replies

    /// The reply text with every canonical spelling replaced by the term's first spoken form, so the
    /// voice says the term the way the user does. Whole words only, case-insensitive.
    func pronouncingCanonicalSpellings(in replyText: String) -> String {
        var pronouncedText = replyText
        for term in terms {
            let canonicalSpelling = term.canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalSpelling.isEmpty,
                  let pronunciation = term.spokenForms
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }),
                  pronunciation.caseInsensitiveCompare(canonicalSpelling) != .orderedSame else { continue }
            pronouncedText = Self.replacingWholeWords(matching: canonicalSpelling, with: pronunciation, in: pronouncedText)
        }
        return pronouncedText
    }

    // MARK: - 3. System prompt section

    /// The prompt section the model reads, or an empty string when there are no usable terms.
    /// Written in the same lowercase spoken style as the rest of the voice prompt.
    func systemPromptSection() -> String {
        let usableTerms = terms.filter {
            !$0.canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usableTerms.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("")
        lines.append("vocabulary from ForIT Support:")
        for term in usableTerms {
            let canonicalSpelling = term.canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
            let spokenForms = term.spokenForms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var line = "- \(canonicalSpelling)"
            if !spokenForms.isEmpty {
                let quotedSpokenForms = spokenForms.map { "\"\($0)\"" }.joined(separator: " or ")
                line += ", which the user says as \(quotedSpokenForms)"
            }
            let meaning = term.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !meaning.isEmpty {
                line += ": \(meaning)"
            }
            lines.append(line)
        }
        lines.append("these are products and systems, never a client's tenant. write them with the spelling above in tool calls. when you search the knowledge base for one of them, search by the topic words (\"tsa screening\", \"crew duty\") rather than the product name, because every article about the product contains its name and the topic is what narrows the search.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool policy support

    /// True when `text` is one of the canonical spellings or spoken forms (whole string, trimmed,
    /// case-insensitive). The tool policy uses it to keep a product name out of the tenant argument.
    func containsTerm(matching text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        for term in terms {
            if term.canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(candidate) == .orderedSame {
                return true
            }
            for spokenForm in term.spokenForms
            where spokenForm.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(candidate) == .orderedSame {
                return true
            }
        }
        return false
    }

    // MARK: - The list ForIT Support publishes

    /// The gateway tool that returns ForIT Support's vocabulary (for-Support
    /// `GET /api/admin/vocabulary`, contract in docs/common-proposed/for-support-vocabulary-api.md).
    /// Never described to the model: the app calls it itself, outside any spoken turn.
    static let foritSupportToolName = "support_listVocabulary"

    /// The terms in a `support_listVocabulary` result:
    /// `{"terms":[{"term_id","canonical_spelling","spoken_forms":[…],"meaning"}]}`.
    /// nil when the text is not that shape (an error text, another route's answer), so the caller
    /// keeps the list it has. A row without a canonical spelling is dropped; spoken forms may also
    /// arrive as one comma-separated string. Support's `term_id` becomes the term's id when it is a
    /// UUID, so a row keeps its identity from one fetch to the next.
    static func terms(fromForITSupportResultText resultText: String) -> [WingmanVocabularyTerm]? {
        guard let resultData = resultText.data(using: .utf8),
              let resultObject = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let termObjects = resultObject["terms"] as? [[String: Any]] else {
            return nil
        }

        var terms: [WingmanVocabularyTerm] = []
        for termObject in termObjects {
            let canonicalSpelling = (termObject["canonical_spelling"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !canonicalSpelling.isEmpty else { continue }

            let spokenForms: [String]
            if let spokenFormList = termObject["spoken_forms"] as? [String] {
                spokenForms = spokenFormList
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else if let spokenFormText = termObject["spoken_forms"] as? String {
                spokenForms = Self.spokenForms(fromCommaSeparatedText: spokenFormText)
            } else {
                spokenForms = []
            }

            let meaning = (termObject["meaning"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let termID = (termObject["term_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            terms.append(WingmanVocabularyTerm(
                id: termID,
                canonicalSpelling: canonicalSpelling,
                spokenForms: spokenForms,
                meaning: meaning
            ))
        }
        return terms
    }

    /// Splits "Flex, flecks" into ["Flex", "flecks"], dropping blanks.
    static func spokenForms(fromCommaSeparatedText text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Whole-word replacement

    /// Replaces `word` wherever it stands on its own (not inside another word), ignoring case.
    /// Word edges are anything that is not a letter or a digit, so "FL3XX," and "(Flex)" match
    /// while "Flexible" does not.
    static func replacingWholeWords(matching word: String, with replacement: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let wholeRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regularExpression.stringByReplacingMatches(
            in: text,
            options: [],
            range: wholeRange,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

/// Where the vocabulary on this Mac came from.
enum WingmanVocabularySource: Equatable {
    /// The built-in seed (`WingmanVocabulary.builtInTerms`): a fresh install, or ForIT Support has
    /// not published a list yet.
    case builtIn

    /// The list ForIT Support published, fetched through the gateway at `fetchedAt`.
    case foritSupport(fetchedAt: Date)
}

/// What the store writes to disk: the terms and where they came from, so the next launch starts
/// from the last list ForIT Support published rather than from the seed.
struct WingmanStoredVocabulary: Codable, Equatable {
    static let foritSupportSourceName = "forit-support"

    var terms: [WingmanVocabularyTerm]
    var source: String
    var fetchedAt: Date?
}

/// Owns the vocabulary on this Mac. ForIT Support is the source of truth: `CompanionManager` fetches
/// its list through the gateway and hands it to `replaceWithTermsFromForITSupport`; nothing is added
/// or removed here, because a term is managed in ForIT Support for every Wingman at once. The last
/// list is kept in one JSON file in Application Support. A file written by an earlier build, which
/// let the person edit terms locally, is not carried forward: those terms were never Support's.
@MainActor
final class WingmanVocabularyStore: ObservableObject {
    @Published private(set) var vocabulary: WingmanVocabulary
    @Published private(set) var source: WingmanVocabularySource

    private let vocabularyFileURL: URL

    /// The default file: ~/Library/Application Support/io.forit.wingman/vocabulary.json.
    /// `nonisolated` because it is the initializer's default argument, and a default argument is
    /// evaluated outside the main actor; it touches no state of the store anyway.
    nonisolated static func defaultVocabularyFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory
            .appendingPathComponent("io.forit.wingman", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    init(vocabularyFileURL: URL = WingmanVocabularyStore.defaultVocabularyFileURL()) {
        self.vocabularyFileURL = vocabularyFileURL
        if let storedVocabulary = Self.loadStoredVocabulary(from: vocabularyFileURL),
           storedVocabulary.source == WingmanStoredVocabulary.foritSupportSourceName,
           let fetchedAt = storedVocabulary.fetchedAt,
           !storedVocabulary.terms.isEmpty {
            self.vocabulary = WingmanVocabulary(terms: storedVocabulary.terms)
            self.source = .foritSupport(fetchedAt: fetchedAt)
        } else {
            self.vocabulary = WingmanVocabulary.builtIn
            self.source = .builtIn
        }
    }

    /// When the list ForIT Support published was last fetched; nil while the seed applies.
    var lastFetchedFromForITSupportAt: Date? {
        if case .foritSupport(let fetchedAt) = source {
            return fetchedAt
        }
        return nil
    }

    /// True when the list should be fetched again: never fetched, or `maximumAge` or older.
    func isDueForRefresh(maximumAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let fetchedAt = lastFetchedFromForITSupportAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= maximumAge
    }

    /// Replaces the vocabulary with the list ForIT Support published and writes it to disk.
    /// An empty list means Support has published nothing yet; it changes nothing and returns false,
    /// so an unseeded Support cannot erase the built-in FL3XX term.
    @discardableResult
    func replaceWithTermsFromForITSupport(_ publishedTerms: [WingmanVocabularyTerm], fetchedAt: Date) -> Bool {
        guard !publishedTerms.isEmpty else { return false }
        vocabulary = WingmanVocabulary(terms: publishedTerms)
        source = .foritSupport(fetchedAt: fetchedAt)
        saveStoredVocabulary()
        return true
    }

    private static func loadStoredVocabulary(from fileURL: URL) -> WingmanStoredVocabulary? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WingmanStoredVocabulary.self, from: data)
    }

    private func saveStoredVocabulary() {
        do {
            let directoryURL = vocabularyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let storedVocabulary = WingmanStoredVocabulary(
                terms: vocabulary.terms,
                source: WingmanStoredVocabulary.foritSupportSourceName,
                fetchedAt: lastFetchedFromForITSupportAt
            )
            let data = try encoder.encode(storedVocabulary)
            try data.write(to: vocabularyFileURL, options: [.atomic])
        } catch {
            print("⚠️ Could not save the vocabulary to \(vocabularyFileURL.path): \(error)")
        }
    }
}
