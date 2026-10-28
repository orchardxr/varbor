import Foundation

public struct SteamApp {
    public let appid: String
    public let name: String
    public let library: URL
    public let installDir: URL
}

public struct Steam {
    public let root: URL
    /// Libraries the user added in MacVR, besides the ones Steam lists.
    public let extraLibraries: [URL]

    public init(root: URL, extraLibraries: [URL] = []) {
        self.root = root
        self.extraLibraries = extraLibraries
    }

    /// The libraries in Steam's libraryfolders.vdf (and the root).
    public var steamLibraries: [URL] {
        var out = [root]
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let t = try? String(contentsOf: vdf, encoding: .utf8), let tree = try? VDF.parse(t),
           let folders = tree.child("libraryfolders") {
            for f in folders.children {
                guard let p = f.child("path")?.value else { continue }
                out.append(URL(fileURLWithPath: p))
            }
        }
        return Self.unique(out)
    }

    public var libraries: [URL] { Self.unique(steamLibraries + extraLibraries.map(Self.libraryRoot)) }

    static func unique(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls where !out.contains(where: { $0.standardizedFileURL.path == u.standardizedFileURL.path }) { out.append(u) }
        return out.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("steamapps").path) }
    }

    /// A library folder as the user may pick it: its root, or its `steamapps`.
    public static func libraryRoot(_ u: URL) -> URL {
        u.lastPathComponent.lowercased() == "steamapps" ? u.deletingLastPathComponent() : u
    }

    public var apps: [SteamApp] {
        var out: [SteamApp] = []
        for lib in libraries {
            let sa = lib.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: sa.path)) ?? []
            for f in files.sorted() where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let t = try? String(contentsOf: sa.appendingPathComponent(f), encoding: .utf8),
                      let st = (try? VDF.parse(t))?.child("AppState"),
                      let id = st.child("appid")?.value, let dir = st.child("installdir")?.value else { continue }
                out.append(SteamApp(appid: id, name: st.child("name")?.value ?? id, library: lib,
                                    installDir: sa.appendingPathComponent("common").appendingPathComponent(dir)))
            }
        }
        return out
    }

    /// Installed games' names by appid, from their app manifests.
    public var appNames: [String: String] {
        Dictionary(apps.map { ($0.appid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Prefixes NotProton made, plus its templates.
    public var prefixes: [WinePrefix] {
        var out: [WinePrefix] = []
        let fm = FileManager.default
        for lib in libraries {
            let cd = lib.appendingPathComponent("steamapps/compatdata")
            for n in ((try? fm.contentsOfDirectory(atPath: cd.path)) ?? []).sorted() {
                let owner = cd.appendingPathComponent(n)
                if n == "notproton-template" {
                    for r in ((try? fm.contentsOfDirectory(atPath: owner.path)) ?? []).sorted() {
                        let o = owner.appendingPathComponent(r)
                        let p = WinePrefix(pfx: o.appendingPathComponent("pfx"), owner: o, kind: .template)
                        if fm.fileExists(atPath: p.systemReg.path) { out.append(p) }
                    }
                    continue
                }
                guard n.allSatisfy(\.isNumber) else { continue }
                let p = WinePrefix(pfx: owner.appendingPathComponent("pfx"), owner: owner, kind: .steam)
                if fm.fileExists(atPath: p.systemReg.path) { out.append(p) }
            }
        }
        return out
    }

    static let notVRGames: Set<String> = ["250820", "228980"]

    public var appInfoFile: URL { root.appendingPathComponent("appcache/appinfo.vdf") }

    /// VR games, as Steam's app info declares them (the list the headset gets from the server). Apps missing from
    /// the cache fall back to openvr_api.dll or openxr_loader.dll in the game dir. Unreal's bundled OpenXR plugin
    /// (Engine/Binaries/ThirdParty, Engine/Plugins) ships in many flat games, so it doesn't count.
    public func vrGames() -> [(SteamApp, String)] {
        let apps = self.apps
        let ids = Set(apps.compactMap { UInt32($0.appid) })
        let info = (try? Data(contentsOf: appInfoFile)).flatMap { try? AppInfo.read($0, apps: ids) } ?? [:]
        return apps.compactMap { app in
            if let i = UInt32(app.appid).flatMap({ info[$0] }) {
                return i.isVRGame ? (app, "appinfo \(i.vrFlag!)") : nil
            }
            guard !Self.notVRGames.contains(app.appid), let hit = Self.findVRDLL(app.installDir) else { return nil }
            return (app, hit)
        }
    }

    static func findVRDLL(_ dir: URL, maxDepth: Int = 6) -> String? {
        let dir = dir.resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsPackageDescendants]) else { return nil }
        for case let u as URL in e {
            if e.level > maxDepth { e.skipDescendants(); continue }
            let n = u.lastPathComponent.lowercased()
            if n == "thirdparty" || n == "plugins" && u.deletingLastPathComponent().lastPathComponent.lowercased() == "engine" {
                e.skipDescendants()
                continue
            }
            if n == "openvr_api.dll" || n == "openxr_loader.dll" {
                return String(u.resolvingSymlinksInPath().path.dropFirst(dir.path.count + 1))
            }
        }
        return nil
    }

    public var userConfigs: [URL] {
        let ud = root.appendingPathComponent("userdata")
        return ((try? FileManager.default.contentsOfDirectory(atPath: ud.path)) ?? []).sorted().map {
            ud.appendingPathComponent($0).appendingPathComponent("config/localconfig.vdf")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var isRunning: Bool { !Processes.pids(exact: "steam_osx").isEmpty }

    /// A NotProton game (its `run` or a wineserver) is running.
    public static var gameRunning: Bool {
        !Processes.pids(matching: "compatibilitytools.d/notproton.*/run waitforexitandrun").isEmpty
            || !Processes.pids(matching: "CrossOver/bin/wineserver").isEmpty
    }
}
