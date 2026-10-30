import Foundation

/// Self-update from the GitHub releases of the repo: the latest release's .zip holds VarboR.app.
public enum Updater {
    public static let repo = "orchardxr/varbor"
    public static let bundleID = "org.orchardxr.varbor"

    /// The release asset with VarboR.app: `VarboR-<version>.zip`. A release may also carry a MacVR-*.zip for MacVR
    /// installs that still update themselves (docs/varbor-app.md, "From MacVR").
    public static func appAsset(_ names: [String]) -> String? {
        names.first { $0.hasPrefix("VarboR-") && $0.hasSuffix(".zip") }
    }

    public struct Release: Sendable, Equatable {
        public let version: String
        public let zip: URL
        public let page: URL
    }

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    public static func latest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw VarborError("update check: GitHub answered \(code)") }
        let r = try JSONDecoder().decode(APIRelease.self, from: data)
        guard !r.draft, !r.prerelease, let name = appAsset(r.assets.map(\.name)),
              let zip = r.assets.first(where: { $0.name == name }) else { return nil }
        let v = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return Release(version: v, zip: zip.browser_download_url, page: r.html_url)
    }

    public static func available() async throws -> Release? {
        guard let r = try await latest(), isNewer(r.version, than: currentVersion) else { return nil }
        return r
    }

    /// Downloads and unpacks the release; returns the new VarboR.app, checked against the running one.
    public static func download(_ r: Release) async throws -> URL {
        let (file, resp) = try await URLSession.shared.download(from: r.zip)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VarborError("update: download failed") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("varbor-update-\(r.version)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let x = run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path])
        try? fm.removeItem(at: file)
        guard x.status == 0 else { throw VarborError("update: unzip failed: \(x.err)") }
        let app = dir.appendingPathComponent("VarboR.app")
        guard let b = Bundle(url: app), b.bundleIdentifier == bundleID,
              b.infoDictionary?["CFBundleShortVersionString"] as? String == r.version else {
            throw VarborError("update: the release zip has no matching VarboR.app")
        }
        let v = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard v.status == 0 else { throw VarborError("update: signature check failed: \(v.err)") }
        return app
    }

    public static func canReplace(_ installed: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path)
    }

    /// After `pid` exits, swaps `installed` for `new` (restoring it on failure) and opens the result.
    public static func replaceAfterExit(of pid: Int32, installed: URL, with new: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            old="$2.old-update"
            rm -rf "$old"
            if mv "$2" "$old"; then
                if mv "$3" "$2"; then rm -rf "$old"; else mv "$old" "$2"; fi
            fi
            xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", "\(pid)", installed.path, new.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
