import Foundation

public enum Wineserver {
    /// Wine's server dir for a prefix: `<tmp>/.wine-<uid>/server-<dev>-<inode>`; a running wineserver holds a lock on
    /// its `lock` file.
    public static func running(prefix: URL) -> Bool {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return false }
        let name = String(format: "server-%llx-%llx", UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        var bases = ["/tmp/.wine-\(getuid())"]
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
            bases.append(String(cString: buf) + ".wine-\(getuid())")
        }
        for base in bases where lockHeld("\(base)/\(name)/lock") { return true }
        return false
    }

    static func lockHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        guard fcntl(fd, F_GETLK, &fl) == 0 else { return false }
        return fl.l_type != Int16(F_UNLCK)
    }
}

/// NotProton's own launch lock (`run` takes it with lockf(1), i.e. flock). Held only for the few ms of an edit.
public final class PrefixLock {
    let fd: Int32

    /// nil when NotProton holds it. A missing lock file means no launch runs; it isn't created. No file: nothing to lock.
    public init?(_ lockFile: URL?) {
        guard let lockFile else { self.fd = -1; return }
        let fd = open(lockFile.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else {
            if errno == ENOENT { self.fd = -1; return }
            return nil
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// One Wine prefix: a NotProton game's `compatdata/<appid>/pfx`, a template's `notproton-template/<runner>/pfx`, or a
/// CrossOver bottle the user added (its record and backups live in MacVR's `state/bottles/<id>`).
public struct WinePrefix {
    public enum Kind: String { case steam, template, bottle }

    public let pfx: URL
    /// compatdata/<appid>, notproton-template/<runner> or state/bottles/<id>
    public let owner: URL
    public let kind: Kind

    public init(pfx: URL, owner: URL, kind: Kind) {
        self.pfx = pfx
        self.owner = owner
        self.kind = kind
    }

    public var isTemplate: Bool { kind == .template }
    public var name: String {
        switch kind {
        case .steam: owner.lastPathComponent
        case .template: "template/\(owner.lastPathComponent)"
        case .bottle: "bottle/\(pfx.lastPathComponent)"
        }
    }
    public var systemReg: URL { pfx.appendingPathComponent("system.reg") }
    public var record: URL { owner.appendingPathComponent("macvr-vr") }
    public var backupDir: URL { owner.appendingPathComponent("macvr-backup") }
    public var lockFile: URL? {
        switch kind {
        case .template: owner.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".notproton-template.lock")
        case .steam: owner.appendingPathComponent(".notproton-prefix.lock")
        case .bottle: nil
        }
    }

    /// Windows profile dirs (steamuser; `crossover` is a symlink to it).
    public var userDirs: [URL] {
        let users = pfx.appendingPathComponent("drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        return names.sorted().compactMap { n in
            let u = users.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard n != "Public", FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) == nil else { return nil }
            return u
        }
    }
}

public struct Record {
    public var values: [String: String]

    public init(values: [String: String] = [:]) { self.values = values }

    public static func load(_ url: URL) -> Record? {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Record(values: KeyValueFile.parse(t))
    }

    public func save(_ url: URL) throws {
        var v = values
        v["version"] = "1"
        try KeyValueFile.write(v, to: url)
    }

    public subscript(_ k: String) -> String? {
        get { values[k] }
        set { values[k] = newValue }
    }
}
