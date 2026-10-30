import Foundation

public enum Varbor {
    public static let backendNote = "VR works with the DXMT and DXVK graphics backends (set in the game's NotProton "
        + "compatibility settings); DXMT is preferred. D3DMetal isn't supported."

    /// What the app does each time it opens (and `varbor install`): deploy, runner files, prefixes.
    @discardableResult
    public static func install(_ ctx: Context, payload: URL?) throws -> Rescan.Report {
        if let payload {
            try Deploy.install(ctx, payload: payload)
        } else if Deploy.currentStamp(ctx) == nil {
            throw VarborError("no payload found and nothing installed")
        }
        let r = try RunnerInstall.ensure(ctx)
        log("runner: \(r.installed) installed, \(r.current) current" + (r.foreign.isEmpty ? "" : ", \(r.foreign.count) foreign left alone"))
        return rescan(ctx)
    }

    /// Adds missing or outdated runner files (a runner set up while the app runs, a changed OpenVR mode).
    public static func refreshRunners(_ ctx: Context) {
        do {
            let r = try RunnerInstall.ensure(ctx)
            if r.installed > 0 { log("runner: \(r.installed) installed, \(r.current) current") }
        } catch {
            log("runner: \(error)")
        }
    }

    @discardableResult
    public static func rescan(_ ctx: Context) -> Rescan.Report {
        Rescan.run(ctx)
    }

    // MARK: uninstall

    public struct UninstallReport {
        public var reverted: [String] = []
        public var busy: [String] = []
        public var errors: [String] = []
    }

    static let managedValues: [(String, String, String)] =
        [("system.reg", Rescan.openxrKey, "ActiveRuntime"),
         ("user.reg", Rescan.wineVRKey, "openvr_vulkan_instance_extensions"),
         ("user.reg", Rescan.wineVRKey, "state")]

    /// Reverts every prefix and template (values that are ours: restored from the record, else removed) and the
    /// runner files.
    public static func uninstall(_ ctx: Context) -> UninstallReport {
        var rep = UninstallReport()
        for p in ctx.steam.prefixes + Bottles.prefixes(ctx) {
            do {
                if try revertPrefix(ctx, p) { rep.reverted.append(p.name) }
            } catch let e as VarborError where e.description == "busy" {
                rep.busy.append(p.name)
            } catch {
                rep.errors.append("\(p.name): \(error)")
            }
        }
        if rep.busy.isEmpty {
            RunnerInstall.remove(ctx)
            Bottles.removeLib(ctx)
        } else {
            log("uninstall: runner files kept, prefixes busy")
        }
        log("uninstall: \(rep.reverted.count) reverted, busy: \(rep.busy), errors: \(rep.errors)")
        return rep
    }

    static func revertPrefix(_ ctx: Context, _ p: WinePrefix) throws -> Bool {
        let rec = Record.load(p.record) ?? Record()
        var changed = false
        if p.kind == .bottle, let text = try? String(contentsOf: Bottles.conf(p.pfx), encoding: .utf8),
           let c = Bottles.revertedConf(CXConfigFile(text: text), ctx, rec) {
            if Wineserver.running(prefix: p.pfx) { throw VarborError("busy") }
            try Bottles.writeConf(c, p)
            changed = true
        }
        for file in ["system.reg", "user.reg"] {
            let url = p.pfx.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var reg = try WineRegistry(text: text)
            let orig = reg.lines
            let lines = Rescan.desiredLines(ctx)
            for (f, key, name) in managedValues where f == file {
                guard let cur = reg.rawValueLine(key, name), Rescan.isOurs(cur, ctx) || lines.contains(cur) else { continue }
                let prev = rec["reg|\(file)|\(key)|\(name)"] ?? "-"
                if prev == "-" { reg.deleteValue(key, name) } else { reg.setRaw(key, name, prev) }
            }
            guard reg.lines != orig else { continue }
            if Wineserver.running(prefix: p.pfx) { throw VarborError("busy") }
            guard let lock = PrefixLock(p.lockFile) else { throw VarborError("busy") }
            try withExtendedLifetime(lock) {
                try Rescan.backup(url, p)
                let perm = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
                try writeAtomically(Data(reg.text.utf8), to: url, permissions: perm)
            }
            changed = true
        }
        if try Rescan.removeVRClient(p, rec) { changed = true }
        let ours = Rescan.vrpathJSON(ctx)
        for user in p.userDirs {
            let f = Rescan.vrpathFile(user)
            guard (try? String(contentsOf: f, encoding: .utf8)) == ours else { continue }
            try Rescan.removeFile(f)
            if let b = rec["vrpath|\(user.lastPathComponent)"], b != "-" {
                try FileManager.default.copyItem(atPath: b, toPath: f.path)
            }
            changed = true
        }
        if FileManager.default.fileExists(atPath: p.record.path) {
            try FileManager.default.removeItem(at: p.record)
            changed = true
        }
        if p.kind == .bottle { try? FileManager.default.removeItem(at: p.owner) }
        if changed { log("uninstall: \(p.name) reverted") }
        return changed
    }

