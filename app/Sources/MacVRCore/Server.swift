import Foundation

/// wivrn-server from `current/server`. The app starts it as its own child, so the audio-capture TCC grant goes to
/// MacVR.app (the responsible process).
public final class Server: @unchecked Sendable {
    public let ctx: Context
    private var process: Process?
    private let lock = NSLock()

    public init(ctx: Context) { self.ctx = ctx }

    public static let lowLatencyEnv = [
        "WIVRN_PACER_WINDOW": "500", "WIVRN_PACER_PERCENTILE": "99", "WIVRN_CLIENT_MARGIN_MS": "2.5",
    ]
    static let moltenVK = "/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json"

    public static var tempDir: String {
        var buf = [CChar](repeating: 0, count: 1024)
        return confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
    }

    public static var socketPath: String { tempDir + "wivrn/comp_ipc" }

    /// Any wivrn-server, ours or a dev build (scripts/run-wivrn.sh).
    public static func runningPids() -> [Int32] { Processes.pids(exact: "wivrn-server") }

    public var ourPid: Int32? {
        guard let t = try? String(contentsOf: ctx.serverPidFile, encoding: .utf8),
              let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)), Processes.alive(pid),
              let exe = Processes.executablePath(pid), exe.hasPrefix(ctx.support.resolvingSymlinksInPath().path)
                || exe.hasPrefix(ctx.support.path) else { return nil }
        return pid
    }

    public var isChildRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    public func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "XDG_RUNTIME_DIR"] { env[k] = nil }
        let icd = ctx.current.appendingPathComponent("server/lib/MoltenVK_icd.json").resolvingSymlinksInPath().path
        if FileManager.default.fileExists(atPath: icd) {
            env["VK_DRIVER_FILES"] = icd
        } else if FileManager.default.fileExists(atPath: Self.moltenVK) {
            env["VK_DRIVER_FILES"] = Self.moltenVK
        }
        env["XRT_LOG"] = env["XRT_LOG"] ?? "info"
        for (k, v) in Self.lowLatencyEnv where env[k] == nil { env[k] = v }
        return env
    }

    func rotateLog() throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: ctx.serverLogDir, withIntermediateDirectories: true)
        Log.rotate(ctx.serverLog)
        fm.createFile(atPath: ctx.serverLog.path, contents: nil)
        return try FileHandle(forWritingTo: ctx.serverLog)
    }

    /// Starts the server. `detached`: in its own session, outliving the caller (CLI); otherwise a monitored child.
    public func start(detached: Bool, onExit: (@Sendable (Int32) -> Void)? = nil) throws {
        if let pid = ourPid { throw MacVRError("server already running (pid \(pid))") }
        if let pid = Self.runningPids().first { throw MacVRError("another wivrn-server is running (pid \(pid)), not starting ours") }
        let exe = ctx.serverBinary.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw MacVRError("no server at \(exe.path): run install") }
        let out = try rotateLog()
        defer { try? out.close() }
        let args = ["--no-manage-active-runtime"]
        var pid: Int32
        if detached {
            pid = try spawnDetached(exe.path, args, env: environment(), logFD: out.fileDescriptor)
        } else {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.environment = environment()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                log("server: exited (status \(proc.terminationStatus))")
                onExit?(proc.terminationStatus)
            }
            try p.run()
            lock.lock()
            process = p
            lock.unlock()
            pid = p.processIdentifier
        }
        try FileManager.default.createDirectory(at: ctx.stateDir, withIntermediateDirectories: true)
        try "\(pid)\n".write(to: ctx.serverPidFile, atomically: true, encoding: .utf8)
        log("server: started pid \(pid) (\(exe.path))")
        publishStamp(afterStartOf: pid)
    }

    /// The bridge compares the client's ipc-stamp with `$TMPDIR/wivrn/ipc-stamp`, which must be newer than the server.
    func publishStamp(afterStartOf pid: Int32) {
        let stamp = ctx.serverStamp
        DispatchQueue.global().async {
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: Self.socketPath) { usleep(100_000) }
            sleep(1)
            guard Processes.alive(pid) else { return }
            let dir = URL(fileURLWithPath: Self.tempDir + "wivrn")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try writeAtomically(Data(contentsOf: stamp), to: dir.appendingPathComponent("ipc-stamp"))
                log("server: ipc-stamp published")
            } catch {
                log("server: ipc-stamp: \(error)")
            }
        }
    }

    func spawnDetached(_ path: String, _ args: [String], env: [String: String], logFD: Int32) throws -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, logFD, 1)
        posix_spawn_file_actions_adddup2(&fa, logFD, 2)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        guard r == 0 else { throw MacVRError("posix_spawn: \(String(cString: strerror(r)))") }
        return pid
    }

    /// SIGTERM to our server (pid file), SIGKILL after 5 s.
    public func stop() {
        lock.lock()
        let child = process
        lock.unlock()
        let pid = child?.isRunning == true ? child!.processIdentifier : ourPid
        guard let pid else { return }
        kill(pid, SIGTERM)
        for _ in 0..<50 where Processes.alive(pid) { usleep(100_000) }
        if Processes.alive(pid) { kill(pid, SIGKILL); log("server: killed pid \(pid)") } else { log("server: stopped pid \(pid)") }
        try? FileManager.default.removeItem(at: ctx.serverPidFile)
    }
}

