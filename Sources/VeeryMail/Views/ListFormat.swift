import AppKit
import SwiftUI

// MARK: - Per-element text style

/// Full typographic control for one piece of a message row (sender, subject, preview or date).
struct TextStyle: Codable, Equatable {
    enum Weight: String, Codable, CaseIterable, Identifiable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ultraLight: return "Ultralight"
            case .semibold: return "Semibold"
            default: return rawValue.capitalized
            }
        }
        var font: Font.Weight {
            switch self {
            case .ultraLight: return .ultraLight
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            }
        }
    }

    enum Design: String, Codable, CaseIterable, Identifiable {
        case standard, serif, rounded, monospaced
        var id: String { rawValue }
        var label: String { self == .standard ? "Default" : rawValue.capitalized }
        var font: Font.Design {
            switch self {
            case .standard: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            }
        }
    }

    enum ColorChoice: String, Codable, CaseIterable, Identifiable {
        case primary, secondary, tertiary, silver, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .primary: return "Primary"
            case .secondary: return "Secondary (muted)"
            case .tertiary: return "Tertiary (faint)"
            case .silver: return "Copper accent"     // raw value kept from the silver theme
            case .custom: return "Custom color"
            }
        }
    }

    enum LetterCase: String, Codable, CaseIterable, Identifiable {
        case asTyped, uppercase, lowercase
        var id: String { rawValue }
        var label: String {
            switch self {
            case .asTyped: return "As written"
            case .uppercase: return "UPPERCASE"
            case .lowercase: return "lowercase"
            }
        }
    }

    /// Empty string = system font (San Francisco), otherwise an installed font family name.
    var family = ""
    var design: Design = .standard
    var size: Double = 13
    var readWeight: Weight = .regular
    var unreadWeight: Weight = .semibold
    var italic = false
    var underline = false
    var color: ColorChoice = .primary
    var customHex = "#CCD1D9"
    var letterCase: LetterCase = .asTyped
    var tracking: Double = 0
    /// Use `unreadHex` instead of the normal color while a message is unread.
    var unreadColorOn = false
    var unreadHex = "#FFFFFF"

    init(family: String = "", design: Design = .standard, size: Double = 13,
         readWeight: Weight = .regular, unreadWeight: Weight = .semibold,
         italic: Bool = false, underline: Bool = false, color: ColorChoice = .primary) {
        self.family = family; self.design = design; self.size = size
        self.readWeight = readWeight; self.unreadWeight = unreadWeight
        self.italic = italic; self.underline = underline; self.color = color
    }

    /// Tolerant decoding: styles saved by an older version keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decodeIfPresent(String.self, forKey: .family) ?? ""
        design = try c.decodeIfPresent(Design.self, forKey: .design) ?? .standard
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 13
        readWeight = try c.decodeIfPresent(Weight.self, forKey: .readWeight) ?? .regular
        unreadWeight = try c.decodeIfPresent(Weight.self, forKey: .unreadWeight) ?? .semibold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        color = try c.decodeIfPresent(ColorChoice.self, forKey: .color) ?? .primary
        customHex = try c.decodeIfPresent(String.self, forKey: .customHex) ?? "#CCD1D9"
        letterCase = try c.decodeIfPresent(LetterCase.self, forKey: .letterCase) ?? .asTyped
        tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? 0
        unreadColorOn = try c.decodeIfPresent(Bool.self, forKey: .unreadColorOn) ?? false
        unreadHex = try c.decodeIfPresent(String.self, forKey: .unreadHex) ?? "#FFFFFF"
    }

    static let sizeRange: ClosedRange<Double> = 9...24

    func font(unread: Bool) -> Font {
        let weight = (unread ? unreadWeight : readWeight).font
        var font = family.isEmpty
            ? Font.system(size: size, weight: weight, design: design.font)
            : Font.custom(family, size: size).weight(weight)
        if italic { font = font.italic() }
        return font
    }

    func resolvedColor(unread: Bool) -> Color {
        if unread, unreadColorOn, let c = Color(hex: unreadHex) { return c }
        switch color {
        case .primary: return Theme.text
        case .secondary: return Theme.secondaryText
        case .tertiary: return Theme.secondaryText.opacity(0.75)
        case .silver: return Theme.accent
        case .custom: return Color(hex: customHex) ?? Theme.text
        }
    }
}

extension View {
    /// Applies a `TextStyle`; unread messages use the style's unread weight.
    func textStyle(_ style: TextStyle, unread: Bool) -> some View {
        self.font(style.font(unread: unread))
            .underline(style.underline)
            .tracking(style.tracking)
            .textCase(style.letterCase == .uppercase ? .uppercase : style.letterCase == .lowercase ? .lowercase : nil)
            .foregroundStyle(style.resolvedColor(unread: unread))
    }
}

// MARK: - Whole-row format

struct ListFormat: Equatable {
    enum Element: String, CaseIterable, Identifiable {
        case sender, subject, preview, date
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var key: String { "list.style.\(rawValue)" }

        var defaultStyle: TextStyle {
            switch self {
            case .sender: return TextStyle(size: 13, readWeight: .regular, unreadWeight: .semibold)
            case .subject: return TextStyle(size: 12.5, readWeight: .regular, unreadWeight: .medium)
            case .preview: return TextStyle(size: 12, readWeight: .regular, unreadWeight: .regular, color: .secondary)
            case .date: return TextStyle(size: 11, readWeight: .regular, unreadWeight: .regular, color: .secondary)
            }
        }
    }

