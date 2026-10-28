import Foundation

/// Merges our env tokens into a Steam launch-options string, keeping the user's tokens.
/// Our block always starts with the marker `MACVR=1`, followed by our assignments, before `%command%`.
public enum LaunchOptions {
    public static let markerKey = "MACVR"
    public static let command = "%command%"

    public struct Token: Equatable {
        public let raw: String
        public var key: String? {
            guard let eq = raw.firstIndex(of: "="), eq != raw.startIndex else { return nil }
            let k = raw[..<eq]
            guard k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !k.first!.isNumber else { return nil }
            return String(k)
        }
        public var value: String? {
            guard key != nil, let eq = raw.firstIndex(of: "=") else { return nil }
            return unquote(String(raw[raw.index(after: eq)...]))
        }
    }

    public static func tokenize(_ s: String) -> [Token] {
        var toks: [Token] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { cur.append(ch); escaped = true; continue }
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); continue }
            if ch == " " || ch == "\t" || ch == "\n" {
                if !cur.isEmpty { toks.append(Token(raw: cur)); cur = "" }
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty { toks.append(Token(raw: cur)) }
        return toks
    }

    static func unquote(_ s: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote { if ch == q { quote = nil } else { out.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            out.append(ch)
        }
        return out
    }

    public static func assignment(_ key: String, _ value: String) -> String {
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "/._-:,+=@".contains($0) }
        if plain && !value.isEmpty { return "\(key)=\(value)" }
        let esc = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        return "\(key)=\"\(esc)\""
    }

    /// Removes our block (the marker and our assignments right after it).
    static func stripOurs(_ toks: [Token], keys: Set<String>) -> [Token] {
        var out: [Token] = []
        var inBlock = false
        for t in toks {
            if t.key == markerKey { inBlock = true; continue }
            if inBlock, let k = t.key, keys.contains(k) { continue }
            inBlock = false
            out.append(t)
        }
        return out
    }

    public struct Merge: Equatable {
        public var result: String
        /// User tokens we replaced (same keys, before %command%).
        public var displaced: [String]
        public var addedCommand: Bool
    }

    public static func apply(_ s: String, ours: [(String, String)]) -> Merge {
        let keys = Set(ours.map(\.0))
        let toks = stripOurs(tokenize(s), keys: keys)
        let block = ["\(markerKey)=1"] + ours.map { assignment($0.0, $0.1) }
        guard let ci = toks.firstIndex(where: { $0.raw == command }) else {
            let rest = toks.map(\.raw)
            return Merge(result: (block + [command] + rest).joined(separator: " "), displaced: [],
                         addedCommand: true)
        }
        var before: [String] = []
        var displaced: [String] = []
        for t in toks[..<ci] {
            if let k = t.key, keys.contains(k) { displaced.append(t.raw) } else { before.append(t.raw) }
        }
        let after = toks[(ci + 1)...].map(\.raw)
        return Merge(result: (block + before + [command] + after).joined(separator: " "), displaced: displaced,
                     addedCommand: false)
    }

    public static func hasOurs(_ s: String) -> Bool {
        tokenize(s).contains { $0.key == markerKey }
    }

    /// Our tokens out, displaced tokens back (before %command%). Returns "" when nothing of the user's is left.
    public static func remove(_ s: String, keys: Set<String>, restore: [String], addedCommand: Bool) -> String {
        var toks = stripOurs(tokenize(s), keys: keys).map(\.raw)
        if let ci = toks.firstIndex(of: command) {
            toks.insert(contentsOf: restore, at: ci)
            if addedCommand && toks.first == command { toks.removeFirst() }
        }
        if toks == [command] { return "" }
        return toks.joined(separator: " ")
    }
}
