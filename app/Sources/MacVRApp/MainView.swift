import AppKit
import MacVRCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case status, prefixes, added, runners, logs

    var id: Self { self }

    var title: String {
        switch self {
        case .status: "Status"
        case .prefixes: "Games & Prefixes"
        case .added: "Added by You"
        case .runners: "Runners"
        case .logs: "Logs"
        }
    }

    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .prefixes: "square.stack.3d.up"
        case .added: "folder.badge.plus"
        case .runners: "shippingbox"
        case .logs: "doc.text"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page? = .status

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.icon).badge(badge(p))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .navigationTitle((page ?? .status).title)
                .toolbar {
                    if let r = model.update, model.updating == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Update to \(r.version)", systemImage: "arrow.down.circle") { model.installUpdate() }
                                .help("Install MacVR \(r.version)")
                                .disabled(!model.games.isEmpty)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if model.working != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Rescan Now", systemImage: "arrow.clockwise") { model.rescanNow() }
                                .help("Rescan Now")
                        }
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            model.windowVisible = true
            model.refreshDetails()
        }
        .onDisappear { model.windowVisible = false }
    }

    @ViewBuilder var detail: some View {
        switch page ?? .status {
        case .status: StatusPage(model: model)
        case .prefixes: PrefixesPage(model: model)
        case .added: AddedPage(model: model)
        case .runners: RunnersPage(model: model)
        case .logs: LogsPage(model: model)
        }
    }

    func badge(_ p: Page) -> Int {
        switch p {
        case .prefixes: model.prefixes.filter { $0.kind != .bottle && !["ok", "excluded"].contains($0.state) }.count
        case .added: model.prefixes.filter { $0.kind == .bottle && ($0.state != "ok" || $0.warning != nil) }.count
        case .runners: model.runnerFiles.filter { $0.state != "ok" }.count
        default: 0
        }
    }
}

/// A grouped form with the last action's error on top.
struct PageForm<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            if let m = model.message {
                Section {
                    LabeledContent {
                        Button("Dismiss") { model.message = nil }
                    } label: {
                        Label(m, systemImage: "exclamationmark.triangle.fill").textSelection(.enabled)
                    }
                }
            }
            if let r = model.update {
                Section {
                    Row(title: "MacVR \(r.version) is available",
                        subtitle: [model.updating ?? (model.games.isEmpty
                            ? "You have \(Updater.currentVersion). MacVR restarts to install it."
                            : "Quit the VR game to install it.")], dot: .blue) {
                        if model.updating != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Release Notes") { NSWorkspace.shared.open(r.page) }
                            Button("Install") { model.installUpdate() }.disabled(!model.games.isEmpty)
                        }
                    }
                }
            }
            content
        }
        .formStyle(.grouped)
    }
}

/// Title (with an optional status dot), secondary subtitle lines, trailing controls: a stock grouped-form row.
struct Row<Trailing: View>: View {
    let title: String
    var subtitle: [String] = []
    var dot: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            if let dot {
                Text("\(Text(Image(systemName: "circle.fill")).foregroundStyle(dot)) \(title)")
            } else {
                Text(title)
            }
            ForEach(subtitle, id: \.self) { Text($0).truncationMode(.middle) }
        }
    }
}

extension Row where Trailing == EmptyView {
    init(title: String, subtitle: [String] = [], dot: Color? = nil) {
        self.init(title: title, subtitle: subtitle, dot: dot) { EmptyView() }
    }
}

struct MoreMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { Label("More", systemImage: "ellipsis") }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

struct PathMenu: View {
    let path: String

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

struct StatusPage: View {
    @ObservedObject var model: AppModel

    var card: (Color, String, String) {
        let s = model.setup
        if let w = model.working { return (.blue, "Working", w) }
        if s == "ready" { return (.green, "Ready", "VR setup is complete.") }
        if s.hasPrefix("setting up") { return (.blue, "Setting Up", "Configuring prefixes and runners…") }
        let text = "\(s.prefix(1).uppercased())\(s.dropFirst())."
        return s.contains("in use") ? (.orange, "Waiting", text) : (.red, "Needs Attention", text)
    }

    var running: Bool { model.serverState == "running" }

