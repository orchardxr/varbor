import Foundation

/// Where everything lives. Tests point it at a scratch tree.
public struct Context: Sendable {
    public var home: URL
    public var support: URL
    public var steamRoot: URL
    public var serverLogDir: URL
    public var runners: URL
    /// Run launchctl/Steam/process side effects. Off in tests.
    public var system: Bool
    /// The app doesn't start wivrn-server or the broker (a test instance next to the real app).
    public var noServer = false

    public init(home: URL, support: URL, steamRoot: URL, serverLogDir: URL, runners: URL, system: Bool) {
        self.home = home
        self.runners = runners
        self.support = support
        self.steamRoot = steamRoot
        self.serverLogDir = serverLogDir
        self.system = system
    }

    public static func real() -> Context {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support")
        var ctx = Context(
            home: home,
            support: appSupport.appendingPathComponent("macvr"),
            steamRoot: appSupport.appendingPathComponent("Steam"),
            serverLogDir: home.appendingPathComponent("Library/Logs/MacVR"),
            runners: appSupport.appendingPathComponent("notproton/runners"),
            system: true)
        if let s = env["MACVR_SUPPORT"] { ctx.support = URL(fileURLWithPath: s) }
        if let s = env["MACVR_STEAM_ROOT"] { ctx.steamRoot = URL(fileURLWithPath: s) }
        if let s = env["MACVR_RUNNERS"] { ctx.runners = URL(fileURLWithPath: s) }
        if let s = env["MACVR_LOG_DIR"] { ctx.serverLogDir = URL(fileURLWithPath: s) }
        if env["MACVR_NO_SYSTEM"] == "1" { ctx.system = false }
        if env["MACVR_NO_SERVER"] == "1" { ctx.noServer = true }
        return ctx
    }

    public var versions: URL { support.appendingPathComponent("versions") }
    public var current: URL { support.appendingPathComponent("current") }
    public var previous: URL { support.appendingPathComponent("previous") }
    public var bridgeDir: URL { current.appendingPathComponent("bridge") }
    public var runtimeJSON: URL { bridgeDir.appendingPathComponent("wineopenxr.json") }
    public var openCompositeDir: URL { current.appendingPathComponent("opencomposite") }
    public var openvrConfigDir: URL { support.appendingPathComponent("openvr/config") }
    public var openvrLogDir: URL { support.appendingPathComponent("openvr/logs") }
    public var serverBinary: URL { current.appendingPathComponent("server/wivrn-server") }
    public var serverStamp: URL { current.appendingPathComponent("server/ipc-stamp") }
    public var stateDir: URL { support.appendingPathComponent("state") }
    public var settingsFile: URL { support.appendingPathComponent("settings") }
    public var serverLog: URL { serverLogDir.appendingPathComponent("wivrn-server.log") }
    public var serverPidFile: URL { stateDir.appendingPathComponent("wivrn-server.pid") }

    /// How OpenVR finds OpenComposite (VR_OVERRIDE & co.): `hklm-env` (system.reg Session Manager\Environment),
    /// `hkcu-env` (user.reg Environment), `vrpath` (read-only openvrpaths.vrpath per prefix), `none`.
    public var openvrMode: String { settings["openvr"] ?? "hklm-env" }

    public var settings: [String: String] {
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return [:] }
        return KeyValueFile.parse(text)
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        var s = settings
        s[key] = value
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try KeyValueFile.write(s, to: settingsFile)
    }

    /// A list setting, stored as a JSON array of paths on one line.
    public func pathList(_ key: String) -> [URL] {
        guard let v = settings[key], let a = try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [String] else { return [] }
        return a.map { URL(fileURLWithPath: $0) }
    }

    public func setPathList(_ key: String, _ urls: [URL]) throws {
        if urls.isEmpty { return try setSetting(key, nil) }
        let d = try JSONSerialization.data(withJSONObject: urls.map(\.path), options: [.withoutEscapingSlashes])
        try setSetting(key, String(decoding: d, as: UTF8.self))
    }

    /// CrossOver bottles the user added.
    public var bottles: [URL] { pathList("bottles") }
    /// Trees MacVR must never modify (e.g. bottles another tool manages).
    public var protectedPaths: [URL] { pathList("protected-paths") }
    /// Steam game prefixes (compatdata/<appid>) MacVR keeps free of its settings.
    public var excludedPrefixes: [URL] { pathList("excluded-prefixes") }
    public func isExcluded(_ p: WinePrefix) -> Bool {
        p.kind == .steam && excludedPrefixes.contains { $0.standardizedFileURL.path == p.owner.standardizedFileURL.path }
    }
    /// Steam libraries the user added (besides libraryfolders.vdf).
    public var extraLibraries: [URL] { pathList("steam-libraries") }
    public var steam: Steam { Steam(root: steamRoot, extraLibraries: extraLibraries) }
    /// `wine/x86_64-{windows,unix}` with the bridge, put on a bottle's dll path through its `[Wine] LibPath`.
    public var bottleLib: URL { support.appendingPathComponent("bottle-lib") }
}

/// `Z:\Users\...` for a unix path.
public func dosPath(_ url: URL) -> String {
    "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
}

enum KeyValueFile {
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func write(_ dict: [String: String], to url: URL) throws {
        let text = dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: "\n") + "\n"
        try writeAtomically(Data(text.utf8), to: url)
    }
}

func writeAtomically(_ data: Data, to url: URL, permissions: Int? = nil) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).macvr-tmp")
    try? FileManager.default.removeItem(at: tmp)
    try data.write(to: tmp)
    if let p = permissions {
        try FileManager.default.setAttributes([.posixPermissions: p], ofItemAtPath: tmp.path)
    }
    if rename(tmp.path, url.path) != 0 {
        let err = errno
        try? FileManager.default.removeItem(at: tmp)
        throw MacVRError("rename \(url.path): \(String(cString: strerror(err)))")
    }
}

public struct MacVRError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}
