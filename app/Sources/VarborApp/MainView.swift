import AppKit
import VarborCore
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
                                .help("Install VarboR \(r.version)")
                                .disabled(model.gameRunning)
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
                    Row(title: "VarboR \(r.version) is available",
                        subtitle: [model.updating ?? (model.gameRunning
                            ? "Quit the VR game to install it."
                            : "You have \(Updater.currentVersion). VarboR restarts to install it.")], dot: .blue) {
                        if model.updating != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Release Notes") { NSWorkspace.shared.open(r.page) }
                            Button("Install") { model.installUpdate() }.disabled(model.gameRunning)
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

    var body: some View {
        PageForm(model: model) {
            Section {
                let (color, title, text) = card
                Row(title: title, subtitle: [text], dot: color) {
                    if model.working != nil || model.setup.hasPrefix("setting up") { ProgressView().controlSize(.small) }
                }
            }
            Section {
                ForEach(model.components, id: \.name) { c in ComponentRow(c: c) }
            } header: {
                Text("Components")
            } footer: {
                Text("Separate apps VarboR works with. Each installs and updates itself; VarboR only checks them.")
            }
            Section {
                let groups = Engines.groups(model.ctx, files: model.runnerFiles, states: model.engines)
                if groups.isEmpty { Text("No NotProton runners found.") }
                ForEach(groups) { g in RunnerGroupRows(model: model, g: g) }
            } header: {
                Text("Runners")
            } footer: {
                HStack {
                    Text("The VarboR runner is a copy of a stock runner with VarboR's DXMT and ARM64EC DXVK.")
                    Spacer()
                    Button("Check for Engines") { model.checkEngines() }.disabled(model.working != nil)
                }
            }
            Section {
                let ok = model.prefixes.filter { $0.state == "ok" }.count
                let excluded = model.prefixes.filter { $0.excluded }.count
                Row(title: "\(ok) of \(model.prefixes.count - excluded) set up",
                    subtitle: excluded == 0 ? [] : ["\(excluded) excluded"],
                    dot: ok == model.prefixes.count - excluded ? .green : .orange)
            } header: {
                Text("Prefixes")
            } footer: {
                Text(Varbor.backendNote)
            }
        }
    }

}

func bridgeOK(_ files: [RunnerInstall.FileState]) -> Bool { files.allSatisfy { $0.state == "ok" } }

func bridgeText(_ files: [RunnerInstall.FileState]) -> String {
    "Bridge: \(files.filter { $0.state == "ok" }.count) of \(files.count) files"
}

/// A stock runner, its VarboR runner nested under it, and with `files` each one's bridge files.
struct RunnerGroupRows: View {
    @ObservedObject var model: AppModel
    let g: Engines.RunnerGroup
    var files = false

    var body: some View {
        Row(title: g.name, subtitle: g.bridge.isEmpty ? ["Not found"] : [bridgeText(g.bridge)],
            dot: !g.bridge.isEmpty && bridgeOK(g.bridge) ? .green : .orange) {
            if let st = g.varbor, st.updateAvailable {
                Button(st.installed ? "Update Engines" : "Install Engines") { model.installEngines(st.runner) }
                    .disabled(model.working != nil || model.gameRunning)
            }
            if files { MoreMenu { PathMenu(path: model.ctx.runners.appendingPathComponent(g.name).path) } }
        }
        if files && !g.bridge.isEmpty {
            DisclosureGroup("Bridge files") { ForEach(g.bridge) { BridgeFileRow(f: $0) } }
        }
        if let st = g.varbor {
            EngineRow(model: model, st: st, bridge: g.varborBridge, files: files).padding(.leading, 18)
        } else if !g.varborBridge.isEmpty {
            Row(title: "VarboR runner", subtitle: [bridgeText(g.varborBridge)],
                dot: bridgeOK(g.varborBridge) ? .secondary : .orange).padding(.leading, 18)
        }
        if files && !g.varborBridge.isEmpty {
            DisclosureGroup("VarboR runner bridge files") { ForEach(g.varborBridge) { BridgeFileRow(f: $0) } }
                .padding(.leading, 18)
        }
    }
}

struct BridgeFileRow: View {
    let f: RunnerInstall.FileState

    var body: some View {
        Row(title: f.file, subtitle: [f.path], dot: f.state == "ok" ? .green : .orange) {
            Text(f.state + (f.archs.map { " (\($0))" } ?? "")).foregroundStyle(.secondary)
        }
    }
}

struct EngineRow: View {
    @ObservedObject var model: AppModel
    let st: Engines.RunnerState
    let bridge: [RunnerInstall.FileState]
    var files = false

