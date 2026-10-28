import Foundation
import MacVRCore

let usage = """
usage: macvr install [--payload <dir>]   deploy the payload, add the runner files, fix prefixes
       macvr status
       macvr rescan [--migrate-legacy]    fix templates and prefixes (--migrate-legacy: remove the hand install now)
       macvr uninstall                    revert prefixes, templates and runner files, stop the server
       macvr server start|stop|status [--record-proof]
       macvr set openvr hklm-env|hkcu-env|vrpath|none
       macvr bottle add|remove <path> | list   CrossOver bottles MacVR sets up (besides NotProton's prefixes)
       macvr library add|remove <path> | list  extra Steam library folders
       macvr protect add|remove <path> | list  trees MacVR never modifies (bottles managed by other tools)
"""

let ctx = Context.real()
Log.shared.open(ctx)
Log.shared.echo = true
let server = Server(ctx: ctx)
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
        guard let payload else { fail("no payload: pass --payload <dir> (build/app/payload) or run from MacVR.app") }
        let rep = try MacVR.install(ctx, payload: payload)
        if !rep.busy.isEmpty { print("busy prefixes are fixed on the next rescan") }
        exit(rep.errors.isEmpty ? 0 : 1)
    case "rescan":
        let rep = MacVR.rescan(ctx, forceLegacy: args.contains("--migrate-legacy"))
        exit(rep.errors.isEmpty ? 0 : 1)
    case "status":
        print(MacVR.statusText(ctx, server: server))
    case "uninstall":
        let rep = MacVR.uninstall(ctx, server: server)
        if !rep.busy.isEmpty { fail("busy (a game or wineserver runs): \(rep.busy.joined(separator: ", ")); run again later") }
        exit(rep.errors.isEmpty ? 0 : 1)
    case "server":
        switch args.dropFirst().first {
        case "start": try server.start(detached: true)
        case "stop": server.stop()
        case "status":
            let st = ServerStatus.read(ctx)
            print("pid: \(server.ourPid.map(String.init) ?? "-"), headset: \(st.headset), games: \(st.gameNames)")
            for pid in st.clientPids.values {
                guard let g = MacVR.probe(ctx, pid: pid) else { continue }
                print("client \(pid): appid \(g.appid ?? "?"), backend \(g.backend ?? "?"), runner bridge \(g.runnerBridge), macvr client \(g.macvrClient)")
                if args.contains("--record-proof") { MacVR.recordProof(ctx, g) }
            }
        default: fail(usage)
        }
    case "set":
        guard args.count == 3, args[1] == "openvr", ["hklm-env", "hkcu-env", "vrpath", "none"].contains(args[2]) else { fail(usage) }
        try ctx.setSetting(args[1], args[2])
        MacVR.refreshRunners(ctx)
        MacVR.rescan(ctx)
    case "bottle", "library":
        let bottle = args[0] == "bottle"
        switch (args.dropFirst().first, args.count) {
        case ("list", 2):
            if bottle {
                for b in ctx.bottles {
                    let st = MacVR.prefixStates(ctx).first { $0.kind == .bottle && $0.path == b.path }
                    print("\(b.path): \(st?.summary ?? "missing")" + (Bottles.backendWarning(b).map { " (\($0))" } ?? ""))
                }
            } else {
                for l in ctx.extraLibraries { print(l.path) }
            }
        case ("add", 3):
            let u = URL(fileURLWithPath: args[2])
            let rep = try bottle ? MacVR.addBottle(ctx, u) : MacVR.addLibrary(ctx, u)
            if bottle, let w = Bottles.backendWarning(u) { print("warning: \(w)") }
            if !rep.busy.isEmpty { print("busy prefixes are fixed on the next rescan") }
            exit(rep.errors.isEmpty ? 0 : 1)
        case ("remove", 3):
            let u = URL(fileURLWithPath: args[2])
            try bottle ? MacVR.removeBottle(ctx, u) : MacVR.removeLibrary(ctx, u)
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
    fail("macvr: \(error)")
}
