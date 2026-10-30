import Foundation
@testable import VarborCore
import XCTest

/// A release server in a directory: `<tag>/engines.json` and `<tag>/<asset>`.
struct FakeEngineSource: EngineSource {
    let dir: URL

    func metadata(tag: String) async throws -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent("\(tag)/\(Engines.metadataAsset)"))
    }

    func download(tag: String, asset name: String, to: URL) async throws {
        try FileManager.default.copyItem(at: dir.appendingPathComponent("\(tag)/\(name)"), to: to)
    }
}

final class EnginesTests: XCTestCase {
    var root: URL!
    var ctx: Context!
    var source: FakeEngineSource!
    let fm = FileManager.default
    let stockDXMT = "v0.80-279-g8f06be3"
    let tag = "cx-27.0.0.41073"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("varbor-engines-\(UUID().uuidString)")
        let np = root.appendingPathComponent("notproton")
        ctx = Context(home: root, support: root.appendingPathComponent("varbor"), steamRoot: root.appendingPathComponent("Steam"),
                      logDir: root.appendingPathComponent("logs"), runners: np.appendingPathComponent("runners"), system: false)
        source = FakeEngineSource(dir: root.appendingPathComponent("releases"))
        let cx = ctx.runners.appendingPathComponent("crossover-27.0.0.41073-fex/CrossOver")
        try write("\0\0MZ\0v4.0\0\(stockDXMT)\0\0", cx.appendingPathComponent("lib/dxmt/aarch64-windows/d3d11.dll"))
        try write("stock dxgi", cx.appendingPathComponent("lib/dxmt/aarch64-windows/dxgi.dll"))
        try write("ntdll", cx.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"))
        // an older MacVR clone and a runner without DXMT are not stock runners for this
        try write("x", ctx.runners.appendingPathComponent("crossover-27.0.0.41073-fex-macvr/CrossOver/lib/dxmt/x"))
        try fm.createDirectory(at: ctx.runners.appendingPathComponent("crossover-25.0/CrossOver/lib"), withIntermediateDirectories: true)
        try write("notproton-fex-41073\t27.0.0.41073-fex\tfex\tCrossOver - FEX\nnotproton-fex-rosetta-41073\t27.0.0.41073-fex\trosetta\tCrossOver - Rosetta\n",
                  np.appendingPathComponent("tools"))
        for t in ["notproton-fex-41073", "notproton-fex-rosetta-41073"] {
            let d = ctx.steamRoot.appendingPathComponent("compatibilitytools.d/\(t)")
            try write("#!/bin/sh\n", d.appendingPathComponent("run"))
            try write("\"manifest\" {}\n", d.appendingPathComponent("toolmanifest.vdf"))
        }
        try write("bridge", np.appendingPathComponent("bridge/wine/27.0.0.41073-fex/lsteamclient.dll"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Publishes a release: files under lib/, tarred; `tamper` changes the json after hashing.
    func publish(files: [String: String], stock: [String]? = nil, crossover: String = "27.0.0.41073",
                 tamper: ((inout [String: Any]) -> Void)? = nil) throws {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        var shas: [String: String] = [:]
        for (rel, text) in files {
            try write(text, staging.appendingPathComponent(rel))
            shas[rel] = Deploy.sha256(staging.appendingPathComponent(rel))!
        }
        let rel = source.dir.appendingPathComponent(tag)
        try fm.createDirectory(at: rel, withIntermediateDirectories: true)
        let archive = rel.appendingPathComponent("engines.tar.gz")
        try? fm.removeItem(at: archive)
        XCTAssertEqual(VarborCore.run("/usr/bin/tar", ["-czf", archive.path, "-C", staging.path, "lib"]).status, 0)
        var j: [String: Any] = ["format": 1, "crossover": crossover, "stock_dxmt": stock ?? [stockDXMT],
                                "engines": ["dxmt": "v0.80-varbor", "dxvk": "v1.10.3-arm64ec"],
                                "archive": ["name": "engines.tar.gz", "sha256": Deploy.sha256(archive)!], "files": shas]
        tamper?(&j)
        try JSONSerialization.data(withJSONObject: j).write(to: rel.appendingPathComponent(Engines.metadataAsset))
    }

    let releaseFiles = ["lib/dxmt/aarch64-windows/d3d11.dll": "patched d3d11", "lib/dxvk/aarch64-windows/d3d11.dll": "arm64ec dxvk"]

    func testStockRunnerDetection() throws {
        let rs = Engines.stockRunners(ctx)
        XCTAssertEqual(rs.map(\.name), ["crossover-27.0.0.41073-fex"])
        XCTAssertEqual(rs[0].crossover, "27.0.0.41073")
        XCTAssertEqual(rs[0].dxmt, stockDXMT)
        XCTAssertEqual(rs[0].tag, tag)
        XCTAssertEqual(Engines.toolID("notproton-fex-41073"), "notproton-fex-varbor-41073")
        XCTAssertEqual(Engines.toolID("notproton-26.3"), "notproton-26.3-varbor")
    }

    func testCheck() async throws {
        var st = await Engines.check(ctx, source: source)
        guard case .none(let why)? = st[0].available else { return XCTFail("\(st)") }
        XCTAssertTrue(why.contains("no VarboR engines"))
        try publish(files: releaseFiles, stock: ["v0.80-1-g0000000"])
        st = await Engines.check(ctx, source: source)
        guard case .none(let why2)? = st[0].available else { return XCTFail("\(st)") }
        XCTAssertTrue(why2.contains("runner has \(stockDXMT)"))
        try publish(files: releaseFiles)
        st = await Engines.check(ctx, source: source)
        guard case .available(let m)? = st[0].available else { return XCTFail("\(st)") }
        XCTAssertEqual(m.files.count, 2)
        XCTAssertTrue(st[0].updateAvailable)
        XCTAssertFalse(st[0].installed)
    }

    func testInstallBuildsCloneAndTools() async throws {
        try publish(files: releaseFiles)
        let r = Engines.stockRunners(ctx)[0]
        let stockBefore = VarborCore.run("/usr/bin/find", [r.dir.path, "-type", "f"]).out
        let dir = try await Engines.install(ctx, r, source: source)
        XCTAssertEqual(dir.lastPathComponent, "crossover-27.0.0.41073-fex-varbor")
        let cx = dir.appendingPathComponent("CrossOver")
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-windows/d3d11.dll"), encoding: .utf8), "patched d3d11")
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxvk/aarch64-windows/d3d11.dll"), encoding: .utf8), "arm64ec dxvk")
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-windows/dxgi.dll"), encoding: .utf8), "stock dxgi")
        XCTAssertTrue(try String(contentsOf: r.dir.appendingPathComponent("CrossOver/lib/dxmt/aarch64-windows/d3d11.dll"), encoding: .utf8).contains(stockDXMT))
        XCTAssertEqual(VarborCore.run("/usr/bin/find", [r.dir.path, "-type", "f"]).out, stockBefore)
        XCTAssertEqual(Engines.stockRunners(ctx).map(\.name), [r.name])

        let tools = ctx.steamRoot.appendingPathComponent("compatibilitytools.d")
        let fex = tools.appendingPathComponent("notproton-fex-varbor-41073")
        XCTAssertEqual(try String(contentsOf: fex.appendingPathComponent("build"), encoding: .utf8), "27.0.0.41073-fex-varbor\n")
        XCTAssertEqual(try String(contentsOf: fex.appendingPathComponent("flavor"), encoding: .utf8), "fex\n")
        XCTAssertTrue(try String(contentsOf: fex.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8).contains("\"CrossOver - FEX - VarboR\""))
        XCTAssertEqual(try Data(contentsOf: fex.appendingPathComponent("run")), Data("#!/bin/sh\n".utf8))
        XCTAssertEqual(try String(contentsOf: tools.appendingPathComponent("notproton-fex-rosetta-varbor-41073/flavor"), encoding: .utf8), "rosetta\n")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("notproton/bridge/wine/27.0.0.41073-fex-varbor/lsteamclient.dll").path))

        var st = Engines.status(ctx)[0]
        XCTAssertEqual(st.installedTag, tag)
        XCTAssertEqual(st.unregistered, ["notproton-fex-varbor-41073", "notproton-fex-rosetta-varbor-41073"])
        let registryBefore = try Data(contentsOf: root.appendingPathComponent("notproton/tools"))
        XCTAssertEqual(try Engines.register(ctx, r).count, 2)
        XCTAssertEqual(try Engines.register(ctx, r), [])
        XCTAssertEqual(try Data(contentsOf: ctx.stateDir.appendingPathComponent("backup/notproton-tools.orig")), registryBefore)
        st = Engines.status(ctx)[0]
        XCTAssertEqual(st.unregistered, [])
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("notproton/tools"), encoding: .utf8)
            .contains("notproton-fex-varbor-41073\t27.0.0.41073-fex-varbor\tfex\tCrossOver - FEX - VarboR\n"))