    var subtitle: [String] {
        var out: [String] = []
        if st.installed {
            out.append("\(Engines.cloneDir(model.ctx, st.runner).lastPathComponent): \(st.installedTag!) revision "
                + "\(st.installedRevision ?? 0), DXMT \(st.installedDXMT ?? "?")")
        } else {
            out.append("Not installed")
        }
        if !st.tools.isEmpty { out.append("Steam tools: \(st.tools.joined(separator: ", "))") }
        if !st.unregistered.isEmpty { out.append("Not in NotProton's tool list yet") }
        if st.installed { out.append(bridgeText(bridge)) }
        if case .available(let m)? = st.available {
            if !st.installed {
                out.append("Engines \(m.tag) revision \(m.revision) available")
            } else if st.updateAvailable {
                out.append("Update available: revision \(m.revision), DXMT \(m.dxmt.version ?? "?")")
            } else {
                out.append("Up to date")
            }
        }
        if case .none(let why)? = st.available { out.append(why) }
        return out
    }

    var body: some View {
        let healthy = st.installed && !st.updateAvailable && st.unregistered.isEmpty && bridgeOK(bridge)
        let dir = Engines.cloneDir(model.ctx, st.runner).path
        Row(title: "VarboR runner", subtitle: subtitle,
            dot: healthy ? .green : st.updateAvailable ? .blue : st.installed ? .orange : .secondary) {
            if !st.unregistered.isEmpty {
                Button("Add to NotProton…") { model.registerTools(st) }.disabled(model.working != nil)
            }
            if files && st.installed { MoreMenu { PathMenu(path: dir) } }
        }
    }
}

struct ComponentRow: View {
    let c: Components.State

    var color: Color {
        switch c.health {
        case .ok: .green
        case .warning: .orange
        case .missing, .outdated: .red
        }
    }

    var body: some View {
        Row(title: c.name + (c.version.map { " \($0)" } ?? ""), subtitle: (c.location.map { [$0] } ?? []) + c.notes, dot: color) {
            switch c.health {
            case .missing: Button("Install…") { NSWorkspace.shared.open(c.page) }
            case .outdated: Button("Update…") { NSWorkspace.shared.open(c.page) }
            default: EmptyView()
            }
            if let l = c.location { MoreMenu { PathMenu(path: l) } }
        }
    }
}

extension Varbor.PrefixState {
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
        if let warning { out.append(warning) }
        return out
    }
}

struct PrefixRow: View {
    let p: Varbor.PrefixState
    let title: String
    var id: String?
    var model: AppModel?

    var body: some View {
        Row(title: title, subtitle: [id.map { "\($0) · \(p.path)" } ?? p.path] + p.issues, dot: p.color) {
            Text(p.userAdded && p.kind != .bottle ? "Added · \(p.label)" : p.label).foregroundStyle(.secondary)
            if let model, p.kind == .steam {
                Toggle("Use VarboR", isOn: Binding(get: { !p.excluded }, set: { model.setExcluded(p, !$0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(p.excluded ? "Excluded: VarboR keeps its VR settings out of this prefix" : "VarboR sets up VR in this prefix")
                    .disabled(model.working != nil || p.busy)
            }
            MoreMenu { PathMenu(path: p.path) }
        }
    }
}

struct PrefixesPage: View {
    @ObservedObject var model: AppModel

    var steam: [Varbor.PrefixState] { model.prefixes.filter { $0.kind == .steam } }
    var templates: [Varbor.PrefixState] { model.prefixes.filter { $0.kind == .template } }

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
                Text("Prefixes NotProton made in your Steam libraries. Turn a game off to keep VarboR's VR settings out of its prefix; the game then runs without Varbor.")
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

    func state(_ bottle: URL) -> Varbor.PrefixState? {
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
                    Text("VarboR finds Steam's libraries and NotProton's prefixes by itself. Add a CrossOver bottle it doesn't know about here.")
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

    var body: some View {
        let groups = Engines.groups(model.ctx, files: model.runnerFiles, states: model.engines)
        PageForm(model: model) {
            if groups.isEmpty {
                Section { Text("No NotProton runners found.") }
            }
            ForEach(groups) { g in
                Section {
                    RunnerGroupRows(model: model, g: g, files: true)
                } header: {
                    if g.id == groups.first?.id { Text("NotProton Runners") }
                } footer: {
                    if g.id == groups.last?.id {
                        HStack {
                            Text("VarboR installs its OpenVR and OpenXR bridges into each runner. The VarboR runner is a copy "
                                + "of a stock runner with VarboR's DXMT and ARM64EC DXVK.")
                            Spacer()
                            Button("Check for Engines") { model.checkEngines() }.disabled(model.working != nil)
                        }
                    }
                }
            }
        }
    }
}

struct LogsPage: View {
    @ObservedObject var model: AppModel

    var logs: [(String, String, URL)] {
        [
            ("VarboR Log", "Setup, rescans and prefix changes", Log.shared.url ?? model.ctx.logDir.appendingPathComponent("varbor.log")),
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
                    Text(model.ctx.logDir.path).textSelection(.enabled)
                    Spacer()
                    Button("Reveal Logs Folder") { NSWorkspace.shared.open(model.ctx.logDir) }
                }
            }
        }
    }
}
