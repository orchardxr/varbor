import Foundation

/// The separately installed pieces VarboR needs: NotProton (runners, compat tools), WiVRn for macOS (OpenXR runtime
/// and server) and OpenComposite for macOS (OpenVR runtime). Detection only reads files; VarboR never installs or
/// updates them, each app updates itself.
public enum Components {
    /// Oldest versions VarboR works with. WiVRn: the runtime/server pair the bridge loads; OpenComposite: the
    /// `oc_metal_submit_sync` exports the vrclient bridge's GPU sync needs.
    public static let minimumWiVRn = "0.1.0"
    public static let minimumOpenComposite = "0.1.0"
    public static let openCompositeSyncSymbol = "_oc_metal_submit_sync_begin"

    public static let wivrnPage = URL(string: "https://github.com/orchardxr/wivrn-macos/releases/latest")!
    public static let openCompositePage = URL(string: "https://github.com/orchardxr/opencomposite-macos/releases/latest")!
    public static let notProtonPage = URL(string: "https://github.com/NotProtonNot/NotProton/releases/latest")!

    public enum Health: String, Sendable { case ok, warning, missing, outdated }

    public struct State: Equatable, Sendable {
        public var name: String
        public var health: Health
        public var version: String?
        public var location: String?
        /// What's wrong or worth knowing, one line each.
        public var notes: [String] = []
        public var page: URL
        /// Runner and compat tool names (NotProton only).
        public var items: [String] = []
    }

    /// Where to look. `real` for the user's machine; tests build one on a scratch tree.
    public struct Roots: Sendable {
        public var home: URL
        public var steamRoot: URL
        public var runners: URL
        /// OpenXR manifest dirs after `~/.config/openxr/1` (the loader's order).
        public var systemOpenXR: [URL]
        public var runtimeJSON: String?
        /// Extra WiVRn install trees to try (dirs with share/wivrn/build-info).
        public var wivrnTrees: [URL]
        public var applications: [URL]

        public init(home: URL, steamRoot: URL, runners: URL, systemOpenXR: [URL] = [], runtimeJSON: String? = nil,
                    wivrnTrees: [URL] = [], applications: [URL] = []) {
            self.home = home
            self.steamRoot = steamRoot
            self.runners = runners
            self.systemOpenXR = systemOpenXR
            self.runtimeJSON = runtimeJSON
            self.wivrnTrees = wivrnTrees
            self.applications = applications
        }

        public static func real(_ ctx: Context) -> Roots {
            let env = ProcessInfo.processInfo.environment
            var trees = [URL(fileURLWithPath: "/usr/local"), URL(fileURLWithPath: "/opt/wivrn"),
                         ctx.home.appendingPathComponent("Library/Application Support/wivrn")]
            if let t = env["VARBOR_WIVRN_PREFIX"] { trees.insert(URL(fileURLWithPath: t), at: 0) }
            return Roots(home: ctx.home, steamRoot: ctx.steamRoot, runners: ctx.runners,
                         systemOpenXR: ["/etc/xdg/openxr/1", "/usr/local/share/openxr/1"].map { URL(fileURLWithPath: $0) },
                         runtimeJSON: env["XR_RUNTIME_JSON"], wivrnTrees: trees,
                         applications: [URL(fileURLWithPath: "/Applications"), ctx.home.appendingPathComponent("Applications")])
        }
    }

    public static func all(_ r: Roots) -> [State] { [notProton(r), wivrn(r), openComposite(r)] }

    // MARK: versions

