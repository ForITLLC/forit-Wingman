//
//  WingmanSpokenSentenceSplitter.swift
//  Wingman
//
//  Cuts the model's streamed reply into sentences that can be sent to text-to-speech before the
//  reply is finished, so the first sentence is heard while the rest is still being written.
//  Pure and unit-tested: it never speaks, it only decides which text is ready to be spoken.
//  Two things in a reply are shown but never spoken: the pointing tag, and the Source line that
//  cites the ForIT Support article the answer came from (decision 012), because a web address
//  read aloud is noise and the screen and the panel already show it.
//

import Foundation

struct WingmanSpokenSentenceSplitter {
    /// The pointing tag the model appends after its spoken text (see `parsePointingCoordinates`).
    /// Nothing from it onward is ever spoken, and a partial tag at the end of the stream ("[PO")
    /// is held back until the stream shows whether it is the tag or ordinary text.
    static let pointingTagPrefix = "[POINT"

    /// The citation the prompt asks for as the last line of a written answer:
    /// `Source: <article title> — <url>`. Nothing from that line onward is spoken.
    static let sourceLinePrefix = "Source:"

    /// A line that starts with the Source prefix (leading spaces allowed, any case).
    private static let sourceLineRegularExpression = try! NSRegularExpression(
        pattern: "^[ \\t]*source:",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /// A web address anywhere in a sentence. The punctuation that closes the sentence around it
    /// ("…/kb/tsa, under Integrations.") is not part of the address and stays spoken.
    private static let webAddressRegularExpression = try! NSRegularExpression(
        pattern: "https?://\\S*[^\\s.,;:!?)\\]]",
        options: [.caseInsensitive]
    )

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

    /// The part of the text that may be spoken: everything before the pointing tag and before the
    /// Source line, minus a trailing fragment that could still turn into the tag. A partial Source
    /// line needs no such hold: it sits after a newline, and text after a newline is only released
    /// at a later boundary, by which time the line is either the citation or ordinary text.
    static func speakablePortion(of text: String) -> String {
        var speakableText = text
        if let tagRange = speakableText.range(of: pointingTagPrefix) {
            speakableText = String(speakableText[..<tagRange.lowerBound])
        }
        let wholeRange = NSRange(speakableText.startIndex..<speakableText.endIndex, in: speakableText)
        if let sourceLineMatch = sourceLineRegularExpression.firstMatch(in: speakableText, options: [], range: wholeRange),
           let sourceLineRange = Range(sourceLineMatch.range, in: speakableText) {
            speakableText = String(speakableText[..<sourceLineRange.lowerBound])
        }
        for partialTagLength in stride(from: pointingTagPrefix.count - 1, through: 1, by: -1) {
            let partialTag = String(pointingTagPrefix.prefix(partialTagLength))
            if speakableText.hasSuffix(partialTag) {
                return String(speakableText.dropLast(partialTagLength))
            }
        }
        return speakableText
    }

    /// What text-to-speech gets for one released sentence: nil when nothing should be said (a
    /// Source line, or a sentence that was only a web address), otherwise the sentence with every
    /// web address removed and the spacing closed up.
    static func speakableText(ofSentence sentence: String) -> String? {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSentence.lowercased().hasPrefix(sourceLinePrefix.lowercased()) {
            return nil
        }
        let wholeRange = NSRange(trimmedSentence.startIndex..<trimmedSentence.endIndex, in: trimmedSentence)
        let withoutWebAddresses = webAddressRegularExpression.stringByReplacingMatches(
            in: trimmedSentence,
            options: [],
            range: wholeRange,
            withTemplate: ""
        )
        let spacingClosedUp = withoutWebAddresses
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([,.;:!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard spacingClosedUp.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return spacingClosedUp
    }
}
