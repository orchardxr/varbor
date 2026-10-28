import AppKit
import CMacVRXR
import WebKit

private let scheme = "vrwebui"

private func mxrLog(_ line: UnsafePointer<CChar>?) {
    if let line { log("xr: " + String(cString: line)) }
}

// One web overlay: an offscreen page of pixel_size CSS pixels at device scale 1, its scene graph, and an overlay
// session showing the graph's panels.
final class OverlayHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webui: String
    let key: String
    let width: Int
    let height: Int
    var onLoaded: (() -> Void)?

    private let files: WebrootFiles
    private let url: URL
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var xr: OpaquePointer?
    private var panels = [ScenePanel]()
    private var inFlight = Set<Int>()
    private var lastPixels = [Int: Data]()
    private var loaded = false
    private var lastSummary = ""
    private var unchanged = [Int: Int]()
    private var tick = 0
    private var lastStats = mxr_stats()
    private var statsTimer: Timer?
    private var snapshots = 0
    private var snapshotMs = 0.0
    private var changed = 0
    private static var nextHandle = 1
    private let handle: Int

    init(webui: String, key: String, webroot: String, drives: [String: String], url: String, width: Int, height: Int) {
        self.webui = webui
        self.key = key
        self.width = width
        self.height = height
        files = WebrootFiles(root: URL(fileURLWithPath: webroot), drives: drives)
        let host = webui.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let path = url.hasPrefix("/") ? url : "/" + url
        self.url = URL(string: "\(scheme)://\(host)\(path)")!
        handle = OverlayHost.nextHandle
        OverlayHost.nextHandle += 1
        super.init()
    }

    func load() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(files, forURLScheme: scheme)
        let ucc = cfg.userContentController
        ucc.add(self, name: "vrhtml")
        ucc.add(self, name: "console")
        ucc.addUserScript(WKUserScript(source: vrhtmlScript(handle: handle), injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let wv = WKWebView(frame: frame, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        callSPI(wv, "_setOverrideDeviceScaleFactor:", CGFloat(1))
        callSPI(wv, "_setWindowOcclusionDetectionEnabled:", false)
        wv.navigationDelegate = self
        // Offscreen, never shown; occlusion detection is off so WebKit keeps animating it.
        let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.colorSpace = .sRGB
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.contentView = wv
        win.orderFrontRegardless()
        window = win
        webView = wv
        if !noXR {
            xr = mxr_create(runtimePath, UInt32(width), UInt32(height), 1000, mxrLog)
        }
        log("\(key): loading \(url.absoluteString) (\(width)x\(height), webroot \(files.root.path))")
        wv.load(URLRequest(url: url))
        statsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.logStats() }
    }

    func close() {
        timer?.invalidate()
        statsTimer?.invalidate()
        timer = nil
        if let xr { mxr_destroy(xr) }
        xr = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        log("\(key): closed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("\(key): loaded")
        if !loaded {
            loaded = true
            onLoaded?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("\(key): load failed: \(error.localizedDescription)")
        if !loaded { loaded = true; onLoaded?() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("\(key): load failed: \(error.localizedDescription)")
        if !loaded { loaded = true; onLoaded?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("\(key): web content process terminated, reloading")
        webView.reload()
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "console" {
            log("\(key) console: \(message.body)")
            return
        }
        guard let body = message.body as? [String: Any], let sg = body["sg"] as? String else { return }
        updateSceneGraph(sg)
    }

    private func updateSceneGraph(_ text: String) {
        // "null" when the page renders nothing.
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
            log("\(key): bad scene graph")
            return
        }
        let root = parsed as? [String: Any] ?? [:]
        let graph = SceneGraph(root: root, pageWidth: width, pageHeight: height)
        if let dumpDir {
            try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: dumpDir.appendingPathComponent("\(key)-scenegraph.json"))
        }
        panels = graph.panels
        let desc = panels.map { "\($0.debugName) \($0.rect) \(String(format: "%.2fx%.2f", $0.quad.width, $0.quad.height)) a=\(String(format: "%.2f", $0.quad.color_scale.3))" }
        let summary = "\(panels.count) panel(s) \(desc.joined(separator: "; "))"
            + (graph.renderModels.isEmpty ? "" : ", \(graph.renderModels.count) render model(s) (not drawn)")
        if summary != lastSummary {
            lastSummary = summary
            log("\(key): scene graph: \(summary)")
        }
        var quads = panels.map { $0.quad }
        if let xr { mxr_set_quads(xr, &quads, UInt32(quads.count)) }
        let live = Set(panels.map { $0.rectKey })
        lastPixels = lastPixels.filter { live.contains($0.key) }
        unchanged = [:]
        if panels.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / captureHz, repeats: true) { [weak self] _ in self?.capture() }
            capture()
        }
    }

    private func capture() {
        guard let wv = webView else { return }
        tick += 1
        // A panel that hasn't changed for 0.5 s is sampled at a third of the rate until it changes again.
        for p in panels where !inFlight.contains(p.rectKey) && (unchanged[p.rectKey, default: 0] < 15 || tick % 3 == 0) {
            let r = p.rect
            let key = p.rectKey
            inFlight.insert(key)
            let c = WKSnapshotConfiguration()
            c.rect = NSRect(x: r.x, y: r.y, width: r.w, height: r.h)
            c.snapshotWidth = NSNumber(value: r.w)
            c.afterScreenUpdates = false
            let t0 = CACurrentMediaTime()
            wv.takeSnapshot(with: c) { [weak self] image, _ in
                guard let self else { return }
                self.inFlight.remove(key)
                self.snapshots += 1
                self.snapshotMs += (CACurrentMediaTime() - t0) * 1000
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.upload(cg, rect: r, key: key, name: p.debugName)
            }
        }
    }

    private func upload(_ cg: CGImage, rect r: PixelRect, key: Int, name: String) {
        let bpr = r.w * 4
        var data = Data(count: bpr * r.h)
        data.withUnsafeMutableBytes { buf in
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let ctx = CGContext(data: buf.baseAddress, width: r.w, height: r.h, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info) else { return }
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: r.w, height: r.h))
        }
        if lastPixels[key] == data {
            unchanged[key, default: 0] += 1
            return
        }
        unchanged[key] = 0
        lastPixels[key] = data
        changed += 1
        if let xr {
            data.withUnsafeBytes { buf in
                mxr_upload(xr, Int32(r.x), Int32(r.y), Int32(r.w), Int32(r.h), buf.baseAddress, bpr)
            }
        }
        if let dumpDir { dumpPNG(data, r, dumpDir.appendingPathComponent("\(self.key)-\(name)-\(r.x)_\(r.y).png")) }
    }

    private func dumpPNG(_ data: Data, _ r: PixelRect, _ url: URL) {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private func logStats() {
        guard !panels.isEmpty || snapshots > 0 else { return }
        var s = mxr_stats()
        if let xr { mxr_get_stats(xr, &s) }
        let l = lastStats
        lastStats = s
        log(String(format: "%@: 10 s: %d snapshots (avg %.1f ms latency), %d changed; xr frames %llu images %llu, upload %.2f Mpx %.1f ms CPU, copy wait %.1f ms, session %d",
                   key, snapshots, snapshots > 0 ? snapshotMs / Double(snapshots) : 0, changed, s.frames - l.frames,
                   s.images - l.images, Double(s.upload_pixels - l.upload_pixels) / 1e6, s.upload_cpu_ms - l.upload_cpu_ms,
                   s.copy_gpu_wait_ms - l.copy_gpu_wait_ms, s.session_running))
        snapshots = 0
        snapshotMs = 0
        changed = 0
    }
}

