import Foundation
import VarborCore

let usage = """
usage: varbor install [--payload <dir>]   deploy the payload, add the runner files, fix prefixes
       varbor status
       varbor rescan                       fix templates and prefixes
       varbor uninstall                    revert prefixes, templates and runner files
       varbor engines [status|check]       the VarboR runner per stock runner (check asks GitHub)
       varbor engines install|register <runner>   build the VarboR runner from the engines release; add its
                                          compat tools to NotProton's tool list (Steam lists them after a restart)
       varbor bottle add|remove <path> | list   CrossOver bottles VarboR sets up (besides NotProton's prefixes)
       varbor library add|remove <path> | list  extra Steam library folders
       varbor protect add|remove <path> | list  trees VarboR never modifies (bottles managed by other tools)
       varbor exclude add|remove <appid|compatdata dir> | list  Steam game prefixes kept free of VarboR's settings
"""

let ctx = Context.real()
if Migration.macVRRunning(ctx) {
    FileHandle.standardError.write(Data("varbor: \(Migration.macVRRunningNotice)\n".utf8))
    exit(1)
}
Migration.run(ctx)
Log.shared.open(ctx)
Log.shared.echo = true
var args = Array(CommandLine.arguments.dropFirst())

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

do {
    switch args.first {
    case "install":
        let payload = option("--payload").map { URL(fileURLWithPath: $0) } ?? Deploy.bundledPayload()
        guard let payload else { fail("no payload: pass --payload <dir> (build/app/payload) or run from VarboR.app") }
        let rep = try Varbor.install(ctx, payload: payload)
        if !rep.busy.isEmpty { print("busy prefixes are fixed on the next rescan") }
        exit(rep.errors.isEmpty ? 0 : 1)
    case "rescan":
        let rep = Varbor.rescan(ctx)
        exit(rep.errors.isEmpty ? 0 : 1)
    case "status":
        print(Varbor.statusText(ctx))
    case "uninstall":
        let rep = Varbor.uninstall(ctx)
        if !rep.busy.isEmpty { fail("busy (a game or wineserver runs): \(rep.busy.joined(separator: ", ")); run again later") }
        exit(rep.errors.isEmpty ? 0 : 1)
    case "engines":
        func runner(_ name: String) -> Engines.StockRunner {
            guard let r = Engines.stockRunners(ctx).first(where: { $0.name == name || $0.build == name }) else {
                fail("no stock runner \(name): \(Engines.stockRunners(ctx).map(\.name).joined(separator: ", "))")
            }
            return r
        }
        @Sendable func show(_ states: [Engines.RunnerState]) {
            for st in states {
                let r = st.runner
                print("\(r.name): CrossOver \(r.crossover), DXMT \(r.dxmt ?? "?"), release \(r.tag)")
                print("  VarboR runner: " + (st.installed ? "\(Engines.cloneDir(ctx, r).lastPathComponent) (\(st.installedTag!))" : "not installed"))
                if !st.tools.isEmpty { print("  tools: \(st.tools.joined(separator: ", "))" + (st.unregistered.isEmpty ? "" : ", not registered: \(st.unregistered.joined(separator: ", "))")) }
                switch st.available {
                case .available?: print(st.updateAvailable ? "  engines available: install with `varbor engines install \(r.name)`" : "  up to date")
                case .none(let why)?: print("  \(why)")
                case nil: break
                }
            }
        }
        let sem = DispatchSemaphore(value: 0)
        func wait(_ work: @escaping @Sendable () async -> Void) {
            Task { await work(); sem.signal() }
            sem.wait()
        }
        switch (args.dropFirst().first, args.count) {
        case (nil, 1), ("status", 2): show(Engines.status(ctx))
        case ("check", 2): wait { show(await Engines.check(ctx, source: GitHubEngineSource())) }
        case ("install", 3):
            let r = runner(args[2])
            wait {
                do {
                    print("built \(try await Engines.install(ctx, r, source: GitHubEngineSource()).path)")
                    Varbor.refreshRunners(ctx)
                } catch { fail("varbor: \(error)") }
            }
        case ("register", 3):
            let added = try Engines.register(ctx, runner(args[2]))
            print(added.isEmpty ? "nothing to register" : "registered \(added.joined(separator: ", ")); restart Steam to list them")
        default: fail(usage)
        }
    case "bottle", "library":
        let bottle = args[0] == "bottle"
        switch (args.dropFirst().first, args.count) {
        case ("list", 2):
            if bottle {
                for b in ctx.bottles {
                    let st = Varbor.prefixStates(ctx).first { $0.kind == .bottle && $0.path == b.path }
                    print("\(b.path): \(st?.summary ?? "missing")" + (Bottles.backendWarning(b).map { " (\($0))" } ?? ""))
                }
            } else {
                for l in ctx.extraLibraries { print(l.path) }
            }
        case ("add", 3):
            let u = URL(fileURLWithPath: args[2])
            let rep = try bottle ? Varbor.addBottle(ctx, u) : Varbor.addLibrary(ctx, u)
            if bottle, let w = Bottles.backendWarning(u) { print("warning: \(w)") }
            if !rep.busy.isEmpty { print("busy prefixes are fixed on the next rescan") }
            exit(rep.errors.isEmpty ? 0 : 1)
        case ("remove", 3):
            let u = URL(fileURLWithPath: args[2])
            try bottle ? Varbor.removeBottle(ctx, u) : Varbor.removeLibrary(ctx, u)
        default: fail(usage)
        }
    case "exclude":
        func owner(_ a: String) -> URL {
            if a.allSatisfy(\.isNumber), let p = ctx.steam.prefixes.first(where: { $0.kind == .steam && $0.owner.lastPathComponent == a }) {
                return p.owner
            }
            return URL(fileURLWithPath: a)
        }
        switch (args.dropFirst().first, args.count) {
        case ("list", 2):
            for p in ctx.excludedPrefixes { print(p.path) }
        case ("add", 3), ("remove", 3):
            let rep = try Varbor.setExcluded(ctx, owner(args[2]), args[1] == "add")
            print(rep.summary)
        default: fail(usage)
        }
    case "protect":
        switch (args.dropFirst().first, args.count) {
        case ("list", 2):
            for p in ctx.protectedPaths { print(p.path) }
        case ("add", 3):
            let u = URL(fileURLWithPath: args[2]).standardizedFileURL
            try ctx.setPathList("protected-paths", ctx.protectedPaths.filter { $0.path != u.path } + [u])
        case ("remove", 3):
            let u = URL(fileURLWithPath: args[2]).standardizedFileURL
            try ctx.setPathList("protected-paths", ctx.protectedPaths.filter { $0.path != u.path })
        default: fail(usage)
        }
    default:
        fail(usage)
    }
} catch {
    fail("varbor: \(error)")
}
