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
                guard j < b.count else { throw MacVRError("vdf: unterminated string at \(i)") }
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
                guard t.kind == .string else { throw MacVRError("vdf: unexpected { at \(t.start)") }
                i += 1
                guard i < toks.count else { throw MacVRError("vdf: key without value at \(t.start)") }
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
                    throw MacVRError("vdf: unexpected } at \(v.start)")
                }
                parent.children.append(node)
            }
            if parent.depth >= 0 { throw MacVRError("vdf: missing } for \(parent.key)") }
            parent.closeStart = toks.last?.end ?? 0
        }
        try parseObject(root)
        return root
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Splices edits into the original bytes, last offset first.
struct ByteEdits {
    var edits: [(Range<Int>, String)] = []
    mutating func replace(_ r: Range<Int>, _ s: String) { edits.append((r, s)) }
    mutating func insert(at i: Int, _ s: String) { edits.append((i..<i, s)) }
    func apply(_ text: String) -> String {
        var b = Array(text.utf8)
        for (r, s) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            b.replaceSubrange(r, with: Array(s.utf8))
        }
        return String(decoding: b, as: UTF8.self)
    }
}

public enum LocalConfig {
    static let appsPath = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]

    public static func launchOptions(_ text: String, appid: String) throws -> String? {
        let root = try VDF.parse(text)
        return root.path(appsPath)?.child(appid)?.child("LaunchOptions")?.value
    }

    /// Sets (or with nil removes) an app's LaunchOptions, touching only that line.
    public static func setLaunchOptions(_ text: String, appid: String, to value: String?) throws -> String {
        let root = try VDF.parse(text)
        guard let apps = root.path(appsPath) else { throw MacVRError("localconfig: no apps section") }
        let enc = VDF.escape(value ?? "")
        var e = ByteEdits()
        let tabs = { (n: Int) in String(repeating: "\t", count: n) }
        if let app = apps.child(appid) {
            if let lo = app.child("LaunchOptions"), let r = lo.valueRange {
                if let value {
                    if lo.value == value { return text }
                    e.replace(r, enc)
                } else {
                    let b = Array(text.utf8)
                    var s = lo.entryRange.lowerBound
                    while s > 0, b[s - 1] == 0x09 { s -= 1 }
                    if s > 0, b[s - 1] == 0x0a { s -= 1 }
                    e.replace(s..<lo.entryRange.upperBound, "")
                }
            } else if value != nil {
                e.insert(at: app.openEnd, "\n\(tabs(app.depth + 1))\"LaunchOptions\"\t\t\"\(enc)\"")
            } else {
                return text
            }
        } else {
            guard value != nil else { return text }
            let d = apps.depth + 1
            let block = "\(tabs(d))\"\(appid)\"\n\(tabs(d)){\n\(tabs(d + 1))\"LaunchOptions\"\t\t\"\(enc)\"\n\(tabs(d))}\n"
            let b = Array(text.utf8)
            var s = apps.closeStart
            while s > 0, b[s - 1] == 0x09 { s -= 1 }
            if s > 0, b[s - 1] == 0x0a {
                e.insert(at: s, block)
            } else {
                e.insert(at: apps.closeStart, "\n" + block + tabs(apps.depth))
            }
        }
        let out = e.apply(text)
        _ = try VDF.parse(out)
        return out
    }
}
