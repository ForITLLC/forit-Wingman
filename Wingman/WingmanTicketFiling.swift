//
//  WingmanTicketFiling.swift
//  Wingman
//
//  The state and the vocabulary behind filing a support ticket for a customer by voice
//  (.ai/decisions.md 011). A ticket is filed in two spoken turns: the model previews it (nothing is
//  created, for-Support returns the preview and a confirmation token), Wingman reads the preview
//  back, and only when the person says "go ahead" in their next message does the app resend the
//  previewed ticket with that token and the person's own words as the consent for-Support's send
//  rail judges. The token and the exact arguments stay in the app between the two turns; the model
//  never sees the token and cannot file anything the person did not hear read back.
//

import Foundation

// MARK: - Spoken consent

/// How for-Support's send rail will judge a person's words (`src/lib/sendRailConsent.ts`): the
/// same vocabulary, so the app refuses locally what the server would hold. A bare "yes" is not
/// approval there and is not approval here; the action word has to be said.
enum WingmanSpokenConsentVerdict: Equatable {
    case approve
    case deny
    case hold
}

enum WingmanSpokenConsent {
    /// Denial wins over approval, exactly as on the server ("no, don't create it").
    private static let denyPattern = #"\b(don'?t|do not|stop|cancel|deny|denied|nope|no|not)\b"#
    private static let approvePattern = #"\b(send|create|go ahead|approved?|proceed|ship it|do it)\b"#

    /// The words a person can say so Wingman files the ticket. Spoken back to them when what
    /// they said was not one of these.
    static let spokenApprovalHint = "say \"go ahead\" or \"create it\""

    static func verdict(forSpokenWords spokenWords: String) -> WingmanSpokenConsentVerdict {
        let trimmedWords = spokenWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWords.isEmpty else { return .hold }
        // A question is never consent.
        guard !trimmedWords.contains("?") else { return .hold }
        if trimmedWords.range(of: denyPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .deny
        }
        if trimmedWords.range(of: approvePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .approve
        }
        return .hold
    }
}

// MARK: - The ticket waiting for its go-ahead

/// A ticket for-Support has previewed but not created: the token it issued and the exact
/// arguments it was previewed with, which are what gets resent (never the model's retyping, so
/// the token always matches and the person confirms what they heard). Held by the app for a
/// short while only; a preview the person walks away from is forgotten.
struct WingmanPendingTicketPreview {
    /// Longer than this between the read-back and the go-ahead and the preview is stale: the
    /// person has to hear it again.
    static let maximumAge: TimeInterval = 10 * 60

    let confirmationToken: String
    let gatewayArguments: [String: Any]
    let previewedAt: Date

    /// The tenant name for-Support echoed in the preview, for the log line.
    let tenantName: String?

    func isUsable(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(previewedAt) < Self.maximumAge
    }
}
