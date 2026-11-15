import AppKit
import SwiftUI

/// A large, searchable emoji picker built from the Unicode data that ships with macOS,
/// with recents and a link to the full system Character Viewer.
struct EmojiPicker: View {
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var category = EmojiCatalog.categories[0].name
    @AppStorage("emoji.recents") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: " ").map(String.init) }

    private var shown: [EmojiCatalog.Emoji] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { return EmojiCatalog.all.filter { $0.name.contains(q) } }
        if category == "Recent" { return recents.map { EmojiCatalog.Emoji(character: $0, name: "") } }
        return EmojiCatalog.categories.first { $0.name == category }?.emoji ?? []
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
            if query.isEmpty {
                Picker("Category", selection: $category) {
                    if !recents.isEmpty { Text("🕘").tag("Recent").help("Recent") }
                    ForEach(EmojiCatalog.categories, id: \.name) { c in
                        Text(c.symbol).tag(c.name).help(c.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 2), count: 10), spacing: 2) {
                    ForEach(shown, id: \.character) { emoji in
                        Button { pick(emoji.character) } label: {
                            Text(emoji.character).font(.system(size: 24)).frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help(emoji.name.capitalized)
                        .accessibilityLabel(emoji.name.isEmpty ? emoji.character : emoji.name)
                    }
                }
            }
            .frame(height: 260)
            HStack {
                Text("\(EmojiCatalog.all.count) emoji").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("More Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func pick(_ e: String) {
        var r = recents.filter { $0 != e }
        r.insert(e, at: 0)
        recentsRaw = r.prefix(30).joined(separator: " ")
        onPick(e)
    }
}

enum EmojiCatalog {
    struct Emoji: Hashable { let character: String; let name: String }
    struct Category { let name: String; let symbol: String; let emoji: [Emoji] }

    private static let ranges: [(String, String, [ClosedRange<UInt32>])] = [
        ("Smileys & People", "😀", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F, 0x1F9D0...0x1F9DF,
                                   0x1F466...0x1F487, 0x1F44A...0x1F450, 0x1F918...0x1F91F, 0x1F9B0...0x1F9B9,
                                   0x1FAE0...0x1FAFF]),
        ("Animals & Nature", "🐻", [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F343, 0x1F490...0x1F490,
                                   0x1FAB0...0x1FABF, 0x1F308...0x1F320]),
        ("Food & Drink", "🍔", [0x1F344...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF]),
        ("Activities", "⚽️", [0x1F380...0x1F3D3, 0x1F93A...0x1F94F, 0x1FA80...0x1FA8F]),
        ("Travel & Places", "🚗", [0x1F680...0x1F6FF, 0x1F3D4...0x1F3F0, 0x1F30D...0x1F307]),
        ("Objects", "💡", [0x1F4A1...0x1F4FF, 0x1F500...0x1F53D, 0x1F56F...0x1F5FF, 0x1FA70...0x1FA7F,
                          0x1FA90...0x1FAAF, 0x1F9E0...0x1F9FF]),
        ("Symbols", "❤️", [0x1F493...0x1F4A0, 0x2600...0x27BF, 0x1F7E0...0x1F7EB, 0x1F170...0x1F251, 0x2B00...0x2BFF]),
        ("Flags", "🏁", [0x1F3F3...0x1F3F4]),
    ]

    static let categories: [Category] = {
        var seen = Set<String>()
        var out: [Category] = []
        for (name, symbol, rs) in ranges {
            var list: [Emoji] = []
            for range in rs {
                for value in range {
                    guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji else { continue }
                    // Text-default symbols get the emoji presentation selector.
                    let text = scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                    guard seen.insert(text).inserted else { continue }
                    list.append(Emoji(character: text, name: (scalar.properties.name ?? "").lowercased()))
                }
            }
            if name == "Flags" { list += flags }
            if !list.isEmpty { out.append(Category(name: name, symbol: symbol, emoji: list)) }
        }
        return out
    }()

    static let all: [Emoji] = categories.flatMap(\.emoji)

    /// Country flags from regional-indicator pairs for common regions.
    private static let flags: [Emoji] = {
        let codes = ["US", "GB", "CA", "AU", "NZ", "IE", "FR", "DE", "ES", "IT", "PT", "NL", "BE", "CH", "AT", "SE", "NO",
                     "DK", "FI", "IS", "PL", "CZ", "GR", "TR", "IL", "AE", "IN", "CN", "JP", "KR", "TW", "HK", "SG",
                     "TH", "VN", "PH", "ID", "MY", "BR", "AR", "CL", "CO", "PE", "MX", "ZA", "NG", "KE", "EG", "UA", "EU", "UN"]
        return codes.map { code in
            let flag = code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }.map(String.init).joined()
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            return Emoji(character: flag, name: "flag " + name.lowercased())
        }
    }()
}
