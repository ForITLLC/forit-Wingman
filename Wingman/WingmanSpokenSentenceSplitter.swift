//
//  WingmanSpokenSentenceSplitter.swift
//  Wingman
//
//  Cuts the model's streamed reply into sentences that can be sent to text-to-speech before the
//  reply is finished, so the first sentence is heard while the rest is still being written.
//  Pure and unit-tested: it never speaks, it only decides which text is ready to be spoken.
//

import Foundation

struct WingmanSpokenSentenceSplitter {
    /// The pointing tag the model appends after its spoken text (see `parsePointingCoordinates`).
    /// Nothing from it onward is ever spoken, and a partial tag at the end of the stream ("[PO")
    /// is held back until the stream shows whether it is the tag or ordinary text.
    static let pointingTagPrefix = "[POINT"

    /// The first sentence is released at the first boundary, however short, so speech starts as
    /// early as possible. Later sentences wait until at least this many characters are pending,
    /// so the synthesiser gets whole clauses instead of a stutter of two-word fragments.
    static let minimumLaterChunkCharacterCount = 60

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// How many characters of the speakable text have already been handed out.
    private var releasedCharacterCount = 0
    private var hasReleasedFirstChunk = false

    init() {}

    /// Feeds the whole reply text received so far (accumulated, not a delta) and returns the
    /// sentences that became ready since the last call, in order. Empty when nothing new is ready.
    mutating func sentencesReady(inAccumulatedText accumulatedText: String) -> [String] {
        let speakableCharacters = Array(Self.speakablePortion(of: accumulatedText))
        guard speakableCharacters.count > releasedCharacterCount else { return [] }

        var readySentences: [String] = []
        var chunkStartIndex = releasedCharacterCount
        var position = releasedCharacterCount

        // A boundary needs a following character: a period at the very end of the stream may be
        // "3." with "5" still to come, so it waits for the next chunk (or the final flush).
        while position < speakableCharacters.count - 1 {
            let character = speakableCharacters[position]
            let followingCharacter = speakableCharacters[position + 1]
            let endsSentence = Self.sentenceTerminators.contains(character) && followingCharacter.isWhitespace
            let isBoundary = endsSentence || character.isNewline

            if isBoundary {
                let chunkText = String(speakableCharacters[chunkStartIndex...position])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if chunkText.isEmpty {
                    chunkStartIndex = position + 1
                } else {
                    let minimumCharacterCount = hasReleasedFirstChunk ? Self.minimumLaterChunkCharacterCount : 1
                    if chunkText.count >= minimumCharacterCount {
                        readySentences.append(chunkText)
                        hasReleasedFirstChunk = true
                        chunkStartIndex = position + 1
                    }
                }
            }
            position += 1
        }

        releasedCharacterCount = chunkStartIndex
        return readySentences
    }

    /// Releases whatever speakable text is still pending once the stream has ended. Returns nil
    /// when nothing is left (or only whitespace).
    mutating func flushRemaining(inAccumulatedText accumulatedText: String) -> String? {
        let speakableCharacters = Array(Self.speakablePortion(of: accumulatedText))
        guard speakableCharacters.count > releasedCharacterCount else { return nil }
        let remainingText = String(speakableCharacters[releasedCharacterCount...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        releasedCharacterCount = speakableCharacters.count
        hasReleasedFirstChunk = true
        return remainingText.isEmpty ? nil : remainingText
    }

    /// The part of the text that may be spoken: everything before the pointing tag, minus a
    /// trailing fragment that could still turn into the tag.
    static func speakablePortion(of text: String) -> String {
        if let tagRange = text.range(of: pointingTagPrefix) {
            return String(text[..<tagRange.lowerBound])
        }
        for partialTagLength in stride(from: pointingTagPrefix.count - 1, through: 1, by: -1) {
            let partialTag = String(pointingTagPrefix.prefix(partialTagLength))
            if text.hasSuffix(partialTag) {
                return String(text.dropLast(partialTagLength))
            }
        }
        return text
    }
}
