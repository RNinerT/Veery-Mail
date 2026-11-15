import AppKit
import SwiftUI

/// Drives one compose window's text view: formatting commands, selection access for AI
/// rewrites, and export to plain text, RTF and email-safe HTML.
@MainActor
final class RichTextController {
    weak var textView: NSTextView?
    var onChange: (() -> Void)?

    nonisolated static let baseSize: CGFloat = 14
    static var baseFont: NSFont { NSFont.systemFont(ofSize: baseSize) }

    var attributedText: NSAttributedString { textView?.attributedString() ?? NSAttributedString() }
    var plainText: String { attributedText.string }

    var selectedText: String {
        guard let tv = textView else { return "" }
        let range = tv.selectedRange()
        guard range.length > 0 else { return "" }
        return (tv.string as NSString).substring(with: range)
    }

    var rtfData: Data? {
        let s = attributedText
        return try? s.data(from: NSRange(location: 0, length: s.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// HTML for the message, or nil when the text has no formatting worth sending.
    var html: String? { HTMLExporter.html(from: attributedText) }

    // MARK: Editing

    private func changeSelection(_ change: (NSTextStorage, NSRange) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else {
            // No selection: apply to what's typed next.
            let probe = NSMutableAttributedString(string: " ", attributes: tv.typingAttributes)
            change(NSTextStorage(attributedString: probe), NSRange(location: 0, length: 1))
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage, range)
        storage.endEditing()
        tv.didChangeText()
        onChange?()
    }

    private func updateTyping(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let tv = textView else { return }
        var attrs = tv.typingAttributes
        attrs[key] = value
        tv.typingAttributes = attrs
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            let font = (tv.typingAttributes[.font] as? NSFont) ?? Self.baseFont
            let has = fm.traits(of: font).contains(trait)
            updateTyping(.font, has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait))
            return
        }
        changeSelection { storage, range in
            var allHave = true
            storage.enumerateAttribute(.font, in: range) { value, _, _ in
                if !fm.traits(of: (value as? NSFont) ?? Self.baseFont).contains(trait) { allHave = false }
            }
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? Self.baseFont
                storage.addAttribute(.font, value: allHave ? fm.convert(font, toNotHaveTrait: trait)
                                                           : fm.convert(font, toHaveTrait: trait), range: sub)
            }
        }
    }

    func toggle(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            let on = (tv.typingAttributes[key] as? Int ?? 0) != 0
            updateTyping(key, on ? nil : NSUnderlineStyle.single.rawValue)
            return
        }
        changeSelection { storage, range in
            var allOn = true
            storage.enumerateAttribute(key, in: range) { value, _, _ in if (value as? Int ?? 0) == 0 { allOn = false } }
            if allOn { storage.removeAttribute(key, range: range) }
            else { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    func adjustSize(by delta: CGFloat) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        if tv.selectedRange().length == 0 {
            let font = (tv.typingAttributes[.font] as? NSFont) ?? Self.baseFont
            updateTyping(.font, fm.convert(font, toSize: max(9, min(48, font.pointSize + delta))))
            return
        }
        changeSelection { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? Self.baseFont
                storage.addAttribute(.font, value: fm.convert(font, toSize: max(9, min(48, font.pointSize + delta))), range: sub)
            }
        }
    }

    func setColor(_ color: NSColor?) {
        guard let tv = textView else { return }
        if tv.selectedRange().length == 0 { updateTyping(.foregroundColor, color); return }
        changeSelection { storage, range in
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
            else { storage.removeAttribute(.foregroundColor, range: range) }
        }
    }

    func setLink(_ url: URL?) {
        changeSelection { storage, range in
            if let url { storage.addAttribute(.link, value: url, range: range) }
            else { storage.removeAttribute(.link, range: range) }
        }
    }

    func clearFormatting() {
        changeSelection { storage, range in
            storage.setAttributes([.font: Self.baseFont, .foregroundColor: NSColor.textColor], range: range)
        }
    }

    /// Bulleted, numbered or quoted lines: changes the selected paragraphs.
    enum LineStyle { case bullets, numbers, quote }