private func callSPI<T>(_ obj: NSObject, _ name: String, _ value: T) {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel), let imp = obj.method(for: sel) else {
        log("SPI \(name) missing")
        return
    }
    if let b = value as? Bool {
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: F.self)(obj, sel, b)
    } else if let f = value as? CGFloat {
        typealias F = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(imp, to: F.self)(obj, sel, f)
    }
}

// SteamVR's browser injects window.VRHTML; the pages only render in an overlay (Environment() == 2).
private func vrhtmlScript(handle: Int) -> String {
    """
    (function() {
      const post = (n, m) => { try { window.webkit.messageHandlers[n].postMessage(m); } catch (e) {} };
      for (const level of ['log', 'warn', 'error']) {
        const orig = console[level].bind(console);
        console[level] = (...a) => {
          post('console', level + ': ' + a.map(x => { try { return typeof x === 'string' ? x : JSON.stringify(x); } catch (e) { return String(x); } }).join(' '));
          orig(...a);
        };
      }
      window.addEventListener('error', e => post('console', 'uncaught: ' + e.message + ' @' + e.filename + ':' + e.lineno));
      const unsupported = () => { throw new Error('not available in MacVR'); };
      window.VRHTML = {
        Environment: () => 2,
        UpdateSceneGraph: (sg, retired) => post('vrhtml', { sg: sg, retired: retired || [] }),
        VROverlay: { ThisOverlayHandle: () => \(handle) },
        VRProperties: { GetStringProperty: unsupported },
        VRRenderModelsInternal: { FindComponentForInputSource: unsupported },
        VRRenderModels: { GetComponentStateForDevicePath: unsupported },
        OpenSteamWorkshop: () => {},
      };
    })();
    """
}
