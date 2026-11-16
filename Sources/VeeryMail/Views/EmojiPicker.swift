import AppKit
import SwiftUI
import VeeryMailCore

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
        .frame(width: 384)
    }

    private func pick(_ e: String) {
        var r = recents.filter { $0 != e }
        r.insert(e, at: 0)
        recentsRaw = r.prefix(30).joined(separator: " ")
        onPick(e)
    }
}
