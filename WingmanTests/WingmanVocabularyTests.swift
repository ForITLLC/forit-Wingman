//
//  WingmanVocabularyTests.swift
//  WingmanTests
//
//  Covers the vocabulary: the keyterms handed to speech recognition, the transcript rewrite to
//  the canonical spelling, the pronunciation rewrite for the voice, the prompt section, the tool
//  policy's use of it, the parsing of ForIT Support's list and the JSON store. No network, no app
//  running.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanVocabularyTests {

    private let vocabulary = WingmanVocabulary(terms: [
        WingmanVocabularyTerm(canonicalSpelling: "FL3XX", spokenForms: ["Flex"], meaning: "the flight operations platform"),
        WingmanVocabularyTerm(canonicalSpelling: "Great North", spokenForms: ["GNA", "Great North Airlines"], meaning: ""),
    ])

    // MARK: - Speech recognition

    @Test func keytermsCarryEverySpellingAndSpokenForm() {
        #expect(vocabulary.transcriptionKeyterms() == ["FL3XX", "Flex", "Great North", "GNA", "Great North Airlines"])
        #expect(WingmanVocabulary.builtIn.transcriptionKeyterms() == ["FL3XX", "Flex"])
    }

    // MARK: - Transcript

    @Test func spokenFormsBecomeTheCanonicalSpellingAsWholeWordsOnly() {
        let transcript = "How do I turn on TSA screening in flex? Flex, not flexible. (Flex)"
        #expect(vocabulary.canonicalisingSpokenForms(in: transcript) == "How do I turn on TSA screening in FL3XX? FL3XX, not flexible. (FL3XX)")
    }

    @Test func theLongestSpokenFormWinsSoAPhraseIsNotEatenByItsFirstWord() {
        #expect(vocabulary.canonicalisingSpokenForms(in: "open tickets for Great North Airlines and GNA") == "open tickets for Great North and Great North")
    }

    @Test func aTranscriptWithoutTermsIsUnchanged() {
        #expect(vocabulary.canonicalisingSpokenForms(in: "what is on my screen") == "what is on my screen")
        #expect(WingmanVocabulary(terms: []).canonicalisingSpokenForms(in: "Flex") == "Flex")
    }

    // MARK: - Voice

    @Test func theVoiceSaysTheFirstSpokenFormInsteadOfTheCanonicalSpelling() {
        #expect(vocabulary.pronouncingCanonicalSpellings(in: "In FL3XX, open Settings. fl3xx.") == "In Flex, open Settings. Flex.")
        #expect(vocabulary.pronouncingCanonicalSpellings(in: "Great North has two tickets.") == "GNA has two tickets.")
    }

    @Test func aTermWithNoSpokenFormIsSpokenAsWritten() {
        let silentVocabulary = WingmanVocabulary(terms: [WingmanVocabularyTerm(canonicalSpelling: "VMO", spokenForms: [], meaning: "")])
        #expect(silentVocabulary.pronouncingCanonicalSpellings(in: "VMO shows it.") == "VMO shows it.")
        #expect(silentVocabulary.canonicalisingSpokenForms(in: "VMO shows it.") == "VMO shows it.")
    }

    // MARK: - Prompt

    @Test func thePromptSectionNamesEachTermItsSpokenFormsAndItsMeaning() {
        let section = vocabulary.systemPromptSection()
        #expect(section.hasPrefix("\nvocabulary from ForIT Support:\n"))
        #expect(section.contains("- FL3XX, which the user says as \"Flex\": the flight operations platform\n"))
        #expect(section.contains("- Great North, which the user says as \"GNA\" or \"Great North Airlines\"\n"))
        #expect(section.contains("never a client's tenant"))
        #expect(WingmanVocabulary(terms: []).systemPromptSection() == "")
    }

    // MARK: - Tool policy

    @Test func aProductNameGivenAsTheTenantFallsBackToTheDefaultTenant() throws {
        let signedInAccount = WingmanSignedInAccount(displayName: "Sam Staff", emailAddress: "sam@forit.io")
        let productAsTenant = try WingmanToolCatalog.prepareCall(
            toolName: "support_searchKbArticles",
            modelArguments: ["q": "tsa screening", "tenant": "FL3XX"],
            signedInAccount: signedInAccount,
            vocabulary: vocabulary
        )
        #expect(productAsTenant.arguments["tenant"] as? String == "forit")

        let spokenFormAsTenant = try WingmanToolCatalog.prepareCall(
            toolName: "support_searchKbArticles",
            modelArguments: ["q": "tsa screening", "tenant": "flex"],
            signedInAccount: signedInAccount,
            vocabulary: vocabulary
        )
        #expect(spokenFormAsTenant.arguments["tenant"] as? String == "forit")

        let realTenant = try WingmanToolCatalog.prepareCall(
            toolName: "support_searchKbArticles",
            modelArguments: ["q": "tsa screening", "tenant": "gna"],
            signedInAccount: signedInAccount,
            vocabulary: WingmanVocabulary.builtIn
        )
        #expect(realTenant.arguments["tenant"] as? String == "gna")
    }

    @Test func containsTermMatchesSpellingsAndSpokenFormsWholeAndCaseInsensitively() {
        #expect(vocabulary.containsTerm(matching: " fl3xx "))
        #expect(vocabulary.containsTerm(matching: "great north airlines"))
        #expect(!vocabulary.containsTerm(matching: "fl3xx ops"))
        #expect(!vocabulary.containsTerm(matching: ""))
    }

    // MARK: - Failure labels

    @Test func theToolFailureLabelCarriesTheHttpStatusAndNothingElse() {
        #expect(WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "HTTP error 401: {\"detail\":\"invalid assertion\"}") == "tool_error_http_401")
        #expect(WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "Upstream failed with status code 404") == "tool_error_http_404")
        #expect(WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "{\"status\": 403, \"detail\": \"user not enabled\"}") == "tool_error_http_403")
        #expect(WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "ticket 12345 not found") == "tool_error")
        #expect(WingmanGatewayToolClient.failureOutcomeLabel(forErrorResultText: "") == "tool_error")
    }

    // MARK: - Store

    @Test func theStoreSeedsTheBuiltInTermsUntilForITSupportPublishesAList() throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wingman-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL.deletingLastPathComponent()) }

        let firstStore = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(firstStore.vocabulary == WingmanVocabulary.builtIn)
        #expect(firstStore.source == .builtIn)
        #expect(firstStore.lastFetchedFromForITSupportAt == nil)
        #expect(firstStore.isDueForRefresh(maximumAge: 3600))
        #expect(!FileManager.default.fileExists(atPath: temporaryFileURL.path))

        // An empty list is "nothing published yet": the seed stays and nothing is written.
        #expect(!firstStore.replaceWithTermsFromForITSupport([], fetchedAt: Date()))
        #expect(firstStore.vocabulary == WingmanVocabulary.builtIn)
        #expect(firstStore.source == .builtIn)
        #expect(!FileManager.default.fileExists(atPath: temporaryFileURL.path))

        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let publishedTerms = [
            WingmanVocabularyTerm(canonicalSpelling: "VMO", spokenForms: ["vee em oh", "vmo"], meaning: "the crew scheduling system"),
        ]
        #expect(firstStore.replaceWithTermsFromForITSupport(publishedTerms, fetchedAt: fetchedAt))
        #expect(firstStore.vocabulary.terms == publishedTerms)
        #expect(firstStore.source == .foritSupport(fetchedAt: fetchedAt))
        #expect(!firstStore.isDueForRefresh(maximumAge: 3600, now: fetchedAt.addingTimeInterval(1800)))
        #expect(firstStore.isDueForRefresh(maximumAge: 3600, now: fetchedAt.addingTimeInterval(3600)))

        let secondStore = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(secondStore.vocabulary == firstStore.vocabulary)
        #expect(secondStore.lastFetchedFromForITSupportAt == fetchedAt)
    }

    @Test func aFileFromABuildThatLetPeopleEditTermsLocallyIsNotCarriedForward() throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wingman-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: temporaryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // The shape the 0.1.5x builds wrote: terms only, added and removed in the panel.
        let locallyEditedFile = """
        {"terms":[{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","canonicalSpelling":"Local","spokenForms":["loco"],"meaning":""}]}
        """
        try Data(locallyEditedFile.utf8).write(to: temporaryFileURL)

        let store = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(store.vocabulary == WingmanVocabulary.builtIn)
        #expect(store.source == .builtIn)
    }

    // MARK: - ForIT Support's list

    @Test func theSupportResultBecomesTermsAndAnythingElseBecomesNil() throws {
        let resultText = """
        {"terms":[\
        {"term_id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","canonical_spelling":" FL3XX ","spoken_forms":["Flex","  "],"meaning":" the flight operations platform "},\
        {"term_id":"not-a-uuid","canonical_spelling":"VMO","spoken_forms":"vee em oh, vmo"},\
        {"canonical_spelling":"   ","spoken_forms":["blank"],"meaning":"dropped"}\
        ],"total":3}
        """
        let terms = try #require(WingmanVocabulary.terms(fromForITSupportResultText: resultText))
        #expect(terms.count == 2)
        #expect(terms[0].id == UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))
        #expect(terms[0].canonicalSpelling == "FL3XX")
        #expect(terms[0].spokenForms == ["Flex"])
        #expect(terms[0].meaning == "the flight operations platform")
        #expect(terms[1].canonicalSpelling == "VMO")
        #expect(terms[1].spokenForms == ["vee em oh", "vmo"])
        #expect(terms[1].meaning == "")

        #expect(WingmanVocabulary.terms(fromForITSupportResultText: "{\"terms\":[]}") == [])
        #expect(WingmanVocabulary.terms(fromForITSupportResultText: "Error: 404 Not Found") == nil)
        #expect(WingmanVocabulary.terms(fromForITSupportResultText: "{\"articles\":[]}") == nil)
    }

    @Test func spokenFormsSplitOnCommasAndDropBlanks() {
        #expect(WingmanVocabulary.spokenForms(fromCommaSeparatedText: "Flex, flecks ,, ") == ["Flex", "flecks"])
        #expect(WingmanVocabulary.spokenForms(fromCommaSeparatedText: "") == [])
    }
}
