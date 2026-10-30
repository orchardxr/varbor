import CryptoKit
import Foundation

/// Line-preserving edits of CrossOver's config format (cxbottle.conf): `[Section]`, `"Name" = "Value"`, `;` comments.
/// Section and field names are case-insensitive, as in CrossOver's CXConfig.pm.
public struct CXConfigFile {
    public var lines: [String]
    let trailingNewline: Bool

    public init(text: String) {
        trailingNewline = text.hasSuffix("\n")
        var l = text.components(separatedBy: "\n")
        if trailingNewline { l.removeLast() }
        lines = l
    }

    public var text: String { lines.joined(separator: "\n") + (trailingNewline ? "\n" : "") }

    static func sectionName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let e = t.firstIndex(of: "]") else { return nil }
        let rest = t[t.index(after: e)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix(";") else { return nil }
        return String(t[t.index(after: t.startIndex)..<e])
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ s: Substring) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    /// A quoted string starting at `i` (at the opening quote): its content and the index after the closing quote.
    static func quoted(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var escaped = false
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                return (unescape(s[s.index(after: s.startIndex)..<i]), s[s.index(after: i)...])
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// `"Name" = "Value"` or `Name = Value`; nil for comments, blanks and garbage.
    static func field(_ line: String) -> (name: String, value: String)? {
        let t = Substring(line.trimmingCharacters(in: .whitespaces))
        guard !t.isEmpty, !t.hasPrefix(";") else { return nil }
        if let (name, rest) = quoted(t) {
            let r = rest.drop { $0 == " " || $0 == "\t" }
            guard r.first == "=" else { return nil }
            let v = r.dropFirst().drop { $0 == " " || $0 == "\t" }
            if let (value, _) = quoted(v) { return (name, value) }
            return (name, String(v))
        }
        guard let eq = t.firstIndex(of: "=") else { return nil }
        return (t[..<eq].trimmingCharacters(in: .whitespaces), t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    public static func fieldLine(_ name: String, _ value: String) -> String {
        "\"\(escape(name))\" = \"\(escape(value))\""
    }

    /// Header line ..< next header (the last section with that name wins in CrossOver; we use the first).
    func section(_ name: String) -> Range<Int>? {
        guard let h = lines.firstIndex(where: { Self.sectionName($0)?.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        var e = h + 1
        while e < lines.count, Self.sectionName(lines[e]) == nil { e += 1 }
        return h..<e
    }

    func fieldIndex(_ section: String, _ name: String) -> Int? {
        guard let r = self.section(section) else { return nil }
        return lines[r].lastIndex { Self.field($0)?.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func get(_ section: String, _ name: String) -> String? {
        fieldIndex(section, name).flatMap { Self.field(lines[$0])?.value }
    }

    public func rawLine(_ section: String, _ name: String) -> String? {
        fieldIndex(section, name).map { lines[$0] }
    }

    public func hasSection(_ name: String) -> Bool { section(name) != nil }

    /// Replaces the field's line, or adds it after the section's last field (a missing section goes at the end).
    public mutating func setRaw(_ section: String, _ name: String, _ line: String) {
        if let i = fieldIndex(section, name) {
            lines[i] = line
            return
        }
        guard let r = self.section(section) else {
            lines += ["", "[\(section)]", line]
            return
        }
        let last = lines[r].lastIndex { Self.field($0) != nil } ?? r.lowerBound
        lines.insert(line, at: last + 1)
    }

    public mutating func delete(_ section: String, _ name: String) {
        guard let i = fieldIndex(section, name) else { return }
        lines.remove(at: i)
    }

    /// Removes a section that has no fields left, with the blank line `setRaw` put before it.
    public mutating func deleteSectionIfEmpty(_ section: String) {
        guard let r = self.section(section), !lines[r].dropFirst().contains(where: { Self.field($0) != nil }),
              lines[r].dropFirst().allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        let start = r.lowerBound > 0 && lines[r.lowerBound - 1].isEmpty ? r.lowerBound - 1 : r.lowerBound
        lines.removeSubrange(start..<r.upperBound)
    }
}

/// CrossOver bottles the user added. CrossOver.app's own Wine runs them, which we don't touch, so the bridge reaches a
/// bottle through its `cxbottle.conf`: `[Wine] "LibPath"` gets VarboR's `bottle-lib` appended. CrossOver's `bin/wine`
/// builds WINEDLLPATH from LibPath (`<lib>/wine/x86_64-windows` and `<lib>/wine` per entry) and overwrites any
/// WINEDLLPATH from `[EnvironmentVariables]`. Registry values are the same as in NotProton prefixes; the record and
/// backups live in `state/bottles/<id>`.
public enum Bottles {
    static let wineSection = "Wine"
    static let libPath = "LibPath"
    static let envSection = "EnvironmentVariables"
    static let recordKey = "conf|Wine|LibPath"
    static let sectionRecordKey = "conf|Wine"

    public static func defaultDir(_ ctx: Context) -> URL {
        ctx.home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    }

    /// Trees VarboR never touches: the `protected-paths` setting (`varbor protect add`) and `VARBOR_PROTECTED_PATHS`
    /// (colon-separated).
    public static func forbiddenRoots(_ ctx: Context) -> [URL] {
        let env = ProcessInfo.processInfo.environment["VARBOR_PROTECTED_PATHS"] ?? ""
        let fromEnv = env.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return ctx.protectedPaths + fromEnv
    }

    /// Why a path may not be added or edited, if it is in a forbidden tree.
    public static func forbidden(_ ctx: Context, _ url: URL) -> String? {
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        for r in forbiddenRoots(ctx) {
            for root in Set([r.standardizedFileURL.path, r.resolvingSymlinksInPath().standardizedFileURL.path])
            where p == root || p.hasPrefix(root + "/") {
                return "\(url.path) is under \(r.path), which VarboR leaves alone"
            }
        }
        return nil
    }

    public static func conf(_ bottle: URL) -> URL { bottle.appendingPathComponent("cxbottle.conf") }

    static func readConf(_ bottle: URL) -> CXConfigFile? {
        (try? String(contentsOf: conf(bottle), encoding: .utf8)).map(CXConfigFile.init)
    }

    /// Checks that a folder is a 64-bit CrossOver bottle VarboR may edit.
    public static func validate(_ ctx: Context, _ url: URL) throws {
        if let why = forbidden(ctx, url) { throw VarborError(why) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: conf(url).path), fm.fileExists(atPath: url.appendingPathComponent("system.reg").path),
              let c = readConf(url) else {
            throw VarborError("\(url.path) isn't a CrossOver bottle (no cxbottle.conf and system.reg)")
        }
        if let arch = c.get("Bottle", "WineArch"), arch.lowercased() != "win64" {
            throw VarborError("\(url.lastPathComponent) is a 32-bit bottle (\(arch)): VR needs a 64-bit bottle")
        }
    }

    static func id(_ bottle: URL) -> String {
        let h = SHA256.hash(data: Data(bottle.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(bottle.lastPathComponent)-\(h.prefix(8))"
    }

    public static func prefix(_ ctx: Context, _ bottle: URL) -> WinePrefix {
        WinePrefix(pfx: bottle, owner: ctx.stateDir.appendingPathComponent("bottles").appendingPathComponent(id(bottle)), kind: .bottle)
    }

    /// The added bottles that still exist (never one in a forbidden tree).
    public static func prefixes(_ ctx: Context) -> [WinePrefix] {
        ctx.bottles.filter { forbidden(ctx, $0) == nil && FileManager.default.fileExists(atPath: $0.appendingPathComponent("system.reg").path) }
            .map { prefix(ctx, $0) }
    }

    // MARK: graphics backend

    /// `CX_GRAPHICS_BACKEND` from the bottle's environment (nil: CrossOver's automatic choice).
    public static func backend(_ bottle: URL) -> String? {
        readConf(bottle)?.get(envSection, "CX_GRAPHICS_BACKEND").map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func backendWarning(_ bottle: URL) -> String? {
        switch backend(bottle) {
        case "dxmt", "dxvk": nil
        case nil: "graphics backend is Auto (may pick D3DMetal): set DXMT or DXVK in the bottle's settings"
        case let b?: "graphics backend is \(b): VR needs DXMT or DXVK"
        }
    }

    // MARK: bridge dir

    public static func libWine(_ ctx: Context) -> URL { ctx.bottleLib.appendingPathComponent("wine") }

    /// Copies the bridge into `bottle-lib/wine` (the same 3 files as a runner gets) when it differs.
    @discardableResult
    public static func ensureLib(_ ctx: Context) throws -> Bool {
        var changed = false
        for f in RunnerInstall.files {
            let src = ctx.bridgeDir.appendingPathComponent(f.src)
            let dst = libWine(ctx).appendingPathComponent(f.dst)
            guard let want = Deploy.sha256(src) else { throw VarborError("no \(src.path): run install") }
            if Deploy.sha256(dst) == want { continue }
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).varbor-tmp")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: src, to: tmp)
            guard rename(tmp.path, dst.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                throw VarborError("rename \(dst.path) failed")
            }
            changed = true
        }
        if changed { log("bottles: bridge copied to \(libWine(ctx).path)") }
        return changed
    }

    public static func removeLib(_ ctx: Context) {
        guard FileManager.default.fileExists(atPath: ctx.bottleLib.path) else { return }
        try? FileManager.default.removeItem(at: ctx.bottleLib)
        log("bottles: removed \(ctx.bottleLib.path)")
    }

    // MARK: cxbottle.conf

    static func hasOurs(_ value: String, _ ctx: Context) -> Bool {
        value.split(separator: ":").contains { $0 == ctx.bottleLib.path }
    }

    /// Our bottle-lib in any of our support dirs.
    static func isOurLib(_ entry: Substring, _ ctx: Context) -> Bool {
        ctx.supportDirs.contains { entry == $0.appendingPathComponent("bottle-lib").path }
    }

    /// LibPath with our dir appended; CrossOver's default is `${CX_ROOT}/lib`.
    static func wantedLibPath(_ current: String?, _ ctx: Context) -> String {
        guard let current, !current.isEmpty else { return "${CX_ROOT}/lib:\(ctx.bottleLib.path)" }
        return hasOurs(current, ctx) ? current : "\(current):\(ctx.bottleLib.path)"
    }

    public static func confOK(_ ctx: Context, _ bottle: URL) -> Bool {
        readConf(bottle)?.get(wineSection, libPath).map { hasOurs($0, ctx) } ?? false
    }

    /// The conf with our LibPath, recording the previous line; nil when nothing changes.
    static func fixedConf(_ c: CXConfigFile, _ ctx: Context, _ rec: inout Record) -> CXConfigFile? {
        let cur = c.get(wineSection, libPath)
        if let cur, hasOurs(cur, ctx) { return nil }
        var out = c
        if let cur, cur.split(separator: ":").contains(where: { isOurLib($0, ctx) }) {
            let moved = cur.split(separator: ":", omittingEmptySubsequences: false)
                .map { isOurLib($0, ctx) ? ctx.bottleLib.path : String($0) }.joined(separator: ":")
            out.setRaw(wineSection, libPath, CXConfigFile.fieldLine(libPath, moved))
            return out
        }
        if rec[recordKey] == nil { rec[recordKey] = c.rawLine(wineSection, libPath) ?? "-" }
        if !c.hasSection(wineSection) { rec[sectionRecordKey] = "created" }
        out.setRaw(wineSection, libPath, CXConfigFile.fieldLine(libPath, wantedLibPath(cur, ctx)))
        return out
    }

    /// The conf with our LibPath entry taken out again (the previous line restored); nil when nothing changes.
    static func revertedConf(_ c: CXConfigFile, _ ctx: Context, _ rec: Record) -> CXConfigFile? {
        guard let cur = c.get(wineSection, libPath), cur.split(separator: ":").contains(where: { isOurLib($0, ctx) }) else { return nil }
        var out = c
        let prev = rec[recordKey] ?? "-"
        if prev == "-" {
            let rest = cur.split(separator: ":", omittingEmptySubsequences: false).filter { !isOurLib($0, ctx) }
            if rest.isEmpty || rest == ["${CX_ROOT}/lib"] {
                out.delete(wineSection, libPath)
                if rec[sectionRecordKey] == "created" { out.deleteSectionIfEmpty(wineSection) }
            } else {
                out.setRaw(wineSection, libPath, CXConfigFile.fieldLine(libPath, rest.joined(separator: ":")))
            }
        } else {
            out.setRaw(wineSection, libPath, prev)
        }
        return out
    }

    static func writeConf(_ c: CXConfigFile, _ p: WinePrefix) throws {
        let url = conf(p.pfx)
        try Rescan.backup(url, p)
        let perm = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        try writeAtomically(Data(c.text.utf8), to: url, permissions: perm)
    }
}
