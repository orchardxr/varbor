import Foundation

public struct RegValue: Equatable {
    public let file: String
    public let key: String
    public let name: String
    public let value: String
    /// Data as written after `=` when it isn't a REG_SZ (e.g. `dword:00000001`).
    public var raw: String?

    public init(file: String, key: String, name: String, value: String, raw: String? = nil) {
        self.file = file
        self.key = key
        self.name = name
        self.value = value
        self.raw = raw
    }

    static func dword(file: String, key: String, name: String, _ v: UInt32) -> RegValue {
        RegValue(file: file, key: key, name: name, value: "\(v)", raw: String(format: "dword:%08x", v))
    }

    var recordKey: String { "reg|\(file)|\(key)|\(name)" }
    var line: String { raw.map { "\"\(WineRegistry.escape(name))\"=\($0)" } ?? WineRegistry.valueLine(name, value) }
}

/// Puts every NotProton prefix (and template) in the state VR needs, the way Proton prepares its prefixes, idempotently,
/// and records what it changed in `<compatdata/appid or template>/macvr-vr` so uninstall can revert exactly that:
/// - OpenXR: `ActiveRuntime` -> our wineopenxr.json.
/// - OpenVR: `C:\vrclient\bin\vrclient_x64.dll` (openvr_api.dll loads it, Wine runs the runner's builtin) and a
///   read-only `openvrpaths.vrpath` per Wine user naming `C:\vrclient` (Proton's setup_openvr_paths).
/// - `HKCU\Software\Wine\VR`, what Proton's steam.exe writes: DXVK reads its Vulkan extension lists there.
public enum Rescan {
    public static let openxrKey = "Software\\Khronos\\OpenXR\\1"
    public static let wineVRKey = "Software\\Wine\\VR"
    // CurrentControlSet is a link key; its data is stored under ControlSet001
    public static let hklmEnvKey = "System\\ControlSet001\\Control\\Session Manager\\Environment"
    public static let hkcuEnvKey = "Environment"
    static let hklmEnvKeyUnlinked = "System\\CurrentControlSet\\Control\\Session Manager\\Environment"

    /// Older Wine (CrossOver 26 bottles) keeps CurrentControlSet as a real key instead of a link to ControlSet001;
    /// the environment then lives under CurrentControlSet.
    static func resolve(_ v: RegValue, in reg: WineRegistry?) -> RegValue {
        guard v.key == hklmEnvKey, reg?.block(hklmEnvKeyUnlinked) != nil else { return v }
        return RegValue(file: v.file, key: hklmEnvKeyUnlinked, name: v.name, value: v.value, raw: v.raw)
    }

    public static func desired(_ ctx: Context) -> [RegValue] {
        [RegValue(file: "system.reg", key: openxrKey, name: "ActiveRuntime", value: dosPath(ctx.runtimeJSON)),
         // The bridge hands Metal textures to the runtime, so DXVK needs no extension: VK_KHR_surface, which it
         // enables anyway (an empty name would make vkCreateInstance fail).
         RegValue(file: "user.reg", key: wineVRKey, name: "openvr_vulkan_instance_extensions", value: "VK_KHR_surface"),
         .dword(file: "user.reg", key: wineVRKey, name: "state", 1)]
    }

    /// Values earlier versions set (Windows OpenComposite through VR_OVERRIDE): removed wherever they still point into
    /// a support dir of ours, record or not (game prefixes cloned from a template have none).
    static let obsolete: [(file: String, key: String, name: String)] = {
        var v: [(String, String, String)] = []
        for n in ["VR_OVERRIDE", "VR_CONFIG_PATH", "VR_LOG_PATH"] {
            v.append(("system.reg", hklmEnvKey, n))
            v.append(("system.reg", hklmEnvKeyUnlinked, n))
            v.append(("user.reg", hkcuEnvKey, n))
        }
        return v
    }()

    public struct Report {
        public var changed: [String] = []
        public var unchanged: [String] = []
        public var busy: [String] = []
        public var needsRetry: Bool { !busy.isEmpty }
        public var errors: [String] = []
        public var summary: String {
            "rescan: \(changed.count) changed, \(unchanged.count) ok, \(busy.count) busy"
                + (busy.isEmpty ? "" : " (\(busy.joined(separator: ", ")), retry later)")
                + (errors.isEmpty ? "" : ", errors: \(errors.joined(separator: "; "))")
        }
    }

