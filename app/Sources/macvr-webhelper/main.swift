// vrwebhelper role: renders the web overlays a game registered (RegisterExternalWebRoot → broker → create_overlays)
// in offscreen WKWebViews, with SteamVR's `window.VRHTML` injected, and shows their scene graph through the
// overlay compositor (CMacVRXR). Started by macvr-broker; exits when its last overlay is destroyed or the broker
// goes away.
import AppKit
import CMacVRXR
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let env = ProcessInfo.processInfo.environment
var port = 27062
if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count {
    port = Int(CommandLine.arguments[i + 1]) ?? port
}
let captureHz = Double(env["MACVR_WEB_FPS"] ?? "") ?? 30
let dumpDir = env["MACVR_WEB_DUMP"].map { URL(fileURLWithPath: $0) }
let runtimePath = env["MACVR_XR_RUNTIME"]
    ?? (NSHomeDirectory() + "/Library/Application Support/macvr/current/server/libopenxr_wivrn.dylib")
let noXR = env["MACVR_WEB_NO_XR"] == "1"

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    print("\(f.string(from: Date())) [webhelper] \(s)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// No App Nap: a windowless background helper would get its timers throttled.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                     reason: "VR overlays")

let mailbox = MailboxClient(port: port, name: "vrwebhelper/main")
var webuis = [String: [OverlayHost]]()

func json(_ obj: [String: Any]) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return String(decoding: d, as: UTF8.self)
}

func destroyWebui(_ name: String) {
    guard let hosts = webuis.removeValue(forKey: name) else { return }
    log("destroy_overlays \(name)")
    for h in hosts { h.close() }
    if webuis.isEmpty {
        log("no overlays left, exiting")
        exit(0)
    }
}

mailbox.onMessage = { obj in
    guard let type = obj["type"] as? String else { return }
    switch type {
    case "create_overlays":
        guard let name = obj["name"] as? String, let root = obj["unix_path"] as? String,
              let overlays = obj["overlays"] as? [[String: Any]] else { return }
        destroyWebuiKeepAlive(name)
        let drives = obj["drives"] as? [String: String] ?? [:]
        var hosts = [OverlayHost]()
        var remaining = 0
        for o in overlays {
            let type = o["type"] as? String ?? "overlay"
            guard type == "overlay", let url = o["url"] as? String else {
                log("skipping overlay \(o["name"] ?? "?") of type \(type)")
                continue
            }
            let size = (o["pixel_size"] as? [Int]) ?? [1024, 1024]
            let h = OverlayHost(webui: name, key: o["name"] as? String ?? "overlay", webroot: root, drives: drives,
                                url: url, width: size[0], height: size.count > 1 ? size[1] : size[0])
            remaining += 1
            h.onLoaded = {
                remaining -= 1
                if remaining == 0 {
                    mailbox.send(to: "web_server_mailbox", json(["type": "overlays_loaded", "name": name]))
                }
            }
            hosts.append(h)
        }
        webuis[name] = hosts
        log("create_overlays \(name): \(hosts.map { $0.key }) from \(root)")
        for h in hosts { h.load() }
        if hosts.isEmpty { mailbox.send(to: "web_server_mailbox", json(["type": "overlays_loaded", "name": name])) }
    case "destroy_overlays":
        if let name = obj["name"] as? String { destroyWebui(name) }
    default:
        log("vrwebhelper/main: unhandled \(type)")
    }
}

func destroyWebuiKeepAlive(_ name: String) {
    guard let hosts = webuis.removeValue(forKey: name) else { return }
    for h in hosts { h.close() }
}

mailbox.onClose = {
    log("lost the broker, exiting")
    exit(0)
}
mailbox.connect()
app.run()
