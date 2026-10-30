import Foundation

public struct ShellResult {
    public let status: Int32
    public let out: String
    public let err: String
}

@discardableResult
public func run(_ exe: String, _ args: [String], env: [String: String]? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ShellResult(status: -1, out: "", err: "\(error)") }
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    p.waitUntilExit()
    group.wait()
    return ShellResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                       err: String(decoding: errData, as: UTF8.self))
}

public enum Processes {
    public static func pids(exact name: String) -> [Int32] {
        run("/usr/bin/pgrep", ["-x", name]).out.split(separator: "\n").compactMap { Int32($0) }
    }

    public static func pids(matching pattern: String) -> [Int32] {
        run("/usr/bin/pgrep", ["-f", pattern]).out.split(separator: "\n").compactMap { Int32($0) }
    }

    /// Command line plus environment (`ps eww`), for processes of this user.
    public static func commandAndEnv(_ pid: Int32) -> String {
        run("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"]).out
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    public static func alive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
