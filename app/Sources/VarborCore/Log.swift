import Foundation

public final class Log: @unchecked Sendable {
    public static let shared = Log()
    private let lock = NSLock()
    private var file: URL?
    public var echo = false
    public var sink: ((String) -> Void)?

    /// `fresh`: start a new log (the app at launch); earlier runs are kept by `rotate`.
    public func open(_ ctx: Context, fresh: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(at: ctx.logDir, withIntermediateDirectories: true)
        let url = ctx.logDir.appendingPathComponent("varbor.log")
        let legacy = ctx.support.appendingPathComponent("logs")
        if fm.fileExists(atPath: legacy.path) {
            if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: legacy.appendingPathComponent("varbor.log"), to: url) }
            try? fm.removeItem(at: legacy)
        }
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 0 && (fresh || size > 1 << 20) { Self.rotate(url) }
        lock.lock()
        file = url
        lock.unlock()
    }

    /// `name.log` -> `name.1.log` -> ... -> `name.<keep-1>.log`: at most `keep` files, newest first.
    public static func rotate(_ url: URL, keep: Int = 10) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        func n(_ i: Int) -> URL { dir.appendingPathComponent("\(base).\(i).log") }
        try? fm.removeItem(at: n(keep - 1))
        for i in stride(from: keep - 2, through: 1, by: -1) where fm.fileExists(atPath: n(i).path) {
            try? fm.moveItem(at: n(i), to: n(i + 1))
        }
        if fm.fileExists(atPath: url.path) { try? fm.moveItem(at: url, to: n(1)) }
    }

    public var url: URL? { lock.lock(); defer { lock.unlock() }; return file }

    public func callAsFunction(_ msg: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let line = "\(f.string(from: Date())) \(msg)\n"
        lock.lock()
        defer { lock.unlock() }
        if echo { FileHandle.standardOutput.write(Data((msg + "\n").utf8)) }
        sink?(msg)
        guard let file else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}

let log = Log.shared