        // a new release rebuilds the clone from the stock runner
        try publish(files: ["lib/dxmt/aarch64-windows/d3d11.dll": "patched d3d11 v2"])
        st = await Engines.check(ctx, source: source)[0]
        XCTAssertTrue(st.updateAvailable)
        try await Engines.install(ctx, r, source: source)
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-windows/d3d11.dll"), encoding: .utf8), "patched d3d11 v2")
        XCTAssertFalse(fm.fileExists(atPath: cx.appendingPathComponent("lib/dxvk/aarch64-windows/d3d11.dll").path))
        st = await Engines.check(ctx, source: source)[0]
        XCTAssertFalse(st.updateAvailable)
    }

    func testBadReleasesRefused() async throws {
        let r = Engines.stockRunners(ctx)[0]
        func refused(_ what: String) async {
            do {
                try await Engines.install(ctx, r, source: source)
                XCTFail("\(what) installed")
            } catch {}
            XCTAssertFalse(fm.fileExists(atPath: Engines.cloneDir(ctx, r).path), what)
        }
        try publish(files: releaseFiles) { $0["archive"] = ["name": "engines.tar.gz", "sha256": String(repeating: "0", count: 64)] }
        await refused("archive sha")
        try publish(files: releaseFiles) { j in
            var f = j["files"] as! [String: String]
            f["lib/dxmt/aarch64-windows/d3d11.dll"] = String(repeating: "1", count: 64)
            j["files"] = f
        }
        await refused("file sha")
        try publish(files: releaseFiles) { j in
            var f = j["files"] as! [String: String]
            f.removeValue(forKey: "lib/dxvk/aarch64-windows/d3d11.dll")
            j["files"] = f
        }
        await refused("unlisted file")
        try publish(files: releaseFiles) { j in
            var f = j["files"] as! [String: String]
            f["lib/../../escape"] = String(repeating: "1", count: 64)
            j["files"] = f
        }
        await refused("path outside lib")
        try publish(files: releaseFiles, crossover: "26.3.0.39832")
        await refused("other CrossOver")
        // a dir of that name VarboR didn't make
        try publish(files: releaseFiles)
        try fm.createDirectory(at: Engines.cloneDir(ctx, r), withIntermediateDirectories: true)
        do { try await Engines.install(ctx, r, source: source); XCTFail("foreign dir replaced") } catch {}
        XCTAssertFalse(fm.fileExists(atPath: Engines.cloneDir(ctx, r).appendingPathComponent("CrossOver").path))
    }
}
