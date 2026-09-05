//
//  WingmanVocabulary.swift
//  Wingman
//
//  Terms the user teaches Wingman: how each one is written, how people say it and what it means.
//  Ben, 2026-09-05: "fl3xx is Flex, how can we train on that?" and "we'll make this so it could be
//  any vocabulary that we could teach". The vocabulary is used in four places, all pure functions
//  here so they can be unit-tested without the app running:
//    1. Apple Speech contextual keyterms, so the recogniser favours these spellings.
//    2. The transcript: every spoken form is rewritten to the canonical spelling before the model
//       sees it, so "how do I turn on TSA screening in Flex" reaches the model as "... in FL3XX".
//    3. The system prompt: a vocabulary section so the model knows what the terms mean and uses
//       the canonical spelling in tool calls.
//    4. Spoken replies: the canonical spelling is replaced by the first spoken form before
//       text-to-speech, so the reply says "Flex" instead of spelling out F-L-3-X-X.
//  Nothing leaves the Mac: the vocabulary is a JSON file in Application Support.
//

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
        lines.append("vocabulary the user has taught you:")
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

/// Owns the vocabulary on disk. One JSON file per Mac, in Application Support, seeded with the
/// built-in terms on first use. Every change is written straight away.
@MainActor
final class WingmanVocabularyStore: ObservableObject {
    @Published private(set) var vocabulary: WingmanVocabulary

    private let vocabularyFileURL: URL

    /// The default file: ~/Library/Application Support/io.forit.wingman/vocabulary.json.
    static func defaultVocabularyFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory
            .appendingPathComponent("io.forit.wingman", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    init(vocabularyFileURL: URL = WingmanVocabularyStore.defaultVocabularyFileURL()) {
        self.vocabularyFileURL = vocabularyFileURL
        self.vocabulary = Self.loadVocabulary(from: vocabularyFileURL) ?? WingmanVocabulary.builtIn
    }

    /// Adds a term. `spokenFormsText` is what the user typed in the panel: spoken forms separated by
    /// commas. Returns false, and changes nothing, when the canonical spelling is blank.
    @discardableResult
    func addTerm(canonicalSpelling: String, spokenFormsText: String, meaning: String) -> Bool {
        let trimmedCanonicalSpelling = canonicalSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCanonicalSpelling.isEmpty else { return false }
        let spokenForms = Self.spokenForms(fromCommaSeparatedText: spokenFormsText)
        let newTerm = WingmanVocabularyTerm(
            canonicalSpelling: trimmedCanonicalSpelling,
            spokenForms: spokenForms,
            meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        vocabulary.terms.append(newTerm)
        saveVocabulary()
        return true
    }

    func removeTerm(withID termID: UUID) {
        vocabulary.terms.removeAll { $0.id == termID }
        saveVocabulary()
    }

    /// Splits "Flex, flecks" into ["Flex", "flecks"], dropping blanks.
    static func spokenForms(fromCommaSeparatedText text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func loadVocabulary(from fileURL: URL) -> WingmanVocabulary? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WingmanVocabulary.self, from: data)
    }

    private func saveVocabulary() {
        do {
            let directoryURL = vocabularyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(vocabulary)
            try data.write(to: vocabularyFileURL, options: [.atomic])
        } catch {
            print("⚠️ Could not save the vocabulary to \(vocabularyFileURL.path): \(error)")
        }
    }
}