    // MARK: status

    public static func statusText(_ ctx: Context) -> String {
        var out: [String] = []
        out.append("version: \(Deploy.currentStamp(ctx) ?? "not installed")"
                   + ((try? FileManager.default.destinationOfSymbolicLink(atPath: ctx.previous.path)).map { " (previous \(URL(fileURLWithPath: $0).lastPathComponent))" } ?? ""))
        out.append("components:")
        for c in Components.all(.real(ctx)) {
            out.append("  \(c.name): \(c.health.rawValue)" + (c.version.map { " \($0)" } ?? "") + (c.location.map { " (\($0))" } ?? ""))
            out += c.notes.map { "    \($0)" }
            if c.health == .missing || c.health == .outdated { out.append("    get it: \(c.page.absoluteString)") }
            out += c.items.map { "    \($0)" }
        }
        out.append("runner files:")
        out += RunnerInstall.status(ctx).map { "  " + $0 }
        out.append("prefixes:")
        for st in prefixStates(ctx) {
            out.append("  \(st.name): \(st.summary)" + (st.kind == .bottle ? " (\(st.path))" : ""))
            if let w = st.warning { out.append("    warning: \(w)") }
        }
        if !ctx.extraLibraries.isEmpty {
            out.append("added Steam libraries: " + ctx.extraLibraries.map(\.path).joined(separator: ", "))
        }
        out.append("VR games:")
        for (app, hit) in ctx.steam.vrGames() { out.append("  \(app.appid) \(app.name) (\(hit))") }
        out.append(backendNote)
        return out.joined(separator: "\n")
    }

    public struct PrefixState: Identifiable, Equatable {
        public var id: String { path }
        public var name: String
        public var path: String
        public var kind: WinePrefix.Kind
        public var missing: [String]
        public var busy: Bool
        public var record: Bool
        public var warning: String?
        /// From a bottle or Steam library the user added.
        public var userAdded: Bool
        /// The user excluded it: VarboR keeps its settings out of this prefix.
        public var excluded = false

        public var state: String {
            excluded ? "excluded" : busy ? "busy" : missing.isEmpty ? "ok" : "missing values"
        }

        public var summary: String {
            (excluded ? "excluded" : missing.isEmpty ? "ok" : "missing \(missing.joined(separator: " "))") + (record ? ", record" : "")
                + (busy ? ", wineserver running" : "")
        }
    }

    /// What `status` shows per prefix: Steam prefixes and templates (incl. added libraries), then added bottles.
    public static func prefixStates(_ ctx: Context) -> [PrefixState] {
        let want = Rescan.desired(ctx)
        let steam = ctx.steam
        let vdfLibs = Set(steam.steamLibraries.map { $0.standardizedFileURL.path })
        return (steam.prefixes + Bottles.prefixes(ctx)).map { p in
            var missing: [String] = []
            var regs: [String: WineRegistry] = [:]
            for v in want {
                if regs[v.file] == nil {
                    regs[v.file] = (try? String(contentsOf: p.pfx.appendingPathComponent(v.file), encoding: .utf8))
                        .flatMap { try? WineRegistry(text: $0) }
                }
                let v = Rescan.resolve(v, in: regs[v.file])
                if regs[v.file]?.rawValueLine(v.key, v.name) != v.line { missing.append(v.name) }
            }
            for u in p.userDirs where (try? String(contentsOf: Rescan.vrpathFile(u), encoding: .utf8)) != Rescan.vrpathJSON(ctx) {
                missing.append("vrpath(\(u.lastPathComponent))")
            }
            if Deploy.sha256(Rescan.vrclientPlaceholder(p)) != Deploy.sha256(ctx.vrclientDLL) { missing.append("C:\\vrclient") }
            var userAdded = p.kind == .bottle
            if p.kind == .bottle {
                if !Bottles.confOK(ctx, p.pfx) { missing.append("LibPath") }
            } else {
                var lib = p.owner.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                if p.isTemplate { lib = lib.deletingLastPathComponent() }
                userAdded = !vdfLibs.contains(lib.standardizedFileURL.path)
            }
            return PrefixState(name: p.name, path: p.pfx.path, kind: p.kind, missing: missing,
                               busy: Wineserver.running(prefix: p.pfx),
                               record: FileManager.default.fileExists(atPath: p.record.path),
                               warning: p.kind == .bottle ? Bottles.backendWarning(p.pfx) : nil, userAdded: userAdded,
                               excluded: ctx.isExcluded(p))
        }
    }

