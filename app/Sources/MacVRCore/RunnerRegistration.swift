import Foundation

/// `macvrreg.dll`: a builtin whose `WINE_REGISTRY` resource holds our VR values as an ATL registrar script. wineboot
/// applies it to every prefix it creates or updates from the runner (`setupapi` `register_fake_dll`), so NotProton's
/// templates, which it builds at a runner's first launch, start with the values instead of getting them at the next
/// rescan. The payload's copy holds a fixed-size placeholder; the per-user copy is generated into `state/`.
public enum RunnerRegistration {
    static let begin = Data("MACVR-RGS-BEGIN".utf8)
    static let end = Data("MACVR-RGS-END".utf8)
    public static let payloadPath = "x86_64-windows/macvrreg.dll"

    public static func generated(_ ctx: Context) -> URL { ctx.stateDir.appendingPathComponent("macvrreg.dll") }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: "%", with: "%%") + "'"
    }

    public static func script(_ values: [RegValue]) -> String {
        func block(_ items: [([String], RegValue)], _ depth: Int) -> String {
            let pad = String(repeating: "\t", count: depth)
            var out = ""
            for (path, v) in items where path.isEmpty { out += "\(pad)val \(quote(v.name)) = s \(quote(v.value))\n" }
            var keys: [String] = []
            for (path, _) in items where !path.isEmpty && !keys.contains(path[0]) { keys.append(path[0]) }
            for k in keys {
                let sub = items.filter { !$0.0.isEmpty && $0.0[0] == k }.map { (Array($0.0.dropFirst()), $0.1) }
                out += "\(pad)NoRemove \(quote(k))\n\(pad){\n" + block(sub, depth + 1) + "\(pad)}\n"
            }
            return out
        }
        var out = ""
        for (root, file) in [("HKLM", "system.reg"), ("HKCU", "user.reg")] {
            let vs = values.filter { $0.file == file }.map { ($0.key.split(separator: "\\").map(String.init), $0) }
            if !vs.isEmpty { out += "\(root)\n{\n" + block(vs, 1) + "}\n" }
        }
        return out
    }

    /// The payload dll with its placeholder replaced by `script` (padded with spaces), or nil if it has none.
    public static func fill(_ dll: Data, script: String) throws -> Data? {
        guard let b = dll.range(of: begin), let e = dll.range(of: end, in: b.upperBound..<dll.endIndex) else { return nil }
        let size = e.upperBound - b.lowerBound
        var text = Data(script.utf8)
        guard text.count <= size else { throw MacVRError("registry script is \(text.count) bytes, room for \(size)") }
        text.append(Data(repeating: 0x20, count: size - text.count))
        var out = dll
        out.replaceSubrange(b.lowerBound..<e.upperBound, with: text)
        return out
    }

    /// Writes `state/macvrreg.dll` for the current values (only when it changes); nil without a payload template.
    @discardableResult
    public static func generate(_ ctx: Context) throws -> URL? {
        let src = ctx.bridgeDir.appendingPathComponent(payloadPath)
        guard let dll = try? Data(contentsOf: src),
              let out = try fill(dll, script: script(Rescan.desired(ctx))) else { return nil }
        let dst = generated(ctx)
        if (try? Data(contentsOf: dst)) == out { return dst }
        try FileManager.default.createDirectory(at: ctx.stateDir, withIntermediateDirectories: true)
        try out.write(to: dst, options: .atomic)
        return dst
    }
}
