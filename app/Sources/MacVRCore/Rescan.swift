import Foundation

public struct RegValue: Equatable {
    public let file: String
    public let key: String
    public let name: String
    public let value: String

    var recordKey: String { "reg|\(file)|\(key)|\(name)" }
    var line: String { WineRegistry.valueLine(name, value) }
}

/// Puts every NotProton prefix (and template) in the state VR needs, idempotently, and records what it changed in
/// `<compatdata/appid or template>/macvr-vr` so uninstall can revert exactly that.
public enum Rescan {
    public static let openxrKey = "Software\\Khronos\\OpenXR\\1"
    // CurrentControlSet is a link key; its data is stored under ControlSet001
    public static let hklmEnvKey = "System\\ControlSet001\\Control\\Session Manager\\Environment"
    public static let hkcuEnvKey = "Environment"
    static let hklmEnvKeyUnlinked = "System\\CurrentControlSet\\Control\\Session Manager\\Environment"

    /// Older Wine (CrossOver 26 bottles) keeps CurrentControlSet as a real key instead of a link to ControlSet001;
    /// the environment then lives under CurrentControlSet.
    static func resolve(_ v: RegValue, in reg: WineRegistry?) -> RegValue {
        guard v.key == hklmEnvKey, reg?.block(hklmEnvKeyUnlinked) != nil else { return v }
        return RegValue(file: v.file, key: hklmEnvKeyUnlinked, name: v.name, value: v.value)
    }

    public static func openvrEnv(_ ctx: Context) -> [(String, String)] {
        [("VR_OVERRIDE", dosPath(ctx.openCompositeDir)),
         ("VR_CONFIG_PATH", dosPath(ctx.openvrConfigDir)),
         ("VR_LOG_PATH", dosPath(ctx.openvrLogDir))]
    }

    public static func desired(_ ctx: Context) -> [RegValue] {
        var out = [RegValue(file: "system.reg", key: openxrKey, name: "ActiveRuntime", value: dosPath(ctx.runtimeJSON))]
        switch ctx.openvrMode {
        case "hklm-env":
            out += openvrEnv(ctx).map { RegValue(file: "system.reg", key: hklmEnvKey, name: $0.0, value: $0.1) }
        case "hkcu-env":
            out += openvrEnv(ctx).map { RegValue(file: "user.reg", key: hkcuEnvKey, name: $0.0, value: $0.1) }
        default: break
        }
        return out
    }

    public struct Report {
        public var changed: [String] = []
        public var unchanged: [String] = []
        public var busy: [String] = []
        public var legacyPending: [String] = []
        /// Apps whose legacy launch option waits for Steam to quit.
        public var launchOptionsPending: [String] = []
        public var needsRetry: Bool { !busy.isEmpty || !legacyPending.isEmpty || !launchOptionsPending.isEmpty }
        public var errors: [String] = []
        public var summary: String {
            "rescan: \(changed.count) changed, \(unchanged.count) ok, \(busy.count) busy"
                + (busy.isEmpty ? "" : " (\(busy.joined(separator: ", ")), retry later)")
                + (errors.isEmpty ? "" : ", errors: \(errors.joined(separator: "; "))")
        }
    }

    public static func run(_ ctx: Context, forceLegacy: Bool = false) -> Report {
        var rep = Report()
        let want = desired(ctx)
        let bottles = Bottles.prefixes(ctx)
        if !bottles.isEmpty {
            do { try Bottles.ensureLib(ctx) } catch { rep.errors.append("bottle-lib: \(error)") }
        }
        // templates first: they are the primary mechanism, game prefixes only get what they miss
        for p in ctx.steam.prefixes.sorted(by: { $0.isTemplate && !$1.isTemplate }) + bottles {
            do {
                switch try fix(ctx, p, want: want, forceLegacy: forceLegacy, report: &rep) {
                case .changed: rep.changed.append(p.name)
                case .unchanged: rep.unchanged.append(p.name)
                case .busy: rep.busy.append(p.name)
                }
            } catch {
                rep.errors.append("\(p.name): \(error)")
                log("rescan: \(p.name): \(error)")
            }
        }
        log(rep.summary)
        return rep
    }

    enum Outcome { case changed, unchanged, busy }

    static func busy(_ p: WinePrefix) -> Bool { Wineserver.running(prefix: p.pfx) }