    func applyLineStyle(_ style: LineStyle) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let paragraphs = ns.paragraphRange(for: tv.selectedRange())
        guard tv.shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        let lines = ns.substring(with: paragraphs).components(separatedBy: "\n")
        let markerPattern = #"^(• |\d+\. )"#
        let alreadyStyled = lines.filter { !$0.isEmpty }.allSatisfy { line in
            switch style {
            case .bullets: return line.hasPrefix("• ")
            case .numbers: return line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            case .quote: return false
            }
        }
        storage.beginEditing()
        if style == .quote {
            let para = NSMutableParagraphStyle()
            let current = storage.attribute(.paragraphStyle, at: paragraphs.location, effectiveRange: nil) as? NSParagraphStyle
            let quoted = (current?.headIndent ?? 0) > 0
            para.headIndent = quoted ? 0 : 24
            para.firstLineHeadIndent = quoted ? 0 : 24
            storage.addAttribute(.paragraphStyle, value: para, range: paragraphs)
            if quoted { storage.removeAttribute(.foregroundColor, range: paragraphs) }
            else { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: paragraphs) }
        } else {
            var number = 0
            let rewritten = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                let bare = line.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
                if alreadyStyled { return bare }
                number += 1
                return (style == .bullets ? "• " : "\(number). ") + bare
            }.joined(separator: "\n")
            let attrs = storage.attributes(at: paragraphs.location, effectiveRange: nil)
            storage.replaceCharacters(in: paragraphs, with: NSAttributedString(string: rewritten, attributes: attrs))
        }
        storage.endEditing()
        tv.didChangeText()
        onChange?()
    }

    /// Inserts text at the cursor (emoji, AI drafts).
    func insert(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
        onChange?()
    }

    /// Replaces the selection, or everything when nothing is selected (AI rewrite). Undoable.
    func replaceSelectionOrAll(with text: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: (tv.string as NSString).length)
        tv.insertText(text, replacementRange: range)
        onChange?()
    }

    /// Replaces one exact piece of text (used to swap signatures when the From address changes).
    @discardableResult
    func replaceFirst(_ old: String, with new: String) -> Bool {
        guard let tv = textView, !old.isEmpty else { return false }
        let range = (tv.string as NSString).range(of: old)
        guard range.location != NSNotFound else { return false }
        tv.insertText(new, replacementRange: range)
        onChange?()
        return true
    }
}

/// The compose body: a native rich-text view with spelling checks and undo.
struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController
    let initialRTF: Data?
    let initialText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.font = RichTextController.baseFont
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.typingAttributes = [.font: RichTextController.baseFont, .foregroundColor: NSColor.textColor]
        if let rtf = initialRTF, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            tv.textStorage?.setAttributedString(attributed)
        } else {
            tv.string = initialText
            tv.textStorage?.addAttributes([.font: RichTextController.baseFont, .foregroundColor: NSColor.textColor],
                                          range: NSRange(location: 0, length: (initialText as NSString).length))
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.delegate = context.coordinator
        controller.textView = tv
        tv.setAccessibilityLabel("Message body")
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        controller.textView = view.documentView as? NSTextView
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichTextController
        init(_ c: RichTextController) { controller = c }
        func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated { controller.onChange?() }
        }
    }
}

/// Converts the editor's text to small, inline-styled HTML that mail clients render reliably.
/// Only formatting the toolbar can produce is exported; there are no external resources.
enum HTMLExporter {
    static func html(from text: NSAttributedString) -> String? {
        guard text.length > 0, hasFormatting(text) else { return nil }
        var out = "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5\">"
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let para = text.attributedSubstring(from: paraRange)
            let style = para.length > 0 ? para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            let quoted = (style?.headIndent ?? 0) > 0
            out += quoted ? "<blockquote style=\"margin:0 0 0 12px;padding-left:10px;border-left:3px solid #ccc;color:#555\">" : "<div>"
            var lineHTML = ""
            para.enumerateAttributes(in: NSRange(location: 0, length: para.length)) { attrs, range, _ in
                var piece = escape((para.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: ""))
                guard !piece.isEmpty else { return }
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                if traits.contains(.boldFontMask) { piece = "<b>\(piece)</b>" }
                if traits.contains(.italicFontMask) { piece = "<i>\(piece)</i>" }
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { piece = "<u>\(piece)</u>" }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { piece = "<s>\(piece)</s>" }
                var css: [String] = []
                if let font, abs(font.pointSize - RichTextController.baseSize) > 0.5 { css.append("font-size:\(Int(font.pointSize))px") }
                if let color = attrs[.foregroundColor] as? NSColor, !quoted, let hex = hex(color) { css.append("color:\(hex)") }
                if !css.isEmpty { piece = "<span style=\"\(css.joined(separator: ";"))\">\(piece)</span>" }
                if let link = (attrs[.link] as? URL) ?? (attrs[.link] as? String).flatMap(URL.init(string:)),
                   ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>"
                }
                lineHTML += piece
            }
            out += lineHTML.isEmpty ? "<br>" : lineHTML
            out += quoted ? "</blockquote>" : "</div>"
            location = NSMaxRange(paraRange)
        }
        return out + "</div>"
    }

    static func hasFormatting(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, stop in
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask)
                    || abs(font.pointSize - RichTextController.baseSize) > 0.5 { found = true }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 || (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { found = true }
            if attrs[.link] != nil { found = true }
            if let color = attrs[.foregroundColor] as? NSColor, color != NSColor.textColor { found = true }
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle, p.headIndent > 0 { found = true }
            if found { stop.pointee = true }
        }
        return found
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hex(_ color: NSColor) -> String? {
        guard color != NSColor.textColor, let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