    /// `v0.2.1-3-gabc`, `0.2.1`, `opencomposite-macos 0.2.1` -> [0, 2, 1]; nil when there is no dotted number.
    public static func versionNumbers(_ s: String) -> [Int]? {
        guard let r = s.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return s[r].split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func atLeast(_ version: String, _ minimum: String) -> Bool? {
        guard let v = versionNumbers(version), let m = versionNumbers(minimum) else { return nil }
        for i in 0..<max(v.count, m.count) {
            let a = i < v.count ? v[i] : 0, b = i < m.count ? m[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    static func versionCheck(_ s: inout State, _ version: String?, minimum: String) {
        guard let version else { s.notes.append("version unknown: VarboR needs \(minimum) or newer"); return }
        switch atLeast(version, minimum) {
        case false?:
            s.health = .outdated
            s.notes.append("needs \(minimum) or newer")
        case nil: s.notes.append("version \(version) can't be compared: VarboR needs \(minimum) or newer")
        default: break
        }
    }

    // MARK: NotProton

    public static func notProton(_ r: Roots) -> State {
        let fm = FileManager.default
        let support = r.home.appendingPathComponent("Library/Application Support/notproton")
        var s = State(name: "NotProton", health: .missing, page: notProtonPage)
        let app = r.applications.map { $0.appendingPathComponent("NotProton.app") }.first { fm.fileExists(atPath: $0.path) }
        if let data = try? Data(contentsOf: support.appendingPathComponent("install-build.json")),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            s.version = j["version"] as? String
        }
        if s.version == nil, let app {
            s.version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        }
        let runners = ((try? fm.contentsOfDirectory(atPath: r.runners.path)) ?? []).sorted().filter {
            fm.fileExists(atPath: r.runners.appendingPathComponent("\($0)/CrossOver/lib/wine/x86_64-windows/ntdll.dll").path)
        }
        let tools = NotProtonTools.load(support).map(\.id)
        s.items = runners.map { "runner \($0)" } + tools.map { "tool \($0)" }
        s.location = (app ?? support).path
        if runners.isEmpty {
            s.notes.append(fm.fileExists(atPath: support.path) || app != nil
                ? "no runners yet: open NotProton and let it set up Steam Play" : "not installed")
            return s
        }
        s.health = tools.isEmpty ? .warning : .ok
        if tools.isEmpty { s.notes.append("no compatibility tools registered") }
        s.notes.append("\(runners.count) runner\(runners.count == 1 ? "" : "s"), \(tools.count) tool\(tools.count == 1 ? "" : "s")")
        return s
    }

    // MARK: WiVRn

    public struct WiVRnInstall: Equatable, Sendable {
        public var root: URL
        public var buildInfo: [String: String]
        public var hasIPCStamp: Bool
        public var version: String? { buildInfo["wivrn-macos"] }
    }

    /// An OpenXR manifest's library, resolved against the manifest's dir (symlinks followed).
    static func manifestLibrary(_ json: URL) -> URL? {
        let real = json.resolvingSymlinksInPath()
        guard let d = try? Data(contentsOf: real), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rt = j["runtime"] as? [String: Any], let lib = rt["library_path"] as? String else { return nil }
        let u = lib.hasPrefix("/") ? URL(fileURLWithPath: lib) : real.deletingLastPathComponent().appendingPathComponent(lib)
        return u.standardizedFileURL
    }

    /// The manifest the bridge would use: XR_RUNTIME_JSON, else the first active_runtime.json.
    public static func activeRuntime(_ r: Roots) -> URL? {
        if let e = r.runtimeJSON, FileManager.default.fileExists(atPath: e) { return URL(fileURLWithPath: e) }
        let dirs = [r.home.appendingPathComponent(".config/openxr/1")] + r.systemOpenXR
        return dirs.map { $0.appendingPathComponent("active_runtime.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func wivrnTree(_ root: URL) -> WiVRnInstall? {
        let share = root.appendingPathComponent("share/wivrn")
        guard let t = try? String(contentsOf: share.appendingPathComponent("build-info"), encoding: .utf8),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wivrn/libopenxr_wivrn.dylib").path)
        else { return nil }
        return WiVRnInstall(root: root.standardizedFileURL, buildInfo: KeyValueFile.parse(t),
                            hasIPCStamp: FileManager.default.fileExists(atPath: share.appendingPathComponent("ipc-stamp").path))
    }

    public static func wivrn(_ r: Roots) -> State {
        var s = State(name: "WiVRn", health: .missing, page: wivrnPage)
        let activeLib = activeRuntime(r).flatMap(manifestLibrary)
        // lib/wivrn/libopenxr_wivrn.dylib -> the tree
        let activeTree = activeLib.flatMap { lib -> WiVRnInstall? in
            lib.lastPathComponent == "libopenxr_wivrn.dylib"
                ? wivrnTree(lib.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) : nil
        }
        guard let tree = activeTree ?? r.wivrnTrees.lazy.compactMap(wivrnTree).first else {
            if let activeLib {
                s.health = .warning
                s.location = activeLib.path
                s.notes.append("the active OpenXR runtime isn't WiVRn for macOS")
            } else {
                s.notes.append("not installed")
            }
            return s
        }
        s.health = .ok
        s.location = tree.root.path
        s.version = tree.version
        if let w = tree.buildInfo["wivrn"] { s.notes.append("WiVRn \(w.split(separator: " ").first ?? "")") }
        versionCheck(&s, tree.version, minimum: minimumWiVRn)
        if !tree.hasIPCStamp { s.notes.append("no ipc-stamp: the bridge can't check the runtime against the server") }
        if activeTree == nil {
            if s.health == .ok { s.health = .warning }
            s.notes.append("not the active OpenXR runtime: start its server once from its install")
        }
        return s
    }

    // MARK: OpenComposite

    static func vrpathRuntimes(_ home: URL) -> [String] {
        let f = home.appendingPathComponent("Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath")
        guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (j["runtime"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func contains(_ file: URL, _ needle: String) -> Bool {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return d.range(of: Data(needle.utf8)) != nil
    }

    public static func openComposite(_ r: Roots) -> State {
        var s = State(name: "OpenComposite", health: .missing, page: openCompositePage)
        let fm = FileManager.default
        let dylib = { (dir: String) in URL(fileURLWithPath: dir).appendingPathComponent("bin/osx64/vrclient.dylib") }
        let registered = vrpathRuntimes(r.home)
        // the bridge takes the first runtime with a vrclient.dylib (vrclient/src/macos_unix.cpp)
        guard let rt = registered.first(where: { fm.fileExists(atPath: dylib($0).path) }) else {
            let home = r.home.appendingPathComponent("Library/Application Support/OpenComposite/runtime")
            s.notes.append(fm.fileExists(atPath: dylib(home.path).path)
                ? "installed but not registered in openvrpaths.vrpath: run its install again" : "not installed")
            return s
        }
        s.health = .ok
        s.location = rt
        if let t = try? String(contentsOf: URL(fileURLWithPath: rt).appendingPathComponent("bin/osx64/version.txt"), encoding: .utf8) {
            // "<OpenOVR commit> opencomposite-macos <version>"
            let parts = t.split(whereSeparator: \.isWhitespace).map(String.init)
            s.version = parts.count >= 3 ? parts[2] : parts.last
        }
        if let v = s.version, versionNumbers(v) == nil { s.version = nil }
        versionCheck(&s, s.version, minimum: minimumOpenComposite)
        if !contains(dylib(rt), openCompositeSyncSymbol) {
            s.health = .outdated
            s.notes.append("lacks oc_metal_submit_sync: install a newer OpenComposite for macOS")
        }
        if let first = registered.first, first != rt { s.notes.append("\(first) comes first in openvrpaths.vrpath but has no vrclient.dylib") }
        return s
    }
}

/// NotProton's tool registry (`notproton/tools`): `<id>\t<build>\t<flavor>\t<display name>` per line.
public struct NotProtonTools {
    public struct Tool: Equatable, Sendable {
        public var id: String
        public var build: String
        public var flavor: String
        public var name: String
        public var line: String { "\(id)\t\(build)\t\(flavor)\t\(name)" }
    }

    public static func file(_ support: URL) -> URL { support.appendingPathComponent("tools") }

    public static func parse(_ text: String) -> [Tool] {
        text.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 4 ? Tool(id: f[0], build: f[1], flavor: f[2], name: f[3...].joined(separator: "\t")) : nil
        }
    }

    public static func load(_ support: URL) -> [Tool] {
        (try? String(contentsOf: file(support), encoding: .utf8)).map(parse) ?? []
    }
}
