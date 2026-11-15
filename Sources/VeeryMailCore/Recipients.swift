import Foundation

/// One entry typed into a To, Cc or Bcc field.
public enum RecipientToken: Equatable, Sendable {
    case valid(EmailAddress, raw: String)
    case invalid(raw: String, reason: String)

    public var raw: String {
        switch self {
        case .valid(_, let raw), .invalid(let raw, _): return raw
        }
    }

    public var address: EmailAddress? {
        if case .valid(let a, _) = self { return a }
        return nil
    }
}

/// Parses recipient fields the way people actually type and paste them:
/// `"Doe, Jane" <jane@example.com>, bob@example.com; carol@example.org` and multi-line pastes.
/// Separators inside quotes or angle brackets are not split on. Invalid entries are returned,
/// never silently dropped, so the composer can point at them.
public enum RecipientParser {
    public static func parse(_ text: String) -> [RecipientToken] {
        split(text).map(token)
    }

    /// Valid addresses, or nil if any entry is invalid.
    public static func addresses(_ text: String) -> [EmailAddress]? {
        let tokens = parse(text)
        guard tokens.allSatisfy({ $0.address != nil }) else { return nil }
        return tokens.compactMap(\.address)
    }

    public static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false, inAngle = false, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            switch ch {
            case "\\" where inQuotes:
                escaped = true; current.append(ch)
            case "\"":
                inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes:
                inAngle = true; current.append(ch)
            case ">" where !inQuotes:
                inAngle = false; current.append(ch)
            case ",", ";", "\n", "\r":
                // (A `where` clause would only guard the last pattern, so check here.)
                if inQuotes || inAngle { current.append(ch) } else { parts.append(current); current = "" }
            default:
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func token(_ raw: String) -> RecipientToken {
        var name: String?
        var addr = raw
        if let lt = raw.lastIndex(of: "<") {
            guard let gt = raw.lastIndex(of: ">"), lt < gt,
                  raw[raw.index(after: gt)...].trimmingCharacters(in: .whitespaces).isEmpty else {
                return .invalid(raw: raw, reason: "Missing closing “>”")
            }
            addr = String(raw[raw.index(after: lt)..<gt])
            var display = raw[..<lt].trimmingCharacters(in: .whitespaces)
            if display.hasPrefix("\""), display.hasSuffix("\""), display.count >= 2 {
                display = String(display.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            name = display.isEmpty ? nil : display
        }
        addr = addr.trimmingCharacters(in: .whitespaces)
        if addr.lowercased().hasPrefix("mailto:") { addr = String(addr.dropFirst(7)) }
        if let reason = problem(with: addr) { return .invalid(raw: raw, reason: reason) }
        return .valid(EmailAddress(name: name, email: addr), raw: raw)
    }

    /// nil if `address` is a usable addr-spec (RFC 5322, dot-atom or quoted local part).
    public static func problem(with address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return "Missing “@”" }
        let local = String(address[..<at])
        let domain = String(address[address.index(after: at)...])
        guard !local.isEmpty else { return "Nothing before “@”" }
        guard !domain.isEmpty else { return "Nothing after “@”" }
        guard local.count <= 64, address.count <= 254 else { return "Address is too long" }

        if local.hasPrefix("\"") {
            guard local.hasSuffix("\""), local.count >= 2 else { return "Unclosed quotes" }
        } else {
            let atext = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "!#$%&'*+-/=?^_`{|}~."))
            guard local.unicodeScalars.allSatisfy({ atext.contains($0) || $0.value > 127 }) else {
                return "The part before “@” has characters that aren’t allowed"
            }
            guard !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else {
                return "Misplaced dot before “@”"
            }
        }

        if domain.hasPrefix("[") {
            return domain.hasSuffix("]") ? nil : "Unclosed address literal"
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return "The domain needs a dot, like example.com" }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return "The domain has an empty or overlong part" }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return "The domain can’t start or end a part with “-”" }
            let ok = label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0.value > 127
            }
            guard ok else { return "The domain has characters that aren’t allowed" }
        }
        return nil
    }
}

extension EmailAddress {
    /// Formats for an address field, quoting names that contain separators.
    public var fieldText: String {
        guard let name, !name.isEmpty else { return email }
        let needsQuotes = name.contains(where: { ",;<>\"@()[]:\\".contains($0) })
        let shown = needsQuotes
            ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            : name
        return "\(shown) <\(email)>"
    }
}
