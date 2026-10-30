import Foundation
import VarborCore

let usage = """
usage: varbor install [--payload <dir>]   deploy the payload, add the runner files, fix prefixes
       varbor status
       varbor rescan                       fix templates and prefixes
       varbor uninstall                    revert prefixes, templates and runner files
       varbor bottle add|remove <path> | list   CrossOver bottles VarboR sets up (besides NotProton's prefixes)
       varbor library add|remove <path> | list  extra Steam library folders
       varbor protect add|remove <path> | list  trees VarboR never modifies (bottles managed by other tools)
       varbor exclude add|remove <appid|compatdata dir> | list  Steam game prefixes kept free of VarboR's settings
"""

let ctx = Context.real()
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
