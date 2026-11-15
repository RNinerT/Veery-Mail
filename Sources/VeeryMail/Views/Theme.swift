import AppKit
import SwiftUI

/// Veery Mail's design tokens: ink-blue chrome, a warm paper reader and a copper accent.
/// All app-controlled text/background pairs below meet WCAG 2.2 AA (4.5:1) at their default values.
enum Theme {
    // MARK: Surfaces

    /// Sidebar and window toolbar.
    static let nav = dynamic("nav", dark: "#141C26", light: "#E3E8EF")
    /// Message list. Also the canvas for sheets (compose, settings preview).
    static let canvas = dynamic("canvas", dark: "#1B2532", light: "#EEF1F6")
    /// Raised panels on the canvas (toasts, fields, hover buttons).
    static let card = dynamic("card", dark: "#243040", light: "#FFFFFF")
    /// Quiet dividers. Stronger when Increase Contrast is on.
    static let rim = dynamic("rim", dark: "#FFFFFF", light: "#000000", alpha: 0.10, contrastAlpha: 0.38)

    // MARK: Row states

    /// Multi-selected rows and the selected mailbox.
    static let selection = dynamic("selection", dark: "#2A3748", light: "#D9E0EA")
    static let hover = dynamic("hover", dark: "#222E3D", light: "#E4E9F0")

    // MARK: Text on nav / canvas

    static let text = dynamic("text", dark: "#E9EDF2", light: "#1B2430")
    static let secondaryText = dynamic("secondaryText", dark: "#A3ADBA", light: "#525C69",
                                       contrastDark: "#CDD4DD", contrastLight: "#2F3742")

    // MARK: Accents

    /// Copper: the open conversation and a small number of active controls.
    static let accent = dynamic("accent", dark: "#DB8F55", light: "#9A4A17")
    /// Text on a filled copper button.
    static let onAccent = dynamic("onAccent", dark: "#1A1208", light: "#FFFFFF")
    /// Default unread dot.
    static let unread = dynamic("unread", dark: "#7FB2F0", light: "#2563B8")
    static let flag = dynamic("flag", dark: "#F0B255", light: "#A35F00")
    static let graphite = Color(red: 0.29, green: 0.30, blue: 0.33)

    // MARK: Type

    enum Typeface {
        /// The open conversation's subject: New York, wraps naturally.
        static let subject = Font.system(size: 30, weight: .semibold, design: .serif)
        static let mailboxTitle = Font.system(size: 22, weight: .bold)
        static let sectionLabel = Font.system(size: 10.5, weight: .semibold)
        static let body = Font.system(size: 15)
        static let meta = Font.system(size: 12)
    }

    // MARK: Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
        /// Width reserved for the unread dot, so every row's text starts on the same line.
        static let dotColumn: CGFloat = 16
        /// Longest comfortable line of reading text.
        static let readingWidth: CGFloat = 700
    }

    // MARK: Helpers

    /// "dark" (default), "light" or "system", stored in Settings.
    static func scheme(for setting: String) -> ColorScheme? {
        switch setting {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    private static func dynamic(_ name: String, dark: String, light: String,
                                alpha: CGFloat = 1, contrastAlpha: CGFloat? = nil,
                                contrastDark: String? = nil, contrastLight: String? = nil) -> Color {
        Color(nsColor: NSColor(name: "VeeryMail.\(name)") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let hex = isDark ? (highContrast ? contrastDark ?? dark : dark)
                             : (highContrast ? contrastLight ?? light : light)
            let a = highContrast ? contrastAlpha ?? alpha : alpha
            return (NSColor(hex: hex) ?? .gray).withAlphaComponent(a)
        })
    }
}

/// Colors for the reader sheet. Fixed values (not appearance-dynamic) because the paper
/// stays light even when the rest of the window is dark.
struct ReaderPalette: Equatable {
    let isDark: Bool
    let background: Color
    let text: Color
    let secondary: Color
    let rule: Color
    let accent: Color
    // The same colors for sender-authored HTML that blends into the sheet.
    let textHex: String
    let secondaryHex: String
    let linkHex: String
    let ruleHex: String

    /// Warm paper. Used in light appearance, and in dark appearance unless Dim is chosen.
    static func paper(lightWindow: Bool) -> ReaderPalette {
        ReaderPalette(isDark: false,
                      background: Color(hex: lightWindow ? "#FBF8F2" : "#F4EFE6") ?? .white,
                      text: Color(hex: "#1F2328") ?? .black,
                      secondary: Color(hex: "#5A5F66") ?? .gray,
                      rule: Color.black.opacity(0.13),
                      accent: Color(hex: "#8F4513") ?? .brown,
                      textHex: "#1F2328", secondaryHex: "#5A5F66", linkHex: "#8F4513", ruleHex: "#D9D2C5")
    }

    /// Dim reader for dark rooms.
    static let dim = ReaderPalette(isDark: true,
                                   background: Color(hex: "#22262C") ?? .black,
                                   text: Color(hex: "#E8E3DA") ?? .white,
                                   secondary: Color(hex: "#ABA79F") ?? .gray,
                                   rule: Color.white.opacity(0.13),
                                   accent: Color(hex: "#E3A572") ?? .orange,
                                   textHex: "#E8E3DA", secondaryHex: "#ABA79F", linkHex: "#E3A572", ruleHex: "#3C4048")

    static func current(scheme: ColorScheme, dim: Bool) -> ReaderPalette {
        scheme == .dark ? (dim ? .dim : .paper(lightWindow: false)) : .paper(lightWindow: true)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Applies the Veery Mail palette and the user's appearance choice.
    func veeryTheme(_ appearance: String) -> some View {
        self.tint(Theme.accent)
            .preferredColorScheme(Theme.scheme(for: appearance))
    }

    /// Filled copper button.
    func primaryButton() -> some View {
        self.buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
    }
}