    static func fix(_ ctx: Context, _ p: WinePrefix, want: [RegValue], forceLegacy: Bool,
                    report: inout Report) throws -> Outcome {
        var rec = Record.load(p.record) ?? Record()
        let before = rec.values
        var changed = false
        defer {
            if rec.values != before {
                rec["updated"] = ISO8601DateFormatter().string(from: Date())
                do {
                    try FileManager.default.createDirectory(at: p.owner, withIntermediateDirectories: true)
                    try rec.save(p.record)
                } catch {
                    log("rescan: \(p.name): record: \(error)")
                }
            }
        }

        if p.kind == .bottle {
            let url = Bottles.conf(p.pfx)
            let c = CXConfigFile(text: try String(contentsOf: url, encoding: .utf8))
            var r = rec
            if let fixed = Bottles.fixedConf(c, ctx, &r) {
                if busy(p) { return .busy }
                try Bottles.writeConf(fixed, p)
                rec = r
                changed = true
                log("rescan: \(p.name): cxbottle.conf LibPath += \(ctx.bottleLib.path)")
            }
        }

        // registry: wanted values set, values we set earlier but no longer want reverted
        var byFile: [String: [RegValue]] = [:]
        for v in want { byFile[v.file, default: []].append(v) }
        for k in rec.values.keys where k.hasPrefix("reg|") {
            let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !want.contains(where: { $0.recordKey == k }) else { continue }
            byFile[parts[1], default: []] += []
        }
        for (file, values) in byFile.sorted(by: { $0.key < $1.key }) {
            let url = p.pfx.appendingPathComponent(file)
            var reg = try WineRegistry(text: String(contentsOf: url, encoding: .utf8))
            let orig = reg.lines
            let values = values.map { resolve($0, in: reg) }
            for v in values {
                let cur = reg.rawValueLine(v.key, v.name)
                if cur != v.line {
                    // the hand install's system32 runtime is legacy, not something to restore
                    if !(cur.map { isOurs($0, ctx) } ?? false) || rec[v.recordKey] == nil {
                        rec[v.recordKey] = cur.flatMap { $0.contains("system32\\\\wineopenxr.json") || isOurs($0, ctx) ? nil : $0 } ?? "-"
                    }
                    reg.setRaw(v.key, v.name, v.line)
                }
            }
            for k in rec.values.keys.sorted() where k.hasPrefix("reg|\(file)|") && !values.contains(where: { $0.recordKey == k }) {
                revert(&reg, &rec, k, ctx: ctx)
            }
            if reg.lines != orig {
                if busy(p) { return .busy }
                guard let lock = PrefixLock(p.lockFile) else { return .busy }
                try withExtendedLifetime(lock) {
                    try backup(url, p)
                    let perm = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
                    try writeAtomically(Data(reg.text.utf8), to: url, permissions: perm)
                }
                changed = true
                log("rescan: \(p.name): \(file) updated")
            }
        }

        if try fixVRPath(ctx, p, &rec) { changed = true }
        if try fixLegacy(ctx, p, &rec, force: forceLegacy, report: &report) { changed = true }

        return changed ? .changed : .unchanged
    }

    /// Restores the line that was there before us, if the value is still ours.
    static func revert(_ reg: inout WineRegistry, _ rec: inout Record, _ k: String, ctx: Context) {
        let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let prev = rec[k] else { return }
        let key = parts[2], name = parts[3]
        if let cur = reg.rawValueLine(key, name), isOurs(cur, ctx) {
            if prev == "-" { reg.deleteValue(key, name) } else { reg.setRaw(key, name, prev) }
        }
        rec[k] = nil
    }

    /// Any value pointing into a macvr support dir counts as ours (survives a move of `current`).
    static func isOurs(_ line: String, _ ctx: Context) -> Bool {
        line.contains(WineRegistry.escape(dosPath(ctx.support)))
    }