    public static func run(_ ctx: Context) -> Report {
        var rep = Report()
        let want = desired(ctx)
        let bottles = Bottles.prefixes(ctx)
        if !bottles.isEmpty {
            do { try Bottles.ensureLib(ctx) } catch { rep.errors.append("bottle-lib: \(error)") }
        }
        // templates first: they are the primary mechanism, game prefixes only get what they miss
        for p in ctx.steam.prefixes.sorted(by: { $0.isTemplate && !$1.isTemplate }) + bottles {
            if ctx.isExcluded(p) {
                // macvrreg.dll re-adds our values whenever wineboot updates the prefix, so revert on every rescan.
                do {
                    if try MacVR.revertPrefix(ctx, p) { rep.changed.append(p.name) } else { rep.unchanged.append(p.name) }
                } catch let e as MacVRError where e.description == "busy" {
                    rep.busy.append(p.name)
                } catch {
                    rep.errors.append("\(p.name): \(error)")
                    log("rescan: \(p.name): \(error)")
                }
                continue
            }
            do {
                switch try fix(ctx, p, want: want) {
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

    static func fix(_ ctx: Context, _ p: WinePrefix, want: [RegValue]) throws -> Outcome {
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
        for o in obsolete { byFile[o.file, default: []] += [] }
        for (file, values) in byFile.sorted(by: { $0.key < $1.key }) {
            let url = p.pfx.appendingPathComponent(file)
            // a prefix Wine hasn't run yet may lack user.reg; it gets the values once it has one
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var reg = try WineRegistry(text: text)
            let orig = reg.lines
            let values = values.map { resolve($0, in: reg) }
            for v in values {
                let cur = reg.rawValueLine(v.key, v.name)
                if cur != v.line {
                    if !(cur.map { isOurs($0, ctx) } ?? false) || rec[v.recordKey] == nil {
                        rec[v.recordKey] = cur.flatMap { isOurs($0, ctx) ? nil : $0 } ?? "-"
                    }
                    reg.setRaw(v.key, v.name, v.line)
                }
            }
            for k in rec.values.keys.sorted() where k.hasPrefix("reg|\(file)|") && !values.contains(where: { $0.recordKey == k }) {
                revert(&reg, &rec, k, ctx: ctx)
            }
            for o in obsolete where o.file == file {
                guard let cur = reg.rawValueLine(o.key, o.name), isOurs(cur, ctx) else { continue }
                reg.deleteValue(o.key, o.name)
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

        if try fixVRClient(ctx, p, &rec) { changed = true }
        if try fixVRPath(ctx, p, &rec) { changed = true }

        return changed ? .changed : .unchanged
    }

    /// Restores the line that was there before us, if the value is still ours.
    static func revert(_ reg: inout WineRegistry, _ rec: inout Record, _ k: String, ctx: Context) {
        let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let prev = rec[k] else { return }
        let key = parts[2], name = parts[3]
        if let cur = reg.rawValueLine(key, name), isOurs(cur, ctx) || desiredLines(ctx).contains(cur) {
            if prev == "-" { reg.deleteValue(key, name) } else { reg.setRaw(key, name, prev) }
        }
        rec[k] = nil
    }

    /// Any value pointing into one of our support dirs counts as ours (survives a move of `current`).
    static func isOurs(_ line: String, _ ctx: Context) -> Bool {
        ctx.supportDirs.contains { line.contains(WineRegistry.escape(dosPath($0))) }
    }

    /// Our lines that hold no path of ours (the Wine\VR values): ours where they equal what we write.
    static func desiredLines(_ ctx: Context) -> Set<String> { Set(desired(ctx).map(\.line)) }

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

    // MARK: C:\vrclient

    static func vrclientDir(_ p: WinePrefix) -> URL { p.pfx.appendingPathComponent("drive_c/vrclient") }
    static func vrclientPlaceholder(_ p: WinePrefix) -> URL { vrclientDir(p).appendingPathComponent("bin/vrclient_x64.dll") }

    /// The placeholder openvr_api.dll loads; ours (record `vrclient=ours`) is kept equal to the payload's builtin.
    static func fixVRClient(_ ctx: Context, _ p: WinePrefix, _ rec: inout Record) throws -> Bool {
        let fm = FileManager.default
        let dst = vrclientPlaceholder(p)
        guard let want = Deploy.sha256(ctx.vrclientDLL) else { throw MacVRError("no \(ctx.vrclientDLL.path): run install") }
        let have = Deploy.sha256(dst)
        if have == want { return false }
        if have != nil && rec["vrclient"] != "ours" {
            if rec["vrclient"] != "foreign" { log("rescan: \(p.name): \(dst.path) isn't ours, left alone") }
            rec["vrclient"] = "foreign"
            return false
        }
        if busy(p) { return false }
        for d in ["bin", "config", "logs"] {
            try fm.createDirectory(at: vrclientDir(p).appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: ctx.vrclientDLL, to: dst)
        rec["vrclient"] = "ours"
        log("rescan: \(p.name): wrote \(dst.path)")
        return true
    }

    static func removeVRClient(_ p: WinePrefix, _ rec: Record) throws -> Bool {
        guard rec["vrclient"] == "ours" else { return false }
        let fm = FileManager.default
        let dir = vrclientDir(p)
        try? fm.removeItem(at: vrclientPlaceholder(p))
        for d in ["bin", "config", "logs", ""] {
            let u = d.isEmpty ? dir : dir.appendingPathComponent(d)
            if (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty == true { try? fm.removeItem(at: u) }
        }
        return true
    }

    // MARK: openvrpaths.vrpath

    static func vrpathJSON(_ ctx: Context) -> String {
        """
        {
        \t"config": [ "C:\\\\vrclient\\\\config" ],
        \t"external_drivers": null,
        \t"jsonid": "vrpathreg",
        \t"log": [ "C:\\\\vrclient\\\\logs" ],
        \t"runtime": [ "C:\\\\vrclient\\\\", "C:\\\\vrclient" ],
        \t"version": 1
        }

        """
    }

    static func vrpathFile(_ user: URL) -> URL {
        user.appendingPathComponent("AppData/Local/openvr/openvrpaths.vrpath")
    }

    /// Written by us before (an earlier version's, naming a support dir of ours) or by the old hand install: replaced
    /// without a backup.
    static func isReplaceableVRPath(_ text: String, _ ctx: Context) -> Bool {
        text.contains("C:\\\\OpenComposite")
            || ctx.supportDirs.contains { text.contains(dosPath($0).replacingOccurrences(of: "\\", with: "\\\\")) }
    }

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
            if cur == ours { continue }
            if let cur, !isReplaceableVRPath(cur, ctx) {
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
        }
        return changed
    }
}
