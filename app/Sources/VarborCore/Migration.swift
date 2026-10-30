import Foundation

/// MacVR -> VarboR: the support dir, the logs and the per-prefix record/backup names. Only while MacVR isn't running;
/// VarboR never quits or removes MacVR, the user uninstalls it.
public enum Migration {
    /// Moves `~/Library/Application Support/macvr` to `varbor` (one rename) and leaves a `macvr` symlink, so prefixes
    /// a rescan hasn't reached yet (busy ones) still find the bridge. Same for the logs dir, without a link.
    public static func run(_ ctx: Context) {
        let fm = FileManager.default
        if macVRRunning(ctx) { return }
        if let old = ctx.legacySupport, isRealDir(old), !fm.fileExists(atPath: ctx.support.path) {
            if rename(old.path, ctx.support.path) == 0 {
                try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: ctx.support.lastPathComponent)
                log("migration: moved \(old.path) to \(ctx.support.path)")
            } else {
                log("migration: can't move \(old.path): \(String(cString: strerror(errno)))")
            }
        }
        if let old = ctx.legacyLogDir, isRealDir(old), !fm.fileExists(atPath: ctx.logDir.path) {
            try? fm.createDirectory(at: ctx.logDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = rename(old.path, ctx.logDir.path)
        }
    }

    static func isRealDir(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) == nil
            && FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static let macVRBundleID = "org.macvr.MacVR"
    public static let macVRRunningNotice = "Quit MacVR, then reopen VarboR."
    public static let macVRInstalledNotice = "MacVR is still installed. VarboR replaces it: delete MacVR.app, "
        + "or it would undo VarboR's setup when it opens."

    /// MacVR's server and rescans use the old dir and the same prefixes, so VarboR touches nothing while it runs.
    nonisolated(unsafe) static var processRunning: (String) -> Bool = { !Processes.pids(exact: $0).isEmpty }

    public static func macVRRunning(_ ctx: Context) -> Bool {
        ctx.system && processRunning("MacVR")
    }

    /// Installed MacVR.app bundles (the app VarboR replaces), by bundle id.
    public static func macVRApps(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .map { $0.appendingPathComponent("MacVR.app") }
            .filter { Bundle(url: $0)?.bundleIdentifier == macVRBundleID }
    }

    /// `macvr-vr` -> `varbor-vr`, `macvr-backup` -> `varbor-backup` (whichever the new name doesn't have yet).
    static func prefix(_ p: WinePrefix) {
        let fm = FileManager.default
        for (old, new) in [(p.legacyRecord, p.record), (p.legacyBackupDir, p.backupDir)]
        where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            _ = rename(old.path, new.path)
        }
    }
}
