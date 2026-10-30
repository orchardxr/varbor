import Foundation

/// Minimal, line-preserving edits of a Wine registry file (system.reg, `WINE REGISTRY Version 2`).
public struct WineRegistry {
    public var lines: [String]
    let trailingNewline: Bool

    public init(text: String) throws {
        guard text.hasPrefix("WINE REGISTRY Version 2") else { throw VarborError("not a Wine registry file") }
        trailingNewline = text.hasSuffix("\n")
        var l = text.components(separatedBy: "\n")
        if trailingNewline { l.removeLast() }
        lines = l
    }

    public var text: String { lines.joined(separator: "\n") + (trailingNewline ? "\n" : "") }

    /// `Software\Khronos\OpenXR\1` -> `Software\\Khronos\\OpenXR\\1` (as written in the file).
    static func fileKey(_ key: String) -> String { escape(key) }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value >= 0x20 && u.value < 0x7f {
                    out.unicodeScalars.append(u)
                } else {
                    for unit in String(u).utf16 { out += String(format: "\\x%04x", unit) }
                }
            }
        }
        return out
    }

    static func unescape(_ s: Substring) -> String {
        var units: [UInt16] = []
        var it = Array(s.utf16)[...]
        while let c = it.popFirst() {
            guard c == 0x5c, let n = it.popFirst() else { units.append(c); continue }
            switch n {
            case 0x6e: units.append(0x0a)
            case 0x72: units.append(0x0d)
            case 0x74: units.append(0x09)
            case 0x78:
                var hex = ""
                while hex.count < 4, let h = it.first, let ch = Unicode.Scalar(h), ch.properties.isASCIIHexDigit {
                    hex.unicodeScalars.append(ch)
                    it.removeFirst()
                }
                units.append(UInt16(hex, radix: 16) ?? 0)
            default: units.append(n)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The header's key path (still escaped), for `[path] time` lines.
    static func headerKey(_ line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        var escaped = false
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "]" {
                return String(line[line.index(after: line.startIndex)..<i])
            }
            i = line.index(after: i)
        }
        return nil
    }

    /// Line range of the key's block: header line ..< first line of the next block.
    func block(_ key: String) -> Range<Int>? {
        let want = Self.fileKey(key).lowercased()
        guard let h = lines.firstIndex(where: { Self.headerKey($0)?.lowercased() == want }) else { return nil }
        var e = h + 1
        while e < lines.count, Self.headerKey(lines[e]) == nil { e += 1 }
        return h..<e
    }

    static func valueName(_ line: String) -> String? {
        if line.hasPrefix("@=") { return "" }
        guard line.hasPrefix("\"") else { return nil }
        var escaped = false
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                return unescape(line[line.index(after: line.startIndex)..<i])
            }
            i = line.index(after: i)
        }
        return nil
    }

    func valueLine(_ key: String, _ name: String) -> Int? {
        guard let b = block(key) else { return nil }
        return lines[b].firstIndex { Self.valueName($0)?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A REG_SZ value, or nil if missing or of another type.
    public func string(_ key: String, _ name: String) -> String? {
        guard let i = valueLine(key, name) else { return nil }
        let line = lines[i]
        guard let eq = line.range(of: "\"=\"") ?? (line.hasPrefix("@=\"") ? line.range(of: "@=\"") : nil),
              line.hasSuffix("\"") else { return nil }
        return Self.unescape(line[eq.upperBound..<line.index(before: line.endIndex)])
    }

    public func rawValueLine(_ key: String, _ name: String) -> String? {
        valueLine(key, name).map { lines[$0] }
    }

    static func valueLine(_ name: String, _ value: String) -> String {
        "\"\(escape(name))\"=\"\(escape(value))\""
    }

    public mutating func setString(_ key: String, _ name: String, _ value: String, now: Date = Date()) {
        setRaw(key, name, Self.valueLine(name, value), now: now)
    }

    /// Replaces or adds a value line as given (used to restore an old line verbatim).
    public mutating func setRaw(_ key: String, _ name: String, _ line: String, now: Date = Date()) {
        if let i = valueLine(key, name) {
            lines[i] = line
            return
        }
        if let b = block(key) {
            var end = b.upperBound
            while end > b.lowerBound + 1, lines[end - 1].isEmpty { end -= 1 }
            lines.insert(line, at: end)
            return
        }
        let secs = Int(now.timeIntervalSince1970)
        let filetime = UInt64(secs + 11_644_473_600) * 10_000_000
        let newBlock = ["[\(Self.fileKey(key))] \(secs)", "#time=\(String(filetime, radix: 16))", line, ""]
        lines.insert(contentsOf: newBlock, at: insertionPoint(for: key))
    }

    /// Removes a value; drops the block when nothing else is left in it.
    public mutating func deleteValue(_ key: String, _ name: String) {
        guard let i = valueLine(key, name) else { return }
        lines.remove(at: i)
        guard let b = block(key) else { return }
        let rest = lines[b.lowerBound + 1..<b.upperBound].filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if rest.isEmpty { lines.removeSubrange(b) }
    }

    /// Before the first block that sorts after `key` (Wine writes keys in tree order, case-insensitive).
    func insertionPoint(for key: String) -> Int {
        let want = key.lowercased().split(separator: "\\").map(String.init)
        for (i, line) in lines.enumerated() {
            guard let h = Self.headerKey(line) else { continue }
            let have = Self.unescape(Substring(h)).lowercased().split(separator: "\\").map(String.init)
            if have.lexicographicallyPrecedes(want) || have == want { continue }
            return i
        }
        return lines.count
    }
}
