//
//  WingmanSpokenSentenceSplitterTests.swift
//  WingmanTests
//
//  Covers the streamed-reply sentence splitter: early first sentence, batching of later ones,
//  the pointing tag never being spoken, and the final flush.
//

import Foundation
import Testing
@testable import Wingman

struct WingmanSpokenSentenceSplitterTests {

    @Test func firstSentenceIsReleasedAtItsBoundaryHoweverShort() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "Sure") == [])
        #expect(splitter.sentencesReady(inAccumulatedText: "Sure.") == [])
        #expect(splitter.sentencesReady(inAccumulatedText: "Sure. The ticket") == ["Sure."])
    }

    @Test func laterSentencesWaitUntilEnoughTextIsPending() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "Yes. It is open. ") == ["Yes."])
        // "It is open." is far below the later-chunk minimum, so it waits for more text.
        let longerText = "Yes. It is open. The customer wrote back yesterday afternoon asking for an update on the invoice. Next"
        let readySentences = splitter.sentencesReady(inAccumulatedText: longerText)
        #expect(readySentences == ["It is open. The customer wrote back yesterday afternoon asking for an update on the invoice."])
    }

    @Test func periodInsideANumberIsNotABoundary() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "Version 3.") == [])
        #expect(splitter.sentencesReady(inAccumulatedText: "Version 3.5 is out") == [])
        #expect(splitter.flushRemaining(inAccumulatedText: "Version 3.5 is out.") == "Version 3.5 is out.")
    }

    @Test func newlineIsABoundary() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "Two things\nFirst") == ["Two things"])
    }

    @Test func nothingFromThePointingTagOnwardIsSpoken() {
        var splitter = WingmanSpokenSentenceSplitter()
        let fullText = "Click Save. [POINT:120,340:Save button:screen1]"
        #expect(splitter.sentencesReady(inAccumulatedText: fullText) == ["Click Save."])
        #expect(splitter.flushRemaining(inAccumulatedText: fullText) == nil)
    }

    @Test func partialPointingTagAtTheEndIsHeldBack() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "Click Save. [PO") == ["Click Save."])
        #expect(splitter.flushRemaining(inAccumulatedText: "Click Save. [POINT:none]") == nil)
    }

    @Test func bracketThatIsNotTheTagIsSpokenOnceResolved() {
        var splitter = WingmanSpokenSentenceSplitter()
        #expect(splitter.sentencesReady(inAccumulatedText: "See [") == [])
        #expect(splitter.flushRemaining(inAccumulatedText: "See [draft] below.") == "See [draft] below.")
    }

    @Test func flushReturnsOnlyWhatWasNotAlreadyReleased() {
        var splitter = WingmanSpokenSentenceSplitter()
        _ = splitter.sentencesReady(inAccumulatedText: "Done. And")
        #expect(splitter.flushRemaining(inAccumulatedText: "Done. And one more thing") == "And one more thing")
        #expect(splitter.flushRemaining(inAccumulatedText: "Done. And one more thing") == nil)
    }

    @Test func speakablePortionKeepsOrdinaryText() {
        #expect(WingmanSpokenSentenceSplitter.speakablePortion(of: "Hello there") == "Hello there")
        #expect(WingmanSpokenSentenceSplitter.speakablePortion(of: "Hello [POINT:1,2:x:screen1]") == "Hello ")
        #expect(WingmanSpokenSentenceSplitter.speakablePortion(of: "Hello [POIN") == "Hello ")
    }
}
