import Foundation

/// The VarboR runner: an APFS clone of a stock NotProton runner with the engines from orchardxr/varbor-engines
/// (patched DXMT, ARM64EC DXVK) in its `CrossOver/lib`, plus a Steam compat tool per NotProton tool of the stock build.
///
/// A stock runner (CrossOver version from its build name, stock DXMT version read from `lib/dxmt/*/d3d11.dll`) maps
/// to the release tagged `cx-<CrossOver version>`. Its `engines.json` names the stock DXMT versions it fits, an
/// archive and the sha256 of the archive and of every file in it. Network calls happen only through an
/// `EngineSource`, which the app uses at launch (`check`) and when the user installs (`install`).
public protocol EngineSource: Sendable {
    /// The release's `engines.json`, or nil when there is no such release.
    func metadata(tag: String) async throws -> Data?
    /// Downloads the release asset `name` to `to`.
    func download(tag: String, asset name: String, to: URL) async throws
}

public struct GitHubEngineSource: EngineSource {
    public var repo = Engines.repo
    public init() {}

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let assets: [Asset]
    }

    func release(_ tag: String) async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw VarborError("engines: GitHub answered \(code) for \(tag)") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    func asset(_ tag: String, _ name: String) async throws -> URL? {
        try await release(tag)?.assets.first { $0.name == name }?.browser_download_url
    }

    public func metadata(tag: String) async throws -> Data? {
        guard let url = try await asset(tag, Engines.metadataAsset) else { return nil }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VarborError("engines: \(tag)/\(Engines.metadataAsset) download failed") }
        return data
    }

    public func download(tag: String, asset name: String, to: URL) async throws {
        guard let url = try await asset(tag, name) else { throw VarborError("engines: \(tag) has no asset \(name)") }
        let (file, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VarborError("engines: \(name) download failed") }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: file, to: to)
    }
}

public enum Engines {
    public static let repo = "orchardxr/varbor-engines"
    public static let metadataAsset = "engines.json"
    public static let suffix = "-varbor"
    static let marker = ".varbor"

    // MARK: runners

    public struct StockRunner: Equatable, Sendable {
        /// `crossover-27.0.0.41073-fex`
        public var name: String
        /// `27.0.0.41073-fex`, the NotProton build
        public var build: String
        /// `27.0.0.41073`
        public var crossover: String
        /// e.g. `v0.80-279-g8f06be3`
        public var dxmt: String?
        public var dir: URL

        public var tag: String { "cx-\(crossover)" }
        public var cloneBuild: String { build + Engines.suffix }
    }

    /// `27.0.0.41073-fex` -> `27.0.0.41073`
    public static func crossoverVersion(build: String) -> String? {
        guard let r = build.range(of: #"^\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(build[r])
    }

    /// The git-describe version DXMT's build stamps into its DLLs.
    public static func dxmtVersion(_ crossover: URL) -> String? {
        for arch in ["x86_64-windows", "aarch64-windows", "i386-windows"] {
            let dll = crossover.appendingPathComponent("lib/dxmt/\(arch)/d3d11.dll")
            guard let d = try? Data(contentsOf: dll, options: .mappedIfSafe) else { continue }
            let text = String(decoding: d.map { $0 >= 0x20 && $0 < 0x7f ? $0 : 0x0a }, as: UTF8.self)
            for pattern in [#"(?m)^v\d+\.\d+-\d+-g[0-9a-f]{7,}$"#, #"(?m)^v\d+\.\d+(\.\d+)?$"#] {
                if let r = text.range(of: pattern, options: .regularExpression) { return String(text[r]) }
            }
        }
        return nil
    }

    static func isClone(_ dir: URL, _ name: String) -> Bool {
        name.hasSuffix(suffix) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path)
    }