    var body: some View {
        PageForm(model: model) {
            Section {
                let (color, title, text) = card
                Row(title: title, subtitle: [text], dot: color) {
                    if model.working != nil || model.setup.hasPrefix("setting up") { ProgressView().controlSize(.small) }
                }
            }
            Section("Server") {
                Row(title: "WiVRn Server", subtitle: [model.serverState], dot: running ? .green : .secondary) {
                    if running {
                        Button("Stop") { model.stopServer() }
                    } else {
                        Button("Start") { model.startServer() }.disabled(model.ctx.noServer)
                    }
                }
                Row(title: "Headset", subtitle: [model.headset ? "Connected" : "Not connected"],
                    dot: model.headset ? .green : .secondary)
                if let pin = model.pin {
                    Row(title: "Pairing PIN", subtitle: ["Enter it in the WiVRn app on the headset to pair it with this Mac."],
                        dot: .blue) {
                        Text(pin).font(.title2.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                    }
                }
            }
            Section {
                if model.games.isEmpty {
                    Row(title: "No VR game running", subtitle: ["Start a VR game from Steam."])
                }
                ForEach(model.games, id: \.self) { g in
                    Row(title: g, subtitle: ["Connected to the server"], dot: .green)
                }
                if let hint = model.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                }
            } header: {
                Text("VR Games")
            } footer: {
                Text(MacVR.backendNote)
            }
        }
    }
}

extension MacVR.PrefixState {
    var color: Color {
        switch state {
        case "ok": warning == nil ? .green : .orange
        case "excluded": .secondary
        case "busy": .blue
        default: .orange
        }
    }

    var label: String { busy ? "In use" : state == "ok" ? "OK" : state.capitalized }

    var issues: [String] {
        var out: [String] = []
        if !missing.isEmpty { out.append("Missing: \(missing.joined(separator: ", "))") }
        if legacy { out.append("Legacy install present") }
        if let warning { out.append(warning) }
        return out
    }
}

struct PrefixRow: View {
    let p: MacVR.PrefixState
    let title: String
    var id: String?
    var model: AppModel?

