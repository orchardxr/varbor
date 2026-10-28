import Foundation
import WebKit

// Serves the registered web root like SteamVR's web server: static files, plus /fonts/get_font?font=<file>.
// SteamVR's get_font decrypts the Valve-encrypted fonts the games ship; we only serve plain OpenType/TrueType
// files, from ~/Library/Application Support/macvr/fonts first, then <webroot>/fonts. An encrypted file gets a 404
// (the page then falls back to its CSS fallback font).
final class WebrootFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    let drives: [String: String]
    private let userFonts = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/macvr/fonts")
    private var warned = Set<String>()

    init(root: URL, drives: [String: String]) {
        self.root = root.standardizedFileURL
        self.drives = drives
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path.removingPercentEncoding ?? url.path
        var file: URL?
        if path == "/fonts/get_font" {
            let font = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "font" }?.value ?? ""
            file = findFont(font)
        } else {
            let f = root.appendingPathComponent(String(path.drop { $0 == "/" })).standardizedFileURL
            if f.path.hasPrefix(root.path + "/") { file = f }
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            respond(task, url: url, status: 404, type: "text/plain", data: Data())
            if !path.hasPrefix("/dashboard/") { log("404 \(url.absoluteString)") }
            return
        }
        respond(task, url: url, status: 200, type: mimeType(file.pathExtension), data: data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
                       "Cache-Control": "no-cache"]
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    private func findFont(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        for dir in [userFonts, root.appendingPathComponent("fonts")] {
            let f = dir.appendingPathComponent(name)
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            let magic = h.readData(ofLength: 4)
            try? h.close()
            if isFont(magic) { return f }
            if !warned.contains(f.path) {
                warned.insert(f.path)
                log("get_font: \(f.path) is not a plain font (Valve-encrypted); not served")
            }
        }
        return nil
    }

    private func isFont(_ magic: Data) -> Bool {
        let m = [UInt8](magic)
        guard m.count == 4 else { return false }
        return m == [0x4f, 0x54, 0x54, 0x4f] || m == [0, 1, 0, 0] || m == [0x74, 0x72, 0x75, 0x65]
            || m == [0x77, 0x4f, 0x46, 0x46] || m == [0x77, 0x4f, 0x46, 0x32]
    }

    // Windows path from the game (drive letter mapping from OpenComposite) to a unix path.
    func unixPath(_ windowsPath: String) -> String? {
        let p = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard p.count >= 2, p[p.index(after: p.startIndex)] == ":" else { return p.hasPrefix("/") ? p : nil }
        let letter = String(p.prefix(1)).lowercased()
        guard let base = drives[letter] ?? drives[letter.uppercased()] else { return nil }
        return (base as NSString).appendingPathComponent(String(p.dropFirst(2)))
    }

    private func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "otf": return "font/otf"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
