import AppKit
import MacVRCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let ctx = Context.real()
    lazy var server = Server(ctx: ctx)
    lazy var webOverlays = WebOverlays(ctx: ctx)

    @Published var serverState = "starting…"
    @Published var headset = false
    @Published var pin: String?
    @Published var games: [String] = []
    @Published var setup = "setting up…"
    @Published var hint: String?
    @Published var prefixes: [MacVR.PrefixState] = []
    @Published var appNames: [String: String] = [:]
    @Published var runnerFiles: [RunnerInstall.FileState] = []
    @Published var bottles: [URL] = []
    @Published var libraries: [URL] = []
    @Published var working: String?
    @Published var message: String?
    @Published var update: Updater.Release?
    @Published var updating: String?

    var openMain: (() -> Void)?
    var windowVisible = false
    private var ticks = 0

    private var userStopped = false
    private var restarts: [Date] = []
    private var brokerRestarts: [Date] = []
    private var lastRescan = Date.distantPast
    private var needsRescan = false
    private var timer: Timer?

    private init() {
        Log.shared.open(ctx, fresh: true)
        Task.detached { [ctx] in
            let result: String
            var retry = false
            do {
                let rep = try MacVR.install(ctx, payload: Deploy.bundledPayload())
                retry = rep.needsRetry
                result = rep.errors.isEmpty ? (rep.busy.isEmpty ? "ready" : "\(rep.busy.count) prefix(es) in use, fixed later")
                    : "errors, see log"
            } catch {
                Log.shared("setup: \(error)")
                result = "setup failed: \(error)"
            }
            let needs = retry
            await MainActor.run {
                self.setup = result
                self.needsRescan = needs
                self.lastRescan = Date()
                self.refreshDetails()
                if !self.ctx.noServer { self.startServer() }
                self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    Task { @MainActor in self.tick() }
                }
                self.tick()
                self.checkForUpdates(quiet: true)
            }
        }
    }

    /// Quiet (automatic) checks offer each new version once, and not while a game runs.
    func checkForUpdates(quiet: Bool) {
        Task {
            do {
                update = try await Updater.available()
                Log.shared("update: checked, " + (update.map { "\($0.version) available" } ?? "\(Updater.currentVersion) is current"))
                if let r = update {
                    let key = "announcedUpdate"
                    guard !quiet || (games.isEmpty && UserDefaults.standard.string(forKey: key) != r.version) else { return }
                    UserDefaults.standard.set(r.version, forKey: key)
                    offer(r)
                } else if !quiet {
                    alert("MacVR \(Updater.currentVersion) is the latest version.")
                }
            } catch {
                Log.shared("update: \(error)")
                if !quiet { alert("Couldn't check for updates", "\(error)") }
            }
        }
    }

    func offer(_ r: Updater.Release) {
        let a = NSAlert()
        a.messageText = "MacVR \(r.version) is available"
        a.informativeText = "You have \(Updater.currentVersion). MacVR quits, installs the update and opens again."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: installUpdate()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    func alert(_ title: String, _ text: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func installUpdate() {
        guard let r = update, updating == nil else { return }
        let app = Bundle.main.bundleURL
        guard Updater.canReplace(app) else {
            message = "Can't write to \(app.deletingLastPathComponent().path): download the update from GitHub."
            NSWorkspace.shared.open(r.page)
            return
        }
        updating = "Downloading MacVR \(r.version)…"
        Task {
            do {
                let new = try await Updater.download(r)
                Log.shared("update: installing \(r.version) from \(new.path)")
                try Updater.replaceAfterExit(of: getpid(), installed: app, with: new)
                quit()
            } catch {
                Log.shared("update: \(error)")
                alert("Couldn't install the update", "\(error)")
                updating = nil
            }
        }
    }

    func startServer() {
        userStopped = false
        do {
            try server.start(detached: false) { [weak self] status in
                Task { @MainActor in self?.serverExited(status) }
            }
        } catch {
            Log.shared("server: \(error)")
        }
        startWebOverlays()
        tick()
    }

    func startWebOverlays() {
        do {
            try webOverlays.start(environment: server.environment()) { [weak self] _ in
                Task { @MainActor in self?.webOverlaysExited() }
            }
        } catch {
            Log.shared("web overlays: \(error)")
        }
    }

    func webOverlaysExited() {
        guard !userStopped else { return }
        brokerRestarts = brokerRestarts.filter { $0.timeIntervalSinceNow > -300 }
        guard brokerRestarts.count < 3 else {
            Log.shared("web overlays: broker exited 3 times in 5 minutes, not restarting")
            return
        }
        brokerRestarts.append(Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startWebOverlays() }
    }

    func stopServer() {
        userStopped = true
        webOverlays.stop()
        server.stop()
        tick()
    }

    func serverExited(_ status: Int32) {
        tick()
        guard !userStopped else { return }
        restarts = restarts.filter { $0.timeIntervalSinceNow > -300 }
        guard restarts.count < 3 else {
            Log.shared("server: exited 3 times in 5 minutes, not restarting")
            return
        }
        restarts.append(Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startServer() }
    }

    func tick() {
        let ours = server.isChildRunning || server.ourPid != nil
        let other = !ours && !Server.runningPids().isEmpty
        serverState = ours ? "running" : other ? "another wivrn-server is running"
            : ctx.noServer ? "not started (MACVR_NO_SERVER)" : "stopped"
        ticks += 1
        if ticks % 4320 == 0 { checkForUpdates(quiet: true) }
        if windowVisible && ticks % 6 == 0 { refreshDetails() }
        let st = ours ? ServerStatus.read(ctx) : ServerStatus()
        headset = st.headset
        pin = st.pin
        games = st.gameNames
        let ctx = ctx
        let pids = Array(st.clientPids.values)
        let rescanDue = needsRescan && Date().timeIntervalSince(lastRescan) > 60
        if rescanDue { lastRescan = Date() }
        Task.detached {
            var hint: String?
            for pid in pids {
                guard let g = MacVR.probe(ctx, pid: pid) else { continue }
                MacVR.recordProof(ctx, g)
                if let b = g.backend, b != "dxmt", b != "dxvk" {
                    hint = "Game runs with \(b): VR needs DXMT or DXVK"
                }
            }
            var still: Bool?
            if RunnerInstall.needsInstall(ctx) {
                MacVR.refreshRunners(ctx)
                MacVR.rescan(ctx)
            }
            if rescanDue && !Steam.gameRunning {
                let rep = MacVR.rescan(ctx)
                still = rep.needsRetry
            }
            let h = hint, s = still
            await MainActor.run {
                self.hint = h
                if let s { self.needsRescan = s; if !s { self.setup = "ready" } }
                if s != nil { self.refreshDetails() }
            }
        }
    }

    func rescanNow() {
        perform("Rescanning…") { ctx in MacVR.rescan(ctx) }
    }

    func applied(_ rep: Rescan.Report) {
        setup = !rep.errors.isEmpty ? "errors, see log" : rep.busy.isEmpty ? "ready" : "\(rep.busy.count) prefix(es) in use, fixed later"
        needsRescan = rep.needsRetry
        lastRescan = Date()
    }

    /// Runs core work off the main thread; a thrown error is shown in the window.
    func perform(_ what: String, _ work: @escaping @Sendable (Context) throws -> Rescan.Report?) {
        guard working == nil else { return }
        working = what
        message = nil
        let ctx = ctx
        Task.detached {
            var msg: String?
            var rep: Rescan.Report?
            do { rep = try work(ctx) } catch { msg = "\(error)" }
            let r = rep, m = msg
            await MainActor.run {
                if let r { self.applied(r) }
                self.message = m
                self.working = nil
                self.refreshDetails()
            }
        }
    }

    func refreshDetails() {
        let ctx = ctx
        Task.detached {
            let p = MacVR.prefixStates(ctx), r = RunnerInstall.fileStates(ctx), b = ctx.bottles, l = ctx.extraLibraries
            let n = ctx.steam.appNames
            await MainActor.run {
                self.prefixes = p
                self.appNames = n
                self.runnerFiles = r
                self.bottles = b
                self.libraries = l
            }
        }
    }

    func choose(_ title: String, from dir: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = dir
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func addBottle() {
        guard let url = choose("Choose a CrossOver bottle", from: Bottles.defaultDir(ctx)) else { return }
        if let why = Bottles.forbidden(ctx, url) { message = why; return }
        perform("Adding \(url.lastPathComponent)…") { ctx in try MacVR.addBottle(ctx, url) }
    }

    func addLibrary() {
        guard let url = choose("Choose a Steam library folder (the one that contains steamapps)", from: ctx.home) else { return }
        if let why = Bottles.forbidden(ctx, url) { message = why; return }
        perform("Adding \(url.lastPathComponent)…") { ctx in try MacVR.addLibrary(ctx, url) }
    }

    func setExcluded(_ p: MacVR.PrefixState, _ excluded: Bool) {
        let owner = URL(fileURLWithPath: p.path).deletingLastPathComponent()
        perform(excluded ? "Excluding \(appNames[p.name] ?? p.name)…" : "Setting up \(appNames[p.name] ?? p.name)…") { ctx in
            try MacVR.setExcluded(ctx, owner, excluded)
        }
    }

    func removeBottle(_ url: URL) {
        perform("Removing \(url.lastPathComponent)…") { ctx in try MacVR.removeBottle(ctx, url); return nil }
    }

    func removeLibrary(_ url: URL) {
        perform("Removing \(url.lastPathComponent)…") { ctx in try MacVR.removeLibrary(ctx, url); return nil }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMain {
            openMain()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    func about() {
        let a = NSAlert()
        a.messageText = "MacVR"
        a.informativeText = """
            Streams Windows VR games running under NotProton to a Quest with the WiVRn app.

            \(MacVR.backendNote)

            Version \(Deploy.currentStamp(ctx) ?? "?"). Logs: \(ctx.serverLog.path)
            """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func quit() {
        stopServer()
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stopServer() }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Show MacVR") { model.showWindow() }
        Divider()
        Text("Server: \(model.serverState)")
        Text("Headset: \(model.headset ? "connected" : "not connected")")
        if let pin = model.pin { Text("Pairing PIN: \(pin)") }
        Text("Game: \(model.games.isEmpty ? "none" : model.games.joined(separator: ", "))")
        if let hint = model.hint { Text(hint) }
        Text("Setup: \(model.setup)")
        Divider()
        if model.serverState == "running" {
            Button("Stop Server") { model.stopServer() }
        } else {
            Button("Start Server") { model.startServer() }.disabled(model.ctx.noServer)
        }
        Button("Open WiVRn Server Log") { NSWorkspace.shared.open(model.ctx.serverLog) }
        Button("Open Web Overlays Log") { NSWorkspace.shared.open(model.webOverlays.log) }
        Button("Open MacVR Log") { if let u = Log.shared.url { NSWorkspace.shared.open(u) } }
        Button("Rescan Games") { model.rescanNow() }
        Divider()
        if let r = model.update {
            Button("Install MacVR \(r.version)") { model.installUpdate() }.disabled(model.updating != nil)
        }
        Button("Check for Updates…") { model.checkForUpdates(quiet: false) }
        Button("About MacVR") { model.about() }
        Button("Quit MacVR") { model.quit() }.keyboardShortcut("q")
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let pin = model.pin {
            HStack(spacing: 4) {
                Self.icon
                Text(pin).monospacedDigit()
            }
            .onAppear { model.openMain = { openWindow(id: "main") } }
        } else {
            plain
        }
    }

    var plain: some View {
        Self.icon
            .opacity(model.headset ? 1 : 0.5)
            .overlay(alignment: .bottomTrailing) {
                if !model.games.isEmpty { Circle().frame(width: 5, height: 5) }
            }
            .onAppear { model.openMain = { openWindow(id: "main") } }
    }

    static var icon: Image {
        guard let img = NSImage(named: "MenuBarIconTemplate") else { return Image(systemName: "visionpro") }
        img.isTemplate = true
        return Image(nsImage: img)
    }
}

@main
struct MacVRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("MacVR", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 820, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates(quiet: false) }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit MacVR") { model.quit() }.keyboardShortcut("q")
            }
        }

        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuLabel(model: model)
        }
    }
}