    /// Excludes a Steam game prefix (its compatdata/<appid> dir) from VarboR, reverting it, or includes it again.
    @discardableResult
    public static func setExcluded(_ ctx: Context, _ owner: URL, _ excluded: Bool) throws -> Rescan.Report {
        let owner = owner.standardizedFileURL
        var list = ctx.excludedPrefixes.filter { !same($0, owner) }
        if excluded { list.append(owner) }
        try ctx.setPathList("excluded-prefixes", list)
        log("prefixes: \(excluded ? "excluded" : "included") \(owner.path)")
        return rescan(ctx)
    }

    // MARK: user-added bottles and Steam libraries

    static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    /// Adds a CrossOver bottle and fixes it right away.
    @discardableResult
    public static func addBottle(_ ctx: Context, _ url: URL) throws -> Rescan.Report {
        let url = url.standardizedFileURL
        try Bottles.validate(ctx, url)
        var list = ctx.bottles
        if !list.contains(where: { same($0, url) }) {
            list.append(url)
            try ctx.setPathList("bottles", list)
            log("bottles: added \(url.path)")
        }
        return rescan(ctx)
    }

    /// Reverts a bottle (registry, cxbottle.conf) and forgets it. Throws while its wineserver runs.
    public static func removeBottle(_ ctx: Context, _ url: URL) throws {
        guard let known = ctx.bottles.first(where: { same($0, url) }) else { throw VarborError("\(url.path) isn't an added bottle") }
        if Bottles.forbidden(ctx, known) == nil, FileManager.default.fileExists(atPath: known.appendingPathComponent("system.reg").path) {
            do {
                _ = try revertPrefix(ctx, Bottles.prefix(ctx, known))
            } catch let e as VarborError where e.description == "busy" {
                throw VarborError("\(known.lastPathComponent) is in use (its wineserver runs): quit its programs and try again")
            }
        }
        try ctx.setPathList("bottles", ctx.bottles.filter { !same($0, known) })
        log("bottles: removed \(known.path)")
    }

    /// Adds a Steam library folder (its root or its `steamapps`) and fixes its prefixes.
    @discardableResult
    public static func addLibrary(_ ctx: Context, _ url: URL) throws -> Rescan.Report {
        let root = Steam.libraryRoot(url.standardizedFileURL)
        if let why = Bottles.forbidden(ctx, root) { throw VarborError(why) }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) else {
            throw VarborError("\(root.path) isn't a Steam library (no steamapps folder)")
        }
        var list = ctx.extraLibraries
        if !list.contains(where: { same($0, root) }) {
            list.append(root)
            try ctx.setPathList("steam-libraries", list)
            log("steam: added library \(root.path)")
        }
        return rescan(ctx)
    }

    /// Forgets an added library; its prefixes are reverted unless Steam itself lists the library.
    public static func removeLibrary(_ ctx: Context, _ url: URL) throws {
        let root = Steam.libraryRoot(url.standardizedFileURL)
        guard let known = ctx.extraLibraries.first(where: { same($0, root) }) else { throw VarborError("\(root.path) isn't an added library") }
        let steamListed = Steam(root: ctx.steamRoot).steamLibraries.contains { same($0, known) }
        if !steamListed, Bottles.forbidden(ctx, known) == nil {
            let busy = Steam(root: ctx.steamRoot, extraLibraries: [known]).prefixes
                .filter { $0.pfx.path.hasPrefix(known.standardizedFileURL.path + "/") }
                .filter { p in
                    do { _ = try revertPrefix(ctx, p); return false } catch { return true }
                }
            if !busy.isEmpty {
                throw VarborError("in use: \(busy.map(\.name).joined(separator: ", ")); quit the game and try again")
            }
        }
        try ctx.setPathList("steam-libraries", ctx.extraLibraries.filter { !same($0, known) })
        log("steam: removed library \(known.path)")
    }
}
