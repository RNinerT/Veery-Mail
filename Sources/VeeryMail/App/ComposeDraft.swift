import Foundation
import VeeryMailCore

/// Editable state of one compose window. Codable so Undo Send, a failed send or a quit
/// can reopen exactly what was written: recipients, identity, formatting and attachments.
struct ComposeDraft: Identifiable, Codable, Equatable {
    var id = UUID()
    var identityId: String?
    var to = ""
    var cc = ""
    var bcc = ""
    var showCc = false
    var subject = ""
    /// Plain-text body (always sent).
    var body = ""
    /// The formatted body as RTF, owned by the editor.
    var bodyRTF: Data?
    /// HTML generated from the formatted body; nil when there's no formatting.
    var htmlBody: String?
    var inReplyTo: String?
    var references: [String] = []
    var replyingToEmailId: String?
    var threadId: String?
    var isForward = false
    var attachments: [OutgoingAttachment] = []
    var forwardedAttachments: [OutgoingAttachment] = []
    var savedDraftId: String?
    /// The signature block currently in the body, so switching identity can swap it.
    var signatureBlock: String?

    init(identityId: String?) {
        self.identityId = identityId
    }

    var allAttachments: [OutgoingAttachment] { forwardedAttachments + attachments }

    var isEmpty: Bool { snapshot.isBlank }

    /// Exactly what a saved draft contains; compared to decide whether a save is needed.
    var snapshot: DraftSnapshot {
        DraftSnapshot(identityId: identityId, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                      htmlBody: htmlBody, attachments: allAttachments, inReplyTo: inReplyTo,
                      references: references, replyingToEmailId: replyingToEmailId, isForward: isForward)
    }

    enum Field: String, CaseIterable { case to = "To", cc = "Cc", bcc = "Bcc" }

    func text(_ field: Field) -> String {
        switch field {
        case .to: return to
        case .cc: return cc
        case .bcc: return bcc
        }
    }

    /// Entries that aren't valid addresses, by field. Sending is blocked while any exist.
    var invalidRecipients: [Field: [RecipientToken]] {
        var out: [Field: [RecipientToken]] = [:]
        for field in Field.allCases {
            let bad = RecipientParser.parse(text(field)).filter { $0.address == nil }
            if !bad.isEmpty { out[field] = bad }
        }
        return out
    }

    var hasRecipients: Bool {
        Field.allCases.contains { !RecipientParser.parse(text($0)).compactMap(\.address).isEmpty }
    }

    func outgoing(from: EmailAddress, messageId: String?) -> OutgoingMessage {
        OutgoingMessage(
            from: from,
            to: EmailAddress.parseList(to),
            cc: EmailAddress.parseList(cc),
            bcc: EmailAddress.parseList(bcc),
            subject: subject,
            body: body,
            htmlBody: htmlBody,
            inReplyTo: inReplyTo,
            references: references,
            attachments: allAttachments,
            replyingToEmailId: replyingToEmailId,
            isForward: isForward,
            messageId: messageId
        )
    }
}

/// Signature settings, per sending identity.
enum Signatures {
    static func text(for identityId: String?) -> String {
        let d = UserDefaults.standard
        if let id = identityId, let own = d.string(forKey: "signature.\(id)"), !own.isEmpty { return own }
        return d.string(forKey: "signature.default") ?? ""
    }

    static var onNewMessages: Bool { UserDefaults.standard.object(forKey: "signature.new") as? Bool ?? true }
    static var onReplies: Bool { UserDefaults.standard.object(forKey: "signature.replies") as? Bool ?? true }
    static var useDelimiter: Bool { UserDefaults.standard.object(forKey: "signature.delimiter") as? Bool ?? true }

    /// The text inserted into a body, or nil when there's no signature for this kind of message.
    static func block(for identityId: String?, reply: Bool) -> String? {
        guard reply ? onReplies : onNewMessages else { return nil }
        let text = Self.text(for: identityId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return useDelimiter ? "-- \n" + text : text
    }
}