    /// NotProton's own runners (not our clones) with a CrossOver lib/dxmt.
    public static func stockRunners(_ ctx: Context) -> [StockRunner] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: ctx.runners.path)) ?? []).sorted().compactMap { n in
            let dir = ctx.runners.appendingPathComponent(n)
            guard n.hasPrefix("crossover-"), !isClone(dir, n) else { return nil }
            let build = String(n.dropFirst("crossover-".count))
            guard let cx = crossoverVersion(build: build),
                  fm.fileExists(atPath: dir.appendingPathComponent("CrossOver/lib/dxmt").path) else { return nil }
            return StockRunner(name: n, build: build, crossover: cx, dxmt: dxmtVersion(dir.appendingPathComponent("CrossOver")), dir: dir)
        }
    }

    public static func cloneDir(_ ctx: Context, _ r: StockRunner) -> URL {
        ctx.runners.appendingPathComponent("crossover-\(r.cloneBuild)")
    }

    // MARK: metadata

    /// `engines.json` (format 1):
    /// `{"format": 1, "crossover": "27.0.0.41073", "stock_dxmt": ["v0.80-279-g8f06be3"],
    ///   "engines": {"dxmt": "...", "dxvk": "..."},
    ///   "archive": {"name": "varbor-engines-cx-27.0.0.41073.tar.xz", "sha256": "..."},
    ///   "files": {"lib/dxmt/aarch64-windows/d3d11.dll": "<sha256>", ...}}`
    /// Paths are relative to the runner's `CrossOver` dir.
    public struct Metadata: Decodable, Equatable, Sendable {
        public struct Archive: Decodable, Equatable, Sendable {
            public var name: String
            public var sha256: String
        }
        public var format: Int
        public var crossover: String
        public var stock_dxmt: [String]
        public var engines: [String: String]?
        public var archive: Archive
        public var files: [String: String]
    }

    public static func parse(_ data: Data) throws -> Metadata {
        let m = try JSONDecoder().decode(Metadata.self, from: data)
        guard m.format == 1 else { throw VarborError("engines.json format \(m.format) not supported: update VarboR") }
        for p in m.files.keys where !safePath(p) { throw VarborError("engines.json: bad path \(p)") }
        return m
    }

    /// Relative, under lib/, no `..`.
    static func safePath(_ p: String) -> Bool {
        p.hasPrefix("lib/") && !p.split(separator: "/").contains("..") && !p.contains("//")
    }

    /// Why a release doesn't fit the runner, or nil.
    public static func mismatch(_ m: Metadata, _ r: StockRunner) -> String? {
        if m.crossover != r.crossover { return "release is for CrossOver \(m.crossover), runner has \(r.crossover)" }
        guard let d = r.dxmt else { return "can't read the runner's DXMT version" }
        if !m.stock_dxmt.contains(d) { return "release fits DXMT \(m.stock_dxmt.joined(separator: ", ")), runner has \(d)" }
        return nil
    }

    // MARK: state

    public enum Availability: Equatable, Sendable {
        case none(String)
        case available(Metadata)
    }

    public struct RunnerState: Equatable, Sendable {
        public var runner: StockRunner
        /// The clone's marker: tag and archive sha it was built from.
        public var installedTag: String?
        public var installedArchive: String?
        public var tools: [String]
        public var unregistered: [String]
        public var available: Availability?

        public var installed: Bool { installedTag != nil }
        public var updateAvailable: Bool {
            if case .available(let m)? = available { return m.archive.sha256 != installedArchive }
            return false
        }
    }

    static func readMarker(_ dir: URL) -> [String: String] {
        guard let t = try? String(contentsOf: dir.appendingPathComponent(marker), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for l in t.split(separator: "\n") {
            let p = l.split(separator: " ", maxSplits: 1).map(String.init)
            if p.count == 2, !p[0].hasPrefix("file") { out[p[0]] = p[1] }
        }
        return out
    }

    /// Offline: what is installed for each stock runner.
    public static func status(_ ctx: Context) -> [RunnerState] {
        let registry = NotProtonTools.load(notProtonSupport(ctx))
        return stockRunners(ctx).map { r in
            let m = readMarker(cloneDir(ctx, r))
            let tools = plannedTools(ctx, r).map(\.id).filter {
                FileManager.default.fileExists(atPath: toolsDir(ctx).appendingPathComponent("\($0)/\(marker)").path)
            }
            return RunnerState(runner: r, installedTag: m["tag"], installedArchive: m["archive"], tools: tools,
                               unregistered: tools.filter { id in !registry.contains { $0.id == id } }, available: nil)
        }
    }

    /// Network: asks for each runner's release once per tag and fills `available`.
    public static func check(_ ctx: Context, source: EngineSource) async -> [RunnerState] {
        var states = status(ctx)
        var cache: [String: Result<Metadata?, Error>] = [:]
        for i in states.indices {
            let r = states[i].runner
            if cache[r.tag] == nil {
                do { cache[r.tag] = .success(try await source.metadata(tag: r.tag).map(parse)) } catch { cache[r.tag] = .failure(error) }
            }
            switch cache[r.tag]! {
            case .success(nil): states[i].available = .none("no VarboR engines for CrossOver \(r.crossover) yet")
            case .success(let m?): states[i].available = mismatch(m, r).map { .none($0) } ?? .available(m)
            case .failure(let e): states[i].available = .none("\(e)")
            }
        }
        return states
    }

    // MARK: install

    /// Downloads and verifies the release's archive, then builds (or rebuilds) the runner clone and its compat tools.
    @discardableResult
    public static func install(_ ctx: Context, _ r: StockRunner, source: EngineSource) async throws -> URL {
        guard let data = try await source.metadata(tag: r.tag) else { throw VarborError("no VarboR engines release \(r.tag)") }
        let m = try parse(data)
        if let why = mismatch(m, r) { throw VarborError(why) }
        let fm = FileManager.default
        let work = ctx.stateDir.appendingPathComponent("engines/\(r.tag)-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(URL(fileURLWithPath: m.archive.name).lastPathComponent)
        try await source.download(tag: r.tag, asset: m.archive.name, to: archive)
        guard Deploy.sha256(archive) == m.archive.sha256.lowercased() else { throw VarborError("engines: \(m.archive.name) sha256 mismatch") }
        let files = work.appendingPathComponent("files")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let x = run("/usr/bin/tar", ["-xf", archive.path, "-C", files.path])
        guard x.status == 0 else { throw VarborError("engines: unpack failed: \(x.err)") }
        try verify(files, m)
        let dir = try buildClone(ctx, r, files: files, metadata: m)
        try writeTools(ctx, r)
        log("engines: \(r.name) -> \(dir.lastPathComponent) (\(r.tag))")
        return dir
    }

    /// Every unpacked file is listed with its sha, every listed file is there, nothing else (no links).
    static func verify(_ dir: URL, _ m: Metadata) throws {
        var seen = Set<String>()
        let root = dir.resolvingSymlinksInPath().path
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
        while let u = e?.nextObject() as? URL {
            let v = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if v.isDirectory == true { continue }
            let rel = String(u.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            guard v.isSymbolicLink != true, v.isRegularFile == true else { throw VarborError("engines: \(rel) isn't a plain file") }
            guard let want = m.files[rel] else { throw VarborError("engines: \(rel) isn't in engines.json") }
            guard Deploy.sha256(u) == want.lowercased() else { throw VarborError("engines: \(rel) sha256 mismatch") }
            seen.insert(rel)
        }
        if let gone = m.files.keys.sorted().first(where: { !seen.contains($0) }) { throw VarborError("engines: archive lacks \(gone)") }
    }

    /// A fresh APFS clone of the stock runner with the files on top, swapped in for an earlier clone.
    static func buildClone(_ ctx: Context, _ r: StockRunner, files: URL, metadata m: Metadata) throws -> URL {
        let fm = FileManager.default
        let dst = cloneDir(ctx, r)
        if fm.fileExists(atPath: dst.path) && !fm.fileExists(atPath: dst.appendingPathComponent(marker).path) {
            throw VarborError("\(dst.path) exists and isn't VarboR's: left alone")
        }
        let tmp = ctx.runners.appendingPathComponent(".\(dst.lastPathComponent).new")
        try? fm.removeItem(at: tmp)
        let c = run("/bin/cp", ["-c", "-R", r.dir.path, tmp.path])
        guard c.status == 0 else { throw VarborError("engines: clone of \(r.name) failed: \(c.err)") }
        do {
            for rel in m.files.keys.sorted() {
                let to = tmp.appendingPathComponent("CrossOver").appendingPathComponent(rel)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                try fm.copyItem(at: files.appendingPathComponent(rel), to: to)
            }
            var text = "tag \(r.tag)\nbase \(r.build)\narchive \(m.archive.sha256.lowercased())\n"
            if let d = r.dxmt { text += "stock-dxmt \(d)\n" }
            for (rel, sha) in m.files.sorted(by: { $0.key < $1.key }) { text += "file \(rel) \(sha)\n" }
            try text.write(to: tmp.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        let old = ctx.runners.appendingPathComponent(".\(dst.lastPathComponent).old")
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: dst.path) { try fm.moveItem(at: dst, to: old) }
        try fm.moveItem(at: tmp, to: dst)
        try? fm.removeItem(at: old)
        return dst
    }

    // MARK: Steam compat tools

    static func notProtonSupport(_ ctx: Context) -> URL { ctx.runners.deletingLastPathComponent() }
    static func toolsDir(_ ctx: Context) -> URL { ctx.steamRoot.appendingPathComponent("compatibilitytools.d") }

    /// `notproton-fex-41073` -> `notproton-fex-varbor-41073`; `notproton-26.3` -> `notproton-26.3-varbor`.
    public static func toolID(_ stock: String) -> String {
        guard let dash = stock.lastIndex(of: "-"), stock[stock.index(after: dash)...].allSatisfy(\.isNumber) else {
            return stock + suffix
        }
        return stock[..<dash] + suffix + stock[dash...]
    }

    /// One VarboR tool per NotProton tool of the stock build (FEX and Rosetta flavors of one runner).
    public static func plannedTools(_ ctx: Context, _ r: StockRunner) -> [NotProtonTools.Tool] {
        NotProtonTools.load(notProtonSupport(ctx)).filter { $0.build == r.build }.map {
            NotProtonTools.Tool(id: toolID($0.id), build: r.cloneBuild, flavor: $0.flavor, name: $0.name + " - VarboR")
        }
    }

    /// Unmodified copies of NotProton's `run` and toolmanifest.vdf with build/flavor/compatibilitytool.vdf naming the
    /// clone, and a clone of NotProton's per-build bridge data, which its `run` checks for.
    static func writeTools(_ ctx: Context, _ r: StockRunner) throws {
        let fm = FileManager.default
        let stock = NotProtonTools.load(notProtonSupport(ctx)).filter { $0.build == r.build }
        for (s, t) in zip(stock, plannedTools(ctx, r)) {
            let from = toolsDir(ctx).appendingPathComponent(s.id), dir = toolsDir(ctx).appendingPathComponent(t.id)
            guard fm.fileExists(atPath: from.appendingPathComponent("run").path) else { continue }
            if fm.fileExists(atPath: dir.path) && !fm.fileExists(atPath: dir.appendingPathComponent(marker).path) { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in ["run", "toolmanifest.vdf"] {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
                try fm.copyItem(at: from.appendingPathComponent(f), to: dir.appendingPathComponent(f))
            }
            try "\(t.build)\n".write(to: dir.appendingPathComponent("build"), atomically: true, encoding: .utf8)
            try "\(t.flavor)\n".write(to: dir.appendingPathComponent("flavor"), atomically: true, encoding: .utf8)
            // NotProton deletes compatibilitytools.d/notproton-* dirs it doesn't know unless they hold a file it didn't write
            try "varbor compat tool\n".write(to: dir.appendingPathComponent(marker), atomically: true, encoding: .utf8)
            try """
                "compatibilitytools"
                {
                  "compat_tools"
                  {
                    "\(t.id)"
                    {
                      "install_path" "."
                      "display_name" "\(VDF.escape(t.name))"
                      "from_oslist" "windows"
                      "to_oslist" "macos"
                    }
                  }
                }

                """.write(to: dir.appendingPathComponent("compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        }
        let bridge = notProtonSupport(ctx).appendingPathComponent("bridge/wine")
        let from = bridge.appendingPathComponent(r.build), to = bridge.appendingPathComponent(r.cloneBuild)
        if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            let c = run("/bin/cp", ["-c", "-R", from.path, to.path])
            if c.status == 0 { try? "varbor clone of \(r.build)\n".write(to: to.appendingPathComponent(marker), atomically: true, encoding: .utf8) }
        }
    }

    /// Adds the VarboR tools to NotProton's registry so Steam lists them (after a Steam restart). Only on the user's
    /// request; the registry is NotProton's file, backed up once to `state/backup/notproton-tools.orig`.
    public static func register(_ ctx: Context, _ r: StockRunner) throws -> [String] {
        let file = NotProtonTools.file(notProtonSupport(ctx))
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let have = NotProtonTools.parse(text)
        let add = plannedTools(ctx, r).filter { t in
            !have.contains { $0.id == t.id }
                && FileManager.default.fileExists(atPath: toolsDir(ctx).appendingPathComponent("\(t.id)/\(marker)").path)
        }
        guard !add.isEmpty else { return [] }
        let backup = ctx.stateDir.appendingPathComponent("backup/notproton-tools.orig")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: backup)
        }
        let out = (text.isEmpty || text.hasSuffix("\n") ? text : text + "\n") + add.map { $0.line + "\n" }.joined()
        try writeAtomically(Data(out.utf8), to: file)
        log("engines: registered \(add.map(\.id).joined(separator: ", ")) with NotProton")
        return add.map(\.id)
    }
}
