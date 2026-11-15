import AppKit
import VeeryMailCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Prepared bodies

/// Joining body parts and scanning the HTML is done once per message, not on every redraw.
@MainActor
enum BodyCache {
    struct Prepared {
        let html: String?
        let hasRemote: Bool
        let isSimple: Bool
    }

    private static var store: [String: Prepared] = [:]
    private static var order: [String] = []

    static func prepared(_ email: EmailDetail) -> Prepared {
        if let hit = store[email.id] { return hit }
        let html = email.html
        let lower = html?.lowercased() ?? ""
        let value = Prepared(html: html,
                             hasRemote: html != nil && HTMLHeuristics.hasRemoteContent(lower),
                             isSimple: html != nil && HTMLHeuristics.isSimple(lower))
        store[email.id] = value
        order.append(email.id)
        if order.count > 80 { store[order.removeFirst()] = nil }
        return value
    }
}

// MARK: - Reader

/// The open conversation on one continuous sheet: warm paper by default, dim on request.
struct ReaderView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.colorScheme) private var windowScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Dark appearance only: a dim sheet instead of paper.
    @AppStorage("readerDim") private var readerDim = false
    @State private var expanded: Set<String> = []

    var body: some View {
        let palette = ReaderPalette.current(scheme: windowScheme, dim: readerDim)
        Group {
            if store.selection.count > 1 {
                ContentUnavailableView {
                    Label("\(store.selection.count) Conversations Selected", systemImage: "tray.full")
                } description: {
                    Text("The toolbar actions apply to all of them.")
                }
            } else if let last = store.thread.last {
                sheet(last, palette)
                    .id(last.threadId)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
            } else if store.isLoadingThread {
                ProgressView()
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope.open",
                                       description: Text("J and K move through the list. ⌘K runs any command."))
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        // Controls and system text inside the sheet follow the sheet, not the window.
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .animation(.easeOut(duration: 0.18), value: store.thread.first?.threadId)
        .onChange(of: store.thread.first?.threadId) { _, _ in expanded = [] }
    }

    private func sheet(_ last: EmailDetail, _ palette: ReaderPalette) -> some View {
        let subject = last.subject?.trimmingCharacters(in: .whitespaces).isEmpty == false ? last.subject! : "(no subject)"
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(subject)
                    .font(Theme.Typeface.subject)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)   // long subjects wrap, never truncate
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if store.thread.count > 1 {
                    Text("\(store.thread.count) messages")
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(palette.secondary)
                        .padding(.top, Theme.Space.xs)
                }
                ForEach(store.thread) { email in
                    Rectangle().fill(palette.rule).frame(height: 1)
                        .padding(.top, Theme.Space.l)
                    MessageSection(email: email, palette: palette,
                                   isExpanded: expanded.contains(email.id) || email.id == last.id
                                       || store.expandedOnOpen.contains(email.id),
                                   onToggle: toggler(for: email.id, lastId: last.id))
                }
            }
            // One shared left edge for subject, sender, recipients and body.
            .frame(maxWidth: Theme.Space.readingWidth + 60, alignment: .leading)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.xl + Theme.Space.s)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }

    /// The newest message always stays open, so it gets no toggle.
    private func toggler(for id: String, lastId: String) -> (() -> Void)? {
        guard id != lastId else { return nil }
        return {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

// MARK: - One message on the sheet

struct MessageSection: View {
    @Environment(MailStore.self) private var store
    let email: EmailDetail
    let palette: ReaderPalette
    let isExpanded: Bool
    /// Collapses or expands the message; nil for the newest one, which stays open.
    let onToggle: (() -> Void)?
    @State private var webHeight: CGFloat = 80
    @State private var allowRemote = UserDefaults.standard.bool(forKey: "loadRemoteContent")
    @AppStorage(ListFormat.Key.cleanSenders) private var cleanSenders = true

    var body: some View {
        let prepared = BodyCache.prepared(email)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
                .contentShape(Rectangle())
                .onTapGesture { onToggle?() }
            if isExpanded {
                if let html = prepared.html {
                    if !allowRemote && prepared.hasRemote {
                        // Privacy status with its action right beside it.
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "eye.slash").accessibilityHidden(true)
                            Text("Remote images and trackers are blocked.")
                            Button("Load remote content") { allowRemote = true }
                                .buttonStyle(.plain)
                                .foregroundStyle(palette.accent)
                                .underline()
                        }
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(palette.secondary)
                    }
                    // Sender-authored HTML is isolated in its own web view. Simple mail blends into
                    // the sheet; designed mail keeps its own page, scaled to fit the column.
                    MessageWebView(html: html, allowRemote: allowRemote, blend: prepared.isSimple, palette: palette,
                                   inlineParts: inlineParts, client: store.client, height: $webHeight)
                        .frame(height: webHeight)
                        .frame(maxWidth: prepared.isSimple ? Theme.Space.readingWidth : .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: prepared.isSimple ? 0 : 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(prepared.isSimple ? Color.clear : palette.rule))
                } else {
                    Text(Linkify.attributed(email.plainText))
                        .font(Theme.Typeface.body)
                        .lineSpacing(5)
                        .foregroundStyle(palette.text)
                        .tint(palette.accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: Theme.Space.readingWidth, alignment: .leading)
                }
                if !email.visibleAttachments.isEmpty {
                    AttachmentStrip(parts: email.visibleAttachments, palette: palette)
                }
            }
        }
        .padding(.top, Theme.Space.l)
        .contextMenu {
            Button("Reply") { store.reply(all: false, to: email) }
            Button("Reply All") { store.reply(all: true, to: email) }
            Button("Forward") { store.forward(email) }
            if email.unsubscribeURL != nil {
                Divider()
                Button("Unsubscribe") { store.unsubscribe(email) }
            }
        }
    }

    private var inlineParts: [String: (blobId: String, type: String)] {
        var out: [String: (blobId: String, type: String)] = [:]
        for part in email.attachments ?? [] {
            if let cid = part.cid, let blob = part.blobId {
                out[cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = (blob, part.type)
            }
        }
        return out
    }

    /// Sender, then recipients and time, all on the sheet's left edge.
    private var header: some View {
        let from = email.from?.first
        let clean = from?.cleaned
        let name = (cleanSenders ? clean?.name : from?.displayName) ?? "Unknown"
        // Next to the name: the real domain (clean) or the literal address (as sent).
        let detail = cleanSenders ? clean?.domain : from?.email
        let time = email.receivedAt.formatted(date: .abbreviated, time: .shortened)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let detail, !name.contains("@") {
                    Text(detail)
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                if email.isFlagged {
                    Image(systemName: "flag.fill").foregroundStyle(palette.accent).accessibilityLabel("Flagged")
                }
                if isExpanded && email.unsubscribeURL != nil {
                    Button(email.supportsOneClickUnsubscribe ? "Unsubscribe" : "Unsubscribe…") {
                        store.unsubscribe(email)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(palette.accent)
                    .underline()
                }
            }
            .help(addressDetails)
            if isExpanded {
                Text(recipientLine + "  ·  " + time)
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text(time + "  ·  " + (email.preview ?? ""))
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(onToggle == nil ? "" : (isExpanded ? "Collapses this message" : "Expands this message"))
    }

    /// Hover text: the literal addresses, including any relay address.
    private var addressDetails: String {
        guard let from = email.from?.first else { return "" }
        var lines = ["From: \(from.formatted)"]
        if from.cleaned.isRelayed { lines.append("Original sender: \(from.cleaned.address) (via a relay)") }
        if let to = email.to, !to.isEmpty { lines.append("To: " + to.map(\.formatted).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private var recipientLine: String {
        let mine = Set(store.identities.map { $0.email.lowercased() })
        func names(_ list: [EmailAddress]) -> String {
            list.map { mine.contains($0.email.lowercased()) ? "me" : $0.displayName }.joined(separator: ", ")
        }
        var line = "to " + names(email.to ?? [])
        if let cc = email.cc, !cc.isEmpty { line += ", cc " + names(cc) }
        return line
    }
}

struct Avatar: View {
    let address: EmailAddress?
    var size: CGFloat = 32

    var body: some View {
        let name = address?.cleaned.name ?? "?"
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        // Silver tones, varied per sender so people stay distinguishable.
        let shade = 0.55 + Double(abs((address?.email ?? name).hashValueStable) % 30) / 100
        Circle()
            .fill(LinearGradient(colors: [Color(white: min(shade + 0.15, 0.95)), Color(white: shade - 0.15)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75)))
            .accessibilityHidden(true)
    }
}

private extension String {
    /// Deterministic across launches (unlike `hashValue`).
    var hashValueStable: Int {
        unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }
}

struct AttachmentStrip: View {
    @Environment(MailStore.self) private var store
    let parts: [EmailBodyPart]
    let palette: ReaderPalette

    var body: some View {
        // An adaptive grid wraps onto more lines in a narrow reader, so attachments can
        // never widen the window. Long file names truncate in the middle.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: Theme.Space.s, alignment: .leading)],
                  alignment: .leading, spacing: Theme.Space.s) {
            ForEach(parts, id: \.self) { part in
                Button { open(part, saveAs: false) } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: part.type) ?? .data))
                            .resizable().frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(part.name ?? "attachment")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(part.size ?? 0), countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.rule))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(part.name ?? "attachment")
                .contextMenu {
                    Button("Open") { open(part, saveAs: false) }
                    Button("Save As…") { open(part, saveAs: true) }
                }
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    private func open(_ part: EmailBodyPart, saveAs: Bool) {
        guard let blob = part.blobId, let client = store.client else { return }
        // Never trust a path from the sender: keep only the file name.
        let name = (part.name ?? "attachment").components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? "attachment"
        Task {
            do {
                let data = try await client.download(blobId: blob, name: name, type: part.type)
                if saveAs {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = name
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    try data.write(to: url)
                } else {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VeeryMail/\(blob)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
                    try data.write(to: url)
                    NSWorkspace.shared.open(url)
                }
            } catch { store.report(error) }
        }
    }
}

enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
