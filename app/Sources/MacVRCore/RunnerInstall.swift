import Foundation

/// Runner mode: our builtin `wineopenxr.dll` and unixlib `wineopenxr.so` (and `macvrreg.dll`, RunnerRegistration) added to every NotProton runner's
/// `CrossOver/lib/wine`. The .so is universal (x86_64 + arm64) and goes to two places: `x86_64-unix`, which Rosetta
/// (x86_64 Wine) pairs with `x86_64-windows/wineopenxr.dll`, and `x86_64-windows`, because FEX (arm64 Wine) finds the
/// x86_64 PE only through NotProton's flat WINEDLLPATH entry `lib/wine/x86_64-windows` and takes the unixlib from that
/// same dir (as NotProton stages its lsteamclient.so). dyld picks the matching slice, so neither Wine can load a
/// wrong-arch copy. Add only: a file we didn't put there (sha not in our record) is never touched. The .so loads the
/// universal IPC client from `macvr/current/bridge/x86_64-unix`.
public enum RunnerInstall {
    /// Runner path (relative to `lib/wine`) <- bridge payload path.
    public static let files: [(dst: String, src: String)] = [
        ("x86_64-windows/wineopenxr.dll", "x86_64-windows/wineopenxr.dll"),
        ("x86_64-unix/wineopenxr.so", "x86_64-unix/wineopenxr.so"),
        ("x86_64-windows/wineopenxr.so", "x86_64-unix/wineopenxr.so"),
    ]

    /// `files` from the payload plus the per-user `macvrreg.dll` (when the payload has its template).
    static func sources(_ ctx: Context, generate: Bool) throws -> [(dst: String, src: URL)] {
        var out = files.map { (dst: $0.dst, src: ctx.bridgeDir.appendingPathComponent($0.src)) }
        let reg = generate ? try RunnerRegistration.generate(ctx) : RunnerRegistration.generated(ctx)
        if let reg { out.append((dst: "x86_64-windows/macvrreg.dll", src: reg)) }
        return out
    }

    /// A runner lacks one of our files (new runner, or NotProton replaced it).
    public static func needsInstall(_ ctx: Context) -> Bool {
        guard let srcs = try? sources(ctx, generate: false) else { return false }
        return wineLibDirs(ctx).contains { lib in
            srcs.contains { !FileManager.default.fileExists(atPath: lib.appendingPathComponent($0.dst).path) }
        }
    }

    static func recordURL(_ ctx: Context) -> URL { ctx.stateDir.appendingPathComponent("runner-files") }

    /// `<abs path>` -> sha256 of the copy we installed.
    static func loadRecord(_ ctx: Context) -> [String: String] {
        (try? String(contentsOf: recordURL(ctx), encoding: .utf8)).map(KeyValueFile.parse) ?? [:]
    }

    static func saveRecord(_ ctx: Context, _ r: [String: String]) throws {
        try FileManager.default.createDirectory(at: ctx.stateDir, withIntermediateDirectories: true)
        if r.isEmpty { try? FileManager.default.removeItem(at: recordURL(ctx)); return }
        try KeyValueFile.write(r, to: recordURL(ctx))
    }

    /// `runners/<name>/CrossOver/lib/wine` that have an x86_64 PE side.
    public static func wineLibDirs(_ ctx: Context) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ctx.runners.path)) ?? []
        return names.sorted().compactMap { n in
            let lib = ctx.runners.appendingPathComponent(n).appendingPathComponent("CrossOver/lib/wine")
            return FileManager.default.fileExists(atPath: lib.appendingPathComponent("x86_64-windows/ntdll.dll").path) ? lib : nil
        }
    }

    /// Architectures of a Mach-O file (thin or fat), e.g. `["x86_64", "arm64"]`.
    public static func machoArchs(_ url: URL) -> [String] {
        guard let h = FileHandle(forReadingAtPath: url.path), let d = try? h.read(upToCount: 4096) else { return [] }
        try? h.close()
        let b = [UInt8](d)
        func be32(_ o: Int) -> UInt32 { o + 4 <= b.count ? b[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        func name(_ cpu: UInt32) -> String { cpu == 0x0100_0007 ? "x86_64" : cpu == 0x0100_000C ? "arm64" : String(format: "cpu%x", cpu) }
        switch be32(0) {
        case 0xCAFE_BABE: return (0..<Int(min(be32(4), 16))).map { name(be32(8 + $0 * 20)) }
        case 0xCFFA_EDFE: return [name(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)]
        default: return []
        }
    }

    public struct Result { public var installed = 0, current = 0, foreign: [String] = [] }

    @discardableResult
    public static func ensure(_ ctx: Context) throws -> Result {
        var rec = loadRecord(ctx)
        var res = Result()
        defer { try? saveRecord(ctx, rec) }
        let srcs = try sources(ctx, generate: true)
        for lib in wineLibDirs(ctx) {
            for f in srcs {
                let src = f.src
                let dst = lib.appendingPathComponent(f.dst)
                guard let want = Deploy.sha256(src) else { throw MacVRError("no \(src.path): run install") }
                if let have = Deploy.sha256(dst) {
                    if have == want { rec[dst.path] = want; res.current += 1; continue }
                    guard rec[dst.path] == have else {
                        res.foreign.append(dst.path)
                        log("runner: \(dst.path) exists and isn't ours, left alone")
                        continue
                    }
                }
                let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).macvr-tmp")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: src, to: tmp)
                guard rename(tmp.path, dst.path) == 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw MacVRError("rename \(dst.path) failed")
                }
                rec[dst.path] = want
                res.installed += 1
                log("runner: installed \(dst.path)")
            }
        }
        return res
    }

    /// Removes exactly the files we installed (sha still ours).
    public static func remove(_ ctx: Context) {
        var rec = loadRecord(ctx)
        for (path, sha) in rec {
            let u = URL(fileURLWithPath: path)
            if let have = Deploy.sha256(u) {
                if have == sha {
                    try? FileManager.default.removeItem(at: u)
                    log("runner: removed \(path)")
                } else {
                    log("runner: \(path) changed since we installed it, left alone")
                }
            }
            rec[path] = nil
        }
        try? saveRecord(ctx, rec)
    }

    public struct FileState: Identifiable, Equatable {
        public var id: String { path }
        public var runner: String
        public var path: String
        public var file: String
        public var state: String
        public var archs: String?
    }

    public static func fileStates(_ ctx: Context) -> [FileState] {
        let rec = loadRecord(ctx)
        let srcs = (try? sources(ctx, generate: false)) ?? []
        return wineLibDirs(ctx).flatMap { lib in
            srcs.map { f -> FileState in
                let u = lib.appendingPathComponent(f.dst)
                let have = Deploy.sha256(u)
                let want = Deploy.sha256(f.src)
                let state = have == nil ? "missing" : have == want ? "ok" : rec[u.path] == have ? "ours, outdated" : "FOREIGN"
                let archs = f.dst.hasSuffix(".so") && have != nil ? machoArchs(u).joined(separator: "+") : nil
                return FileState(runner: lib.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                                 path: u.path, file: f.dst, state: state, archs: archs)
            }
        }
    }

    public static func status(_ ctx: Context) -> [String] {
        fileStates(ctx).map { "\($0.state)\($0.archs.map { " (\($0))" } ?? ""): \($0.path)" }
    }
}
