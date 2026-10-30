import AppKit
import VarborCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let ctx = Context.real()

    @Published var gameRunning = false
    @Published var setup = "setting up…"
    @Published var prefixes: [Varbor.PrefixState] = []
    @Published var appNames: [String: String] = [:]
    @Published var runnerFiles: [RunnerInstall.FileState] = []
    @Published var bottles: [URL] = []
    @Published var libraries: [URL] = []
    @Published var components: [Components.State] = []
    @Published var engines: [Engines.RunnerState] = []
    @Published var working: String?
    @Published var message: String?
    @Published var update: Updater.Release?
    @Published var updating: String?

    var openMain: (() -> Void)?
    var windowVisible = false
    private var ticks = 0

    private var lastRescan = Date.distantPast
    private var needsRescan = false
    private var timer: Timer?

    private init() {
        Log.shared.open(ctx, fresh: true)
        Task.detached { [ctx] in
            let result: String
            var retry = false
            do {
                let rep = try Varbor.install(ctx, payload: Deploy.bundledPayload())
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
                self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    Task { @MainActor in self.tick() }
                }
                self.tick()
                self.checkForUpdates(quiet: true)
                self.checkEngines()
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
                    guard !quiet || (!gameRunning && UserDefaults.standard.string(forKey: key) != r.version) else { return }
                    UserDefaults.standard.set(r.version, forKey: key)
                    offer(r)
                } else if !quiet {
                    alert("VarboR \(Updater.currentVersion) is the latest version.")
                }
            } catch {
                Log.shared("update: \(error)")
                if !quiet { alert("Couldn't check for updates", "\(error)") }
            }
        }
    }

    func offer(_ r: Updater.Release) {
        let a = NSAlert()
        a.messageText = "VarboR \(r.version) is available"
        a.informativeText = "You have \(Updater.currentVersion). VarboR quits, installs the update and opens again."
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
        updating = "Downloading VarboR \(r.version)…"
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

    func tick() {
        ticks += 1
        if ticks % 4320 == 0 { checkForUpdates(quiet: true) }
        if windowVisible && ticks % 6 == 0 { refreshDetails() }
        let ctx = ctx
        let rescanDue = needsRescan && Date().timeIntervalSince(lastRescan) > 60
        if rescanDue { lastRescan = Date() }
        Task.detached {
            let running = Steam.gameRunning
            var still: Bool?
            if RunnerInstall.needsInstall(ctx) {
                Varbor.refreshRunners(ctx)
                Varbor.rescan(ctx)
            }
            if rescanDue && !running {
                let rep = Varbor.rescan(ctx)
                still = rep.needsRetry
            }
            let s = still
            await MainActor.run {
                self.gameRunning = running
                if let s { self.needsRescan = s; if !s { self.setup = "ready" } }
                if s != nil { self.refreshDetails() }
            }
        }
    }

    /// The one network call for engines besides an install: at launch and from the Runners section.
    func checkEngines() {
        let ctx = ctx
        Task.detached {
            let e = await Engines.check(ctx, source: Engines.defaultSource())
            await MainActor.run { self.engines = e }
        }
    }

    func installEngines(_ r: Engines.StockRunner) {
        guard working == nil else { return }
        if Steam.gameRunning { message = "Quit the game first: the VarboR runner is rebuilt from \(r.name)."; return }
        working = "Installing engines for \(r.name)…"
        message = nil
        let ctx = ctx
        Task.detached {
            var msg: String?
            do {
                try await Engines.install(ctx, r, source: Engines.defaultSource())
                Varbor.refreshRunners(ctx)
                Varbor.rescan(ctx)
            } catch { msg = "\(error)" }
            let m = msg
            await MainActor.run {
                self.message = m
                self.working = nil
                self.checkEngines()
                self.refreshDetails()
            }
        }
    }

    func registerTools(_ st: Engines.RunnerState) {
        let a = NSAlert()
        a.messageText = "Add the VarboR tools to NotProton?"
        a.informativeText = "VarboR adds \(st.unregistered.joined(separator: ", ")) to NotProton's list of compatibility tools "
            + "(a backup of the list is kept). Steam shows them after it restarts; pick one in a game's Compatibility settings."
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform("Registering…") { ctx in
            _ = try Engines.register(ctx, st.runner)
            return nil
        }
    }

    func rescanNow() {
        perform("Rescanning…") { ctx in Varbor.rescan(ctx) }
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
            let p = Varbor.prefixStates(ctx), r = RunnerInstall.fileStates(ctx), b = ctx.bottles, l = ctx.extraLibraries
            let n = ctx.steam.appNames
            let c = Components.all(.real(ctx))
            let e = Engines.status(ctx)
            await MainActor.run {
                self.components = c
                let known = Dictionary(self.engines.map { ($0.runner.name, $0.available) }, uniquingKeysWith: { a, _ in a })
                self.engines = e.map { var s = $0; s.available = known[s.runner.name] ?? nil; return s }
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
        perform("Adding \(url.lastPathComponent)…") { ctx in try Varbor.addBottle(ctx, url) }
    }

    func addLibrary() {
        guard let url = choose("Choose a Steam library folder (the one that contains steamapps)", from: ctx.home) else { return }
        if let why = Bottles.forbidden(ctx, url) { message = why; return }
        perform("Adding \(url.lastPathComponent)…") { ctx in try Varbor.addLibrary(ctx, url) }
    }

    func setExcluded(_ p: Varbor.PrefixState, _ excluded: Bool) {
        let owner = URL(fileURLWithPath: p.path).deletingLastPathComponent()
        perform(excluded ? "Excluding \(appNames[p.name] ?? p.name)…" : "Setting up \(appNames[p.name] ?? p.name)…") { ctx in
            try Varbor.setExcluded(ctx, owner, excluded)
        }
    }

    func removeBottle(_ url: URL) {
        perform("Removing \(url.lastPathComponent)…") { ctx in try Varbor.removeBottle(ctx, url); return nil }
    }

    func removeLibrary(_ url: URL) {
        perform("Removing \(url.lastPathComponent)…") { ctx in try Varbor.removeLibrary(ctx, url); return nil }
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
        a.messageText = "VarboR"
        a.informativeText = """
            Gives Windows VR games under NotProton what Proton gives them on Linux: the OpenVR (vrclient) and
            OpenXR (wineopenxr) bridges, set up in every runner and prefix. WiVRn and OpenComposite are separate apps.

            \(Varbor.backendNote)

            Version \(Updater.currentVersion), payload \(Deploy.currentStamp(ctx) ?? "?"). Logs: \(ctx.logDir.path)
            """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func quit() {
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
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Show VarboR") { model.showWindow() }
        Divider()
        Text("Setup: \(model.setup)")
        Divider()
        Button("Open VarboR Log") { if let u = Log.shared.url { NSWorkspace.shared.open(u) } }
        Button("Rescan Games") { model.rescanNow() }
        Divider()
        if let r = model.update {
            Button("Install VarboR \(r.version)") { model.installUpdate() }.disabled(model.updating != nil)
        }
        Button("Check for Updates…") { model.checkForUpdates(quiet: false) }
        Button("About VarboR") { model.about() }
        Button("Quit VarboR") { model.quit() }.keyboardShortcut("q")
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Self.icon
            .opacity(model.setup == "ready" ? 1 : 0.5)
            .onAppear { model.openMain = { openWindow(id: "main") } }
    }

    static var icon: Image {
        guard let img = NSImage(named: "MenuBarIconTemplate") else { return Image(systemName: "visionpro") }
        img.isTemplate = true
        return Image(nsImage: img)
    }
}

@main
struct VarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("VarboR", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 820, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates(quiet: false) }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit VarboR") { model.quit() }.keyboardShortcut("q")
            }
        }

        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuLabel(model: model)
        }
    }
}