    static func backup(_ url: URL, _ p: WinePrefix) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: p.backupDir, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let orig = p.backupDir.appendingPathComponent("\(name).orig")
        if !fm.fileExists(atPath: orig.path) { try fm.copyItem(at: url, to: orig) }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = p.backupDir.appendingPathComponent("\(name).\(f.string(from: Date()))")
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: url, to: dst)
        let old = ((try? fm.contentsOfDirectory(atPath: p.backupDir.path)) ?? [])
            .filter { $0.hasPrefix("\(name).2") }.sorted().dropLast(3)
        for o in old { try? fm.removeItem(at: p.backupDir.appendingPathComponent(o)) }
    }

    // MARK: openvrpaths.vrpath (fallback when the registry env doesn't reach the game)

    static func vrpathJSON(_ ctx: Context) -> String {
        let esc = { (u: URL) in dosPath(u).replacingOccurrences(of: "\\", with: "\\\\") }
        return """
        {
        \t"config": [ "\(esc(ctx.openvrConfigDir))" ],
        \t"external_drivers": null,
        \t"jsonid": "vrpathreg",
        \t"log": [ "\(esc(ctx.openvrLogDir))" ],
        \t"runtime": [ "\(esc(ctx.openCompositeDir))" ],
        \t"version": 1
        }

        """
    }

    static func vrpathFile(_ user: URL) -> URL {
        user.appendingPathComponent("AppData/Local/openvr/openvrpaths.vrpath")
    }

    static func isLegacyVRPath(_ text: String) -> Bool { text.contains("C:\\\\OpenComposite") }

    static func removeFile(_ u: URL) throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)
        try FileManager.default.removeItem(at: u)
    }

    static func fixVRPath(_ ctx: Context, _ p: WinePrefix, _ rec: inout Record) throws -> Bool {
        let fm = FileManager.default
        let ours = vrpathJSON(ctx)
        var changed = false
        for user in p.userDirs {
            let f = vrpathFile(user)
            let rk = "vrpath|\(user.lastPathComponent)"
            let cur = try? String(contentsOf: f, encoding: .utf8)
            if ctx.openvrMode == "vrpath" {
                if cur == ours { continue }
                if let cur, !isLegacyVRPath(cur) {
                    try fm.createDirectory(at: p.backupDir, withIntermediateDirectories: true)
                    let b = p.backupDir.appendingPathComponent("openvrpaths.vrpath.\(user.lastPathComponent)")
                    try? fm.removeItem(at: b)
                    try fm.copyItem(at: f, to: b)
                    rec[rk] = b.path
                } else if rec[rk] == nil {
                    rec[rk] = "-"
                }
                if cur != nil { try removeFile(f) }
                try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                // read-only: NotProton's steam.exe deletes a writable one at every launch
                try writeAtomically(Data(ours.utf8), to: f, permissions: 0o444)
                changed = true
                log("rescan: \(p.name): wrote read-only \(f.path)")
            } else if let prev = rec[rk] {
                if cur == ours {
                    try removeFile(f)
                    if prev != "-" { try fm.copyItem(atPath: prev, toPath: f.path) }
                    changed = true
                    log("rescan: \(p.name): removed our vrpath (mode \(ctx.openvrMode))")
                }
                rec[rk] = nil
            }
        }
        return changed
    }

    // MARK: legacy hand install (scripts/install-vr-546560.sh)

    public static func legacyItems(_ p: WinePrefix, _ ctx: Context) -> [URL] {
        guard p.kind != .bottle else { return [] }
        let c = p.pfx.appendingPathComponent("drive_c")
        var items = [c.appendingPathComponent("macvr"), c.appendingPathComponent("OpenComposite"),
                     c.appendingPathComponent("windows/system32/wineopenxr.json")]
        // Wine copies every builtin of the runner (ours included) into system32 when it sets up a prefix; only the
        // hand install put a json beside it.
        if FileManager.default.fileExists(atPath: items[2].path) {
            items.append(c.appendingPathComponent("windows/system32/wineopenxr.dll"))
        }
        if ctx.openvrMode != "vrpath" {
            for u in p.userDirs {
                let f = vrpathFile(u)
                if let t = try? String(contentsOf: f, encoding: .utf8), isLegacyVRPath(t) { items.append(f) }
            }
        }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func provenFile(_ ctx: Context, _ appid: String) -> URL {
        ctx.stateDir.appendingPathComponent("proven-\(appid)")
    }

    /// Moves the hand-installed files into macvr-backup/, once a game has run through the new path (or forced).
    static func fixLegacy(_ ctx: Context, _ p: WinePrefix, _ rec: inout Record, force: Bool,
                          report: inout Report) throws -> Bool {
        let items = legacyItems(p, ctx)
        guard !items.isEmpty else { return false }
        let proven = FileManager.default.fileExists(atPath: provenFile(ctx, p.owner.lastPathComponent).path)
        guard force || proven else {
            if rec["legacy"] != "present" { log("rescan: \(p.name): legacy install present, kept until the new path is proven") }
            rec["legacy"] = "present"
            report.legacyPending.append(p.name)
            return false
        }
        if busy(p) { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = p.backupDir.appendingPathComponent("legacy-\(f.string(from: Date()))")
        for item in items {
            let rel = String(item.path.dropFirst(p.pfx.path.count + 1))
            let dst = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: item.path)
            try FileManager.default.moveItem(at: item, to: dst)
        }
        rec["legacy"] = "removed:\(dir.path)"
        log("rescan: \(p.name): legacy install moved to \(dir.path)")
        return true
    }
}
