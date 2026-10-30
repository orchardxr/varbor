import CryptoKit
import Foundation

/// Payload (the wineopenxr and vrclient bridges) -> `versions/<stamp>`, then `current` switched atomically.
public enum Deploy {
    /// The payload shipped in the app bundle (`Contents/Resources/payload`), or `VARBOR_PAYLOAD`.
    public static func bundledPayload() -> URL? {
        if let p = ProcessInfo.processInfo.environment["VARBOR_PAYLOAD"] { return URL(fileURLWithPath: p) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<3 {
            let p = dir.appendingPathComponent("Resources/payload")
            if FileManager.default.fileExists(atPath: p.appendingPathComponent("manifest.json").path) { return p }
            dir = dir.deletingLastPathComponent()
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("payload"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("manifest.json").path) { return r }
        return nil
    }

    static let required = [
        "bridge/x86_64-windows/wineopenxr.dll", "bridge/x86_64-unix/wineopenxr.so", "bridge/wineopenxr.json",
        "bridge/x86_64-windows/vrclient_x64.dll", "bridge/x86_64-unix/vrclient_x64.so",
    ]

    static func files(in dir: URL) -> [String] {
        let dir = dir.resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = String(u.resolvingSymlinksInPath().path.dropFirst(dir.path.count + 1))
            if rel != "manifest.json" && !rel.contains(".dSYM/") { out.append(rel) }
        }
        return out.sorted()
    }

    public static func sha256(_ url: URL) -> String? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Content stamp: the same payload always lands in the same version dir.
    static func stamp(_ dir: URL, _ files: [String]) throws -> (String, [String: String]) {
        var shas: [String: String] = [:]
        var all = SHA256()
        for f in files {
            guard let s = sha256(dir.appendingPathComponent(f)) else { throw VarborError("can't read \(f)") }
            shas[f] = s
            all.update(data: Data("\(f) \(s)\n".utf8))
        }
        return (all.finalize().prefix(6).map { String(format: "%02x", $0) }.joined(), shas)
    }

    public static func currentStamp(_ ctx: Context) -> String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: ctx.current.path)).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    @discardableResult
    public static func install(_ ctx: Context, payload: URL) throws -> String {
        let fm = FileManager.default
        for r in required where !fm.fileExists(atPath: payload.appendingPathComponent(r).path) {
            throw VarborError("payload \(payload.path) lacks \(r)")
        }
        let list = files(in: payload)
        let (stamp, shas) = try stamp(payload, list)
        let dest = ctx.versions.appendingPathComponent(stamp)
        try fm.createDirectory(at: ctx.versions, withIntermediateDirectories: true)
        try fm.createDirectory(at: ctx.stateDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) {
            let tmp = ctx.versions.appendingPathComponent(".tmp-\(stamp)")
            try? fm.removeItem(at: tmp)
            for f in list {
                let to = tmp.appendingPathComponent(f)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: payload.appendingPathComponent(f), to: to)
            }
            var manifest: [String: Any] = ["stamp": stamp, "files": shas,
                                           "installed": ISO8601DateFormatter().string(from: Date())]
            if let src = try? Data(contentsOf: payload.appendingPathComponent("manifest.json")),
               let j = try? JSONSerialization.jsonObject(with: src) as? [String: Any] {
                manifest["source"] = j
            }
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: tmp.appendingPathComponent("manifest.json"))
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            log("deploy: new version \(stamp)")
        }
        let old = currentStamp(ctx)
        if old != stamp {
            try relink(ctx.current, to: "versions/\(stamp)")
            if let old { try relink(ctx.previous, to: "versions/\(old)") }
            log("deploy: current -> \(stamp)" + (old.map { " (previous \($0))" } ?? ""))
        }
        prune(ctx)
        return stamp
    }

    static func relink(_ link: URL, to target: String) throws {
        let tmp = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).new")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createSymbolicLink(atPath: tmp.path, withDestinationPath: target)
        guard rename(tmp.path, link.path) == 0 else { throw VarborError("rename \(link.path) failed") }
    }

    /// Keeps current and previous.
    static func prune(_ ctx: Context) {
        let keep = Set([ctx.current, ctx.previous].compactMap {
            try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)
        }.map { URL(fileURLWithPath: $0).lastPathComponent })
        for v in (try? FileManager.default.contentsOfDirectory(atPath: ctx.versions.path)) ?? [] where !keep.contains(v) {
            try? FileManager.default.removeItem(at: ctx.versions.appendingPathComponent(v))
            log("deploy: removed old version \(v)")
        }
    }
}