    enum Spacing: String, CaseIterable, Identifiable {
        case compact, standard, roomy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var padding: CGFloat {
            switch self {
            case .compact: return 1
            case .standard: return 4
            case .roomy: return 9
            }
        }
    }

    enum DateStyle: String, CaseIterable, Identifiable {
        case relative, time, full
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relative: return "Relative (10:42, Yesterday, Mon)"
            case .time: return "Date only (11/14/26)"
            case .full: return "Date and time"
            }
        }
    }

    enum FirstLine: String, CaseIterable, Identifiable {
        case sender, subject
        var id: String { rawValue }
        var label: String { self == .sender ? "Sender" : "Subject" }
    }

    var sender = Element.sender.defaultStyle
    var subject = Element.subject.defaultStyle
    var preview = Element.preview.defaultStyle
    var date = Element.date.defaultStyle
    var previewLines = 1
    var spacing: Spacing = .standard
    var dateStyle: DateStyle = .relative
    var firstLine: FirstLine = .sender
    var showAvatars = false
    var showUnreadDot = true
    var cleanSenders = true
    /// Empty = the theme's default unread color.
    var unreadDotHex = ""

    var unreadDotColor: Color { Color(hex: unreadDotHex) ?? Theme.unread }

    enum Key {
        static let previewLines = "listDensity"          // kept from v0.1
        static let spacing = "list.spacing"
        static let dateStyle = "list.dateStyle"
        static let firstLine = "list.firstLine"
        static let showAvatars = "list.showAvatars"
        static let showUnreadDot = "list.showUnreadDot"
        static let cleanSenders = "list.cleanSenders"
        static let unreadDotHex = "list.unreadDotHex"
        static let layout = [previewLines, spacing, dateStyle, firstLine, showAvatars, showUnreadDot,
                             cleanSenders, unreadDotHex]
    }

    // MARK: Persistence helpers (styles are stored as JSON strings)

    static func decode(_ json: String, default fallback: TextStyle) -> TextStyle {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let style = try? JSONDecoder().decode(TextStyle.self, from: data) else { return fallback }
        return style
    }

    static func encode(_ style: TextStyle) -> String {
        (try? JSONEncoder().encode(style)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func resetToDefaults() {
        (Key.layout + Element.allCases.map(\.key)).forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    /// ⌘= / ⌘− : scale every element's size together.
    static func adjustFontSize(by delta: Double) {
        for element in Element.allCases {
            var style = decode(UserDefaults.standard.string(forKey: element.key) ?? "", default: element.defaultStyle)
            style.size = min(max(style.size + delta, TextStyle.sizeRange.lowerBound), TextStyle.sizeRange.upperBound)
            UserDefaults.standard.set(encode(style), forKey: element.key)
        }
    }

    /// ⌘0 : default sizes, keeping every other style choice.
    static func resetFontSizes() {
        for element in Element.allCases {
            var style = decode(UserDefaults.standard.string(forKey: element.key) ?? "", default: element.defaultStyle)
            style.size = element.defaultStyle.size
            UserDefaults.standard.set(encode(style), forKey: element.key)
        }
    }

    /// Installed font families for the font picker (computed once).
    static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted()
}

/// Reads every list-format key and exposes a `ListFormat` plus bindings for Settings.
struct ListFormatStorage: DynamicProperty {
    @AppStorage(ListFormat.Element.sender.key) var senderJSON = ""
    @AppStorage(ListFormat.Element.subject.key) var subjectJSON = ""
    @AppStorage(ListFormat.Element.preview.key) var previewJSON = ""
    @AppStorage(ListFormat.Element.date.key) var dateJSON = ""
    @AppStorage(ListFormat.Key.previewLines) var previewLines = 1
    @AppStorage(ListFormat.Key.spacing) var spacing = ListFormat.Spacing.standard
    @AppStorage(ListFormat.Key.dateStyle) var dateStyle = ListFormat.DateStyle.relative
    @AppStorage(ListFormat.Key.firstLine) var firstLine = ListFormat.FirstLine.sender
    @AppStorage(ListFormat.Key.showAvatars) var showAvatars = false
    @AppStorage(ListFormat.Key.showUnreadDot) var showUnreadDot = true
    @AppStorage(ListFormat.Key.cleanSenders) var cleanSenders = true
    @AppStorage(ListFormat.Key.unreadDotHex) var unreadDotHex = ""

    var format: ListFormat {
        ListFormat(sender: style(.sender), subject: style(.subject), preview: style(.preview), date: style(.date),
                   previewLines: previewLines, spacing: spacing, dateStyle: dateStyle, firstLine: firstLine,
                   showAvatars: showAvatars, showUnreadDot: showUnreadDot, cleanSenders: cleanSenders,
                   unreadDotHex: unreadDotHex)
    }

    func style(_ element: ListFormat.Element) -> TextStyle {
        ListFormat.decode(json(element).wrappedValue, default: element.defaultStyle)
    }

    func binding(_ element: ListFormat.Element) -> Binding<TextStyle> {
        let raw = json(element)
        return Binding(
            get: { ListFormat.decode(raw.wrappedValue, default: element.defaultStyle) },
            set: { raw.wrappedValue = ListFormat.encode($0) }
        )
    }

    private func json(_ element: ListFormat.Element) -> Binding<String> {
        switch element {
        case .sender: return $senderJSON
        case .subject: return $subjectJSON
        case .preview: return $previewJSON
        case .date: return $dateJSON
        }
    }
}

// MARK: - Hex colors

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#CCD1D9" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
