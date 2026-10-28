import Foundation

/// Steam launch-option edits. Steam rewrites localconfig.vdf on exit, so these only run while Steam is quit.
public enum SteamConfig {
    static func isLegacyToken(_ t: LaunchOptions.Token) -> Bool {
        t.key == "WINEDLLPATH" && (t.value ?? "").hasSuffix("/drive_c/macvr")
    }

    /// Launch options with the hand install's `WINEDLLPATH=<prefix>/drive_c/macvr`, per user config.
    public static func legacyLaunchOptions(_ steam: Steam) -> [(config: URL, appid: String, options: String)] {
        var out: [(URL, String, String)] = []
        for cfg in steam.userConfigs {
            guard let t = try? String(contentsOf: cfg, encoding: .utf8), let root = try? VDF.parse(t),
                  let apps = root.path(LocalConfig.appsPath) else { continue }
            for app in apps.children {
                if let lo = app.child("LaunchOptions")?.value, LaunchOptions.tokenize(lo).contains(where: isLegacyToken) {
                    out.append((cfg, app.key, lo))
                }
            }
        }
        return out
    }

    public static func withoutLegacy(_ s: String) -> String? {
        let toks = LaunchOptions.tokenize(s).filter { !isLegacyToken($0) }.map(\.raw)
        return toks.isEmpty ? nil : toks.joined(separator: " ")
    }

    /// Drops the legacy WINEDLLPATH token for proven (or forced) games. Returns what is still pending.
    @discardableResult
    public static func migrateLegacy(_ ctx: Context, force: Bool = false) -> [String] {
        let steam = ctx.steam
        var pending: [String] = []
        for (cfg, appid, options) in legacyLaunchOptions(steam) {
            let proven = FileManager.default.fileExists(atPath: Rescan.provenFile(ctx, appid).path)
            guard force || proven else { pending.append(appid); continue }
            if ctx.system && Steam.isRunning { pending.append(appid); continue }
            do {
                let text = try String(contentsOf: cfg, encoding: .utf8)
                let out = try LocalConfig.setLaunchOptions(text, appid: appid, to: withoutLegacy(options))
                let bdir = ctx.stateDir.appendingPathComponent("backup")
                try FileManager.default.createDirectory(at: bdir, withIntermediateDirectories: true)
                let user = cfg.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                try? FileManager.default.removeItem(at: bdir.appendingPathComponent("localconfig-\(user).vdf"))
                try FileManager.default.copyItem(at: cfg, to: bdir.appendingPathComponent("localconfig-\(user).vdf"))
                try writeAtomically(Data(out.utf8), to: cfg)
                log("steam: \(appid): removed the legacy WINEDLLPATH launch option (was: \(options))")
            } catch {
                log("steam: \(appid): \(error)")
                pending.append(appid)
            }
        }
        return pending
    }
}
