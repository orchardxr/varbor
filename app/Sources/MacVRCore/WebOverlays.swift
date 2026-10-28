import Foundation

/// SteamVR's web overlay pipeline (docs/web-overlays.md): `macvr-broker` (the mailbox server on 127.0.0.1:27062),
/// which starts `macvr-webhelper` when a game registers a web root. Both live next to the app's executables
/// (Contents/Helpers); the app runs the broker as its child for as long as it runs the server.
public final class WebOverlays: @unchecked Sendable {
    public let ctx: Context
    private var process: Process?
    private let lock = NSLock()

    public init(ctx: Context) { self.ctx = ctx }

    public var log: URL { ctx.serverLogDir.appendingPathComponent("web-overlays.log") }
    public var runtime: URL { ctx.current.appendingPathComponent("server/libopenxr_wivrn.dylib") }

    public static var brokerBinary: URL? {
        let dirs = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"),
                    Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        return dirs.map { $0.appendingPathComponent("macvr-broker") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    public func start(environment: [String: String], onExit: (@Sendable (Int32) -> Void)? = nil) throws {
        guard !isRunning else { return }
        guard let exe = Self.brokerBinary else { throw MacVRError("no macvr-broker next to the app") }
        let fm = FileManager.default
        try fm.createDirectory(at: ctx.serverLogDir, withIntermediateDirectories: true)
        Log.rotate(log)
        fm.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        defer { try? out.close() }
        var env = environment
        env["MACVR_XR_RUNTIME"] = runtime.resolvingSymlinksInPath().path
        let p = Process()
        p.executableURL = exe
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            MacVRCore.log("web overlays: broker exited (status \(proc.terminationStatus))")
            onExit?(proc.terminationStatus)
        }
        try p.run()
        lock.lock()
        process = p
        lock.unlock()
        MacVRCore.log("web overlays: broker started pid \(p.processIdentifier) (\(exe.path))")
    }

    /// SIGTERM; the broker ends its web helper.
    public func stop() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminationHandler = nil
        p.terminate()
        for _ in 0..<30 where p.isRunning { usleep(100_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        MacVRCore.log("web overlays: broker stopped")
    }
}