    var body: some View {
        Row(title: title, subtitle: [id.map { "\($0) · \(p.path)" } ?? p.path] + p.issues, dot: p.color) {
            Text(p.userAdded && p.kind != .bottle ? "Added · \(p.label)" : p.label).foregroundStyle(.secondary)
            if let model, p.kind == .steam {
                Toggle("Use MacVR", isOn: Binding(get: { !p.excluded }, set: { model.setExcluded(p, !$0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(p.excluded ? "Excluded: MacVR keeps its VR settings out of this prefix" : "MacVR sets up VR in this prefix")
                    .disabled(model.working != nil || p.busy)
            }
            MoreMenu { PathMenu(path: p.path) }
        }
    }
}

struct PrefixesPage: View {
    @ObservedObject var model: AppModel

    var steam: [MacVR.PrefixState] { model.prefixes.filter { $0.kind == .steam } }
    var templates: [MacVR.PrefixState] { model.prefixes.filter { $0.kind == .template } }

    var body: some View {
        PageForm(model: model) {
            Section {
                if steam.isEmpty { Text("No NotProton game prefixes found yet.") }
                ForEach(steam) { p in
                    PrefixRow(p: p, title: model.appNames[p.name] ?? "App \(p.name)", id: model.appNames[p.name] == nil ? nil : p.name,
                              model: model)
                }
            } header: {
                Text("Steam Games")
            } footer: {
                Text("Prefixes NotProton made in your Steam libraries. Turn a game off to keep MacVR's VR settings out of its prefix; the game then runs without MacVR.")
            }
            Section("NotProton Templates") {
                if templates.isEmpty { Text("No NotProton templates found.") }
                ForEach(templates) { p in
                    PrefixRow(p: p, title: URL(fileURLWithPath: p.path).deletingLastPathComponent().lastPathComponent)
                }
            }
        }
    }
}

struct AddedPage: View {
    @ObservedObject var model: AppModel

    var busy: Bool { model.working != nil }

    func state(_ bottle: URL) -> MacVR.PrefixState? {
        model.prefixes.first {
            $0.kind == .bottle && URL(fileURLWithPath: $0.path).standardizedFileURL.path == bottle.standardizedFileURL.path
        }
    }

    func prefixCount(_ library: URL) -> Int {
        let root = Steam.libraryRoot(library).standardizedFileURL.path + "/"
        return model.prefixes.filter { $0.kind != .bottle && $0.path.hasPrefix(root) }.count
    }

    var body: some View {
        PageForm(model: model) {
            Section {
                if model.bottles.isEmpty {
                    Text("MacVR finds Steam's libraries and NotProton's prefixes by itself. Add a CrossOver bottle it doesn't know about here.")
                }
                ForEach(model.bottles, id: \.self) { b in
                    let st = state(b)
                    Row(title: b.lastPathComponent, subtitle: [b.path] + (st?.issues ?? []), dot: st?.color ?? .secondary) {
                        if let st { Text(st.label).foregroundStyle(.secondary) }
                        MoreMenu {
                            PathMenu(path: b.path)
                            Divider()
                            Button("Remove", role: .destructive) { model.removeBottle(b) }.disabled(busy)
                        }
                    }
                }
            } header: {
                Text("CrossOver Bottles")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add CrossOver Bottle…") { model.addBottle() }.disabled(busy)
                }
            }
            Section {
                if model.libraries.isEmpty {
                    Text("Add a Steam library that isn't in Steam's own list here.")
                }
                ForEach(model.libraries, id: \.self) { l in
                    let n = prefixCount(l)
                    Row(title: l.lastPathComponent, subtitle: [l.path]) {
                        Text(n == 1 ? "1 prefix" : "\(n) prefixes").foregroundStyle(.secondary)
                        MoreMenu {
                            PathMenu(path: l.path)
                            Divider()
                            Button("Remove", role: .destructive) { model.removeLibrary(l) }.disabled(busy)
                        }
                    }
                }
            } header: {
                Text("Steam Libraries")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Steam Library…") { model.addLibrary() }.disabled(busy)
                }
            }
        }
    }
}

struct RunnersPage: View {
    @ObservedObject var model: AppModel

    var runners: [String] {
        var out: [String] = []
        for f in model.runnerFiles where !out.contains(f.runner) { out.append(f.runner) }
        return out
    }

    var body: some View {
        PageForm(model: model) {
            if runners.isEmpty {
                Section { Text("No NotProton runners found.") }
            }
            ForEach(runners, id: \.self) { r in
                let files = model.runnerFiles.filter { $0.runner == r }
                let ok = files.filter { $0.state == "ok" }.count
                let dir = model.ctx.runners.appendingPathComponent(r).path
                Section {
                    Row(title: r, subtitle: ["\(ok) of \(files.count) files ok"], dot: ok == files.count ? .green : .orange) {
                        MoreMenu { PathMenu(path: dir) }
                    }
                    ForEach(files) { f in
                        Row(title: f.file, subtitle: [f.path], dot: f.state == "ok" ? .green : .orange) {
                            Text(f.state + (f.archs.map { " (\($0))" } ?? "")).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    if r == runners.first { Text("NotProton Runners") }
                } footer: {
                    if r == runners.last { Text("MacVR installs its OpenXR bridge into each runner.") }
                }
            }
        }
    }
}

struct LogsPage: View {
    @ObservedObject var model: AppModel

    var logs: [(String, String, URL)] {
        [
            ("MacVR Log", "Setup, rescans and prefix changes", Log.shared.url ?? model.ctx.serverLogDir.appendingPathComponent("macvr.log")),
            ("WiVRn Server Log", "The streaming server", model.ctx.serverLog),
            ("Web Overlays Log", "SteamVR web overlays helper", model.webOverlays.log),
        ]
    }

    var body: some View {
        PageForm(model: model) {
            Section {
                ForEach(logs, id: \.0) { title, what, url in
                    Row(title: title, subtitle: [what]) {
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .disabled(!FileManager.default.fileExists(atPath: url.path))
                        MoreMenu { PathMenu(path: url.path) }
                    }
                }
            } header: {
                Text("Logs")
            } footer: {
                HStack {
                    Text(model.ctx.serverLogDir.path).textSelection(.enabled)
                    Spacer()
                    Button("Reveal Logs Folder") { NSWorkspace.shared.open(model.ctx.serverLogDir) }
                }
            }
        }
    }
}
