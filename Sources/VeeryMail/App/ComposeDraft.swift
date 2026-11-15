import Foundation
import VeeryMailCore

/// Editable state of the compose window.
struct ComposeDraft: Identifiable {
    let id = UUID()
    var identityId: String?
    var to = ""
    var cc = ""
    var bcc = ""
    var showCc = false
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: [String] = []
    var replyingToEmailId: String?
    var isForward = false
    var attachments: [OutgoingAttachment] = []
    var forwardedAttachments: [OutgoingAttachment] = []
    var savedDraftId: String?

    init(identityId: String?) {
        self.identityId = identityId
    }

    var allAttachments: [OutgoingAttachment] { forwardedAttachments + attachments }

    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    func outgoing(from: EmailAddress) -> OutgoingMessage {
        OutgoingMessage(
            from: from,
            to: EmailAddress.parseList(to),
            cc: EmailAddress.parseList(cc),
            bcc: EmailAddress.parseList(bcc),
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references,
            attachments: allAttachments,
            replyingToEmailId: replyingToEmailId,
            isForward: isForward
        )
    }

    mutating func restore(from m: OutgoingMessage) {
        to = m.to.map(\.formatted).joined(separator: ", ")
        cc = m.cc.map(\.formatted).joined(separator: ", ")
        bcc = m.bcc.map(\.formatted).joined(separator: ", ")
        showCc = !cc.isEmpty || !bcc.isEmpty
        subject = m.subject
        body = m.body
        inReplyTo = m.inReplyTo
        references = m.references
        attachments = m.attachments
        replyingToEmailId = m.replyingToEmailId
        isForward = m.isForward
    }
}
