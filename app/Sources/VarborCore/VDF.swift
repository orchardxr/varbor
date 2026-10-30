import Foundation

/// Text KeyValues (Steam .vdf/.acf) with byte ranges, so edits can splice the original text.
public final class VDFNode {
    public let key: String
    public var value: String?
    public var children: [VDFNode] = []
    /// Range of the value's content (inside the quotes) for leaves.
    public var valueRange: Range<Int>?
    /// Range of the whole entry: from the key's opening quote to the closing brace or value quote.
    public var entryRange: Range<Int> = 0..<0
    /// Offset just after `{` and of `}` for objects.
    public var openEnd: Int = 0
    public var closeStart: Int = 0
    public var depth: Int = 0

    init(key: String) { self.key = key }

    public var isObject: Bool { value == nil }

    public func child(_ key: String) -> VDFNode? {
        children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    public func path(_ keys: [String]) -> VDFNode? {
        var n: VDFNode? = self
        for k in keys { n = n?.child(k) }
        return n
    }
}

public enum VDF {
    struct Token {
        enum Kind { case string, open, close }
        let kind: Kind
        let text: String
        let range: Range<Int>  // content range for strings, the brace for braces
        let start: Int
        let end: Int
    }

    static func tokenize(_ b: [UInt8]) throws -> [Token] {
        var toks: [Token] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d { i += 1; continue }
            if c == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "/") {
                while i < b.count, b[i] != 0x0a { i += 1 }
                continue
            }
            if c == UInt8(ascii: "{") { toks.append(Token(kind: .open, text: "{", range: i..<i + 1, start: i, end: i + 1)); i += 1; continue }
            if c == UInt8(ascii: "}") { toks.append(Token(kind: .close, text: "}", range: i..<i + 1, start: i, end: i + 1)); i += 1; continue }
            if c == UInt8(ascii: "\"") {
                let s = i + 1
                var j = s
                var out: [UInt8] = []
                while j < b.count, b[j] != UInt8(ascii: "\"") {
                    if b[j] == UInt8(ascii: "\\"), j + 1 < b.count {
                        let n = b[j + 1]
                        switch n {
                        case UInt8(ascii: "n"): out.append(0x0a)
                        case UInt8(ascii: "t"): out.append(0x09)
                        default: out.append(n)
                        }
                        j += 2
                        continue
                    }
                    out.append(b[j])
                    j += 1
                }
                guard j < b.count else { throw VarborError("vdf: unterminated string at \(i)") }
                toks.append(Token(kind: .string, text: String(decoding: out, as: UTF8.self), range: s..<j, start: i, end: j + 1))
                i = j + 1
                continue
            }
            let s = i
            while i < b.count, ![0x20, 0x09, 0x0a, 0x0d, UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\"")].contains(b[i]) { i += 1 }
            toks.append(Token(kind: .string, text: String(decoding: b[s..<i], as: UTF8.self), range: s..<i, start: s, end: i))
        }
        return toks
    }

    public static func parse(_ text: String) throws -> VDFNode {
        let toks = try tokenize(Array(text.utf8))
        let root = VDFNode(key: "")
        root.depth = -1
        var i = 0
        func parseObject(_ parent: VDFNode) throws {
            while i < toks.count {
                let t = toks[i]
                if t.kind == .close { parent.closeStart = t.start; i += 1; return }
                guard t.kind == .string else { throw VarborError("vdf: unexpected { at \(t.start)") }
                i += 1
                guard i < toks.count else { throw VarborError("vdf: key without value at \(t.start)") }
                let node = VDFNode(key: t.text)
                node.depth = parent.depth + 1
                let v = toks[i]
                if v.kind == .open {
                    node.openEnd = v.end
                    i += 1
                    try parseObject(node)
                    node.entryRange = t.start..<(node.closeStart + 1)
                } else if v.kind == .string {
                    node.value = v.text
                    node.valueRange = v.range
                    node.entryRange = t.start..<v.end
                    i += 1
                } else {
                    throw VarborError("vdf: unexpected } at \(v.start)")
                }
                parent.children.append(node)
            }
            if parent.depth >= 0 { throw VarborError("vdf: missing } for \(parent.key)") }
            parent.closeStart = toks.last?.end ?? 0
        }
        try parseObject(root)
        return root
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