/// What the server log says: headset session and OpenXR clients. WiVRn re-execs itself after a headset session,
/// so a new "starting" line resets everything.
public struct ServerStatus: Equatable {
    public var headset = false
    public var clients: [Int: String] = [:]
    public var clientPids: [Int: Int32] = [:]
    public var lastError: String?
    /// The PIN a new headset must enter while the server accepts pairing.
    public var pin: String?

    public init() {}

    public static func parse(_ text: Substring) -> ServerStatus {
        var s = ServerStatus()
        var pendingClient: Int?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("WiVRn ") && line.contains(" starting") {
                s = ServerStatus()
            } else if line == "Client connected" {
                s.headset = true
            } else if line.contains("Session paused") || line.contains("Waiting for new connection") {
                s.headset = false
            } else if line.contains("[client_connected] Client "), let id = clientId(line) {
                s.clients[id] = "app"
                pendingClient = id
            } else if line.contains("[client_disconnected] Client "), let id = clientId(line) {
                s.clients[id] = nil
                s.clientPids[id] = nil
            } else if let pc = pendingClient, let r = line.range(of: "application_name: '") {
                s.clients[pc] = String(line[r.upperBound...].dropLast())
                if s.clients[pc] == Self.webOverlaysApp {
                    s.clients[pc] = nil
                    pendingClient = nil
                }
            } else if let pc = pendingClient, let r = line.range(of: "pid: ") {
                s.clientPids[pc] = Int32(line[r.upperBound...].prefix { $0.isNumber })
                pendingClient = nil
            } else if let r = line.range(of: "To pair a new headset use PIN code: ") {
                s.pin = String(line[r.upperBound...].prefix { $0.isNumber })
            } else if line == "Headset pairing is disabled" || line == "Encryption is disabled" {
                s.pin = nil
            } else if line.contains(" ERROR ") {
                s.lastError = String(line)
            }
        }
        return s
    }

    static func clientId(_ line: Substring) -> Int? {
        guard let r = line.range(of: "Client ") else { return nil }
        return Int(line[r.upperBound...].prefix { $0.isNumber })
    }

    public static func read(_ ctx: Context) -> ServerStatus {
        guard let d = try? Data(contentsOf: ctx.serverLog) else { return ServerStatus() }
        return parse(Substring(String(decoding: d.suffix(4 << 20), as: UTF8.self)))
    }

    /// The web helper's overlay session ("MacVR web overlays") is ours, not a game.
    public static let webOverlaysApp = "MacVR web overlays"

    public var gameNames: [String] {
        clients.values.filter { $0 != Self.webOverlaysApp }.sorted().map { $0.hasPrefix("OpenComposite_") ? String($0.dropFirst(14)) : $0 }
    }
}
