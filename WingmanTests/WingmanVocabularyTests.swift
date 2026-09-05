//
//  WingmanVocabularyTests.swift
//  WingmanTests
//
//  Covers the taught vocabulary: the keyterms handed to speech recognition, the transcript
//  rewrite to the canonical spelling, the pronunciation rewrite for the voice, the prompt
//  section, the tool policy's use of it and the JSON store. No network, no app running.
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
        #expect(section.hasPrefix("\nvocabulary the user has taught you:\n"))
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

    @Test func theStoreSeedsTheBuiltInTermsAndPersistsAdditionsAndRemovals() throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wingman-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL.deletingLastPathComponent()) }

        let firstStore = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(firstStore.vocabulary == WingmanVocabulary.builtIn)
        #expect(!FileManager.default.fileExists(atPath: temporaryFileURL.path))

        #expect(!firstStore.addTerm(canonicalSpelling: "   ", spokenFormsText: "x", meaning: ""))
        #expect(firstStore.addTerm(canonicalSpelling: " VMO ", spokenFormsText: "vee em oh, vmo", meaning: " the crew scheduling system "))
        #expect(firstStore.vocabulary.terms.count == 2)
        #expect(firstStore.vocabulary.terms[1].canonicalSpelling == "VMO")
        #expect(firstStore.vocabulary.terms[1].spokenForms == ["vee em oh", "vmo"])
        #expect(firstStore.vocabulary.terms[1].meaning == "the crew scheduling system")

        let secondStore = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(secondStore.vocabulary == firstStore.vocabulary)

        secondStore.removeTerm(withID: try #require(secondStore.vocabulary.terms.first?.id))
        let thirdStore = WingmanVocabularyStore(vocabularyFileURL: temporaryFileURL)
        #expect(thirdStore.vocabulary.terms.map(\.canonicalSpelling) == ["VMO"])
    }

    @Test func spokenFormsSplitOnCommasAndDropBlanks() {
        #expect(WingmanVocabularyStore.spokenForms(fromCommaSeparatedText: "Flex, flecks ,, ") == ["Flex", "flecks"])
        #expect(WingmanVocabularyStore.spokenForms(fromCommaSeparatedText: "") == [])
    }
}
