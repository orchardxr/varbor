import Foundation
@testable import VarborCore
import XCTest

final class EnginesTests: XCTestCase {
    var root: URL!
    var ctx: Context!
    var source: LocalEngineSource!
    let fm = FileManager.default
    let stockDXMT = "v0.80-279-g8f06be3"
    let tag = "cx-27.0.0.41073"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("varbor-engines-\(UUID().uuidString)")
        let np = root.appendingPathComponent("notproton")
        ctx = Context(home: root, support: root.appendingPathComponent("varbor"), steamRoot: root.appendingPathComponent("Steam"),
                      logDir: root.appendingPathComponent("logs"), runners: np.appendingPathComponent("runners"), system: false)
        source = LocalEngineSource(root.appendingPathComponent("releases"))
        let cx = ctx.runners.appendingPathComponent("crossover-27.0.0.41073-fex/CrossOver")
        try write("\0\0MZ\0v4.0\0\(stockDXMT)\0\0", cx.appendingPathComponent("lib/dxmt/aarch64-windows/d3d11.dll"))
        try write("stock dxgi", cx.appendingPathComponent("lib/dxmt/aarch64-windows/dxgi.dll"))
        try write("ntdll", cx.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"))
        // a marked clone of ours and a runner without DXMT are not stock runners
        try write("x", ctx.runners.appendingPathComponent("crossover-27.0.0.41073-fex-copy/CrossOver/lib/dxmt/x"))
        try write("tag cx-27.0.0.41073\n", ctx.runners.appendingPathComponent("crossover-27.0.0.41073-fex-copy/.varbor"))
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

    /// Publishes a release the way varbor-engines' scripts/package.sh does, into releases/<tag>/ (or `into`):
    /// metadata.json, varbor-engines-<tag>.tar.gz (varbor-engines-<tag>/{dxmt,dxvk,licenses}, metadata.json), SHA256SUMS.
    /// `files` are paths under CrossOver/lib; `tamper` edits the metadata after hashing; `sums` overrides the tarball sha.
    func publish(files: [String: String], stock: String? = nil, crossover: String = "27.0.0.41073", revision: Int = 1,
                 into: URL? = nil, sums: String? = nil, extra: [String: String] = [:],
                 tamper: ((inout [String: Any]) -> Void)? = nil) throws {
        let name = "varbor-engines-\(tag)"
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        let top = staging.appendingPathComponent(name)
        var dxmt: [String: String] = [:], dxvk: [String: String] = [:]
        for (rel, text) in files {
            try write(text, top.appendingPathComponent(rel))
            let sha = Deploy.sha256(top.appendingPathComponent(rel))!
            if rel.hasPrefix("dxmt/") { dxmt[rel] = sha } else { dxvk[rel] = sha }
        }
        for (rel, text) in extra { try write(text, top.appendingPathComponent(rel)) }
        try write("LGPL", top.appendingPathComponent("licenses/DXMT-LICENSE"))
        let dxmtEntry: [String: Any] = ["version": "v0.80-247-gfb451568-varbor.\(revision)", "stock_version": stock ?? stockDXMT,
                                        "files": dxmt]
        let dxvkEntry: [String: Any] = dxvk.isEmpty
            ? ["stock_version": "cxaddon-1.10.3-1-25-g737aacd", "note": "not built"]
            : ["version": "cxaddon-1.10.3-1-25-g737aacd-varbor.1", "stock_version": "cxaddon-1.10.3-1-25-g737aacd", "files": dxvk]
        let cx: [String: Any] = ["version": crossover, "public_version": "20261015"]
        var j: [String: Any] = [:]
        j["schema"] = 1
        j["id"] = crossover
        j["tag"] = tag
        j["revision"] = revision
        j["crossover"] = cx
        j["dxmt"] = dxmtEntry
        j["dxvk"] = dxvkEntry
        j["source"] = "\(name)-src.tar.gz"
        tamper?(&j)
        let meta = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])
        try meta.write(to: top.appendingPathComponent("metadata.json"))
        let rel = into ?? source.dir.appendingPathComponent(tag)
        try fm.createDirectory(at: rel, withIntermediateDirectories: true)
        let archive = rel.appendingPathComponent("\(name).tar.gz")
        try? fm.removeItem(at: archive)
        XCTAssertEqual(VarborCore.run("/usr/bin/tar", ["-czf", archive.path, "-C", staging.path, name]).status, 0)
        try meta.write(to: rel.appendingPathComponent(Engines.metadataAsset))
        try write("\(sums ?? Deploy.sha256(archive)!)  \(name).tar.gz\n0000  \(name)-src.tar.gz\n",
                  rel.appendingPathComponent(Engines.checksumsAsset))
    }

    let releaseFiles = ["dxmt/aarch64-windows/d3d11.dll": "patched d3d11", "dxmt/aarch64-unix/winemetal.so": "patched winemetal",
                        "dxvk/aarch64-windows/d3d11.dll": "arm64ec dxvk"]

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
        try publish(files: releaseFiles, stock: "v0.80-1-g0000000")
        st = await Engines.check(ctx, source: source)
        guard case .none(let why2)? = st[0].available else { return XCTFail("\(st)") }
        XCTAssertTrue(why2.contains("runner has \(stockDXMT)"))
        try publish(files: releaseFiles)
        st = await Engines.check(ctx, source: source)
        guard case .available(let m)? = st[0].available else { return XCTFail("\(st)") }
        XCTAssertEqual(m.files.count, 3)
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
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-unix/winemetal.so"), encoding: .utf8), "patched winemetal")
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-windows/dxgi.dll"), encoding: .utf8), "stock dxgi")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("varbor-engines-licenses/DXMT-LICENSE").path))
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
        XCTAssertEqual(st.installedRevision, 1)
        XCTAssertEqual(st.installedDXMT, "v0.80-247-gfb451568-varbor.1")
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
        try publish(files: ["dxmt/aarch64-windows/d3d11.dll": "patched d3d11 v2"], revision: 2)
        st = await Engines.check(ctx, source: source)[0]
        XCTAssertTrue(st.updateAvailable)
        try await Engines.install(ctx, r, source: source)
        XCTAssertEqual(try String(contentsOf: cx.appendingPathComponent("lib/dxmt/aarch64-windows/d3d11.dll"), encoding: .utf8), "patched d3d11 v2")
        XCTAssertFalse(fm.fileExists(atPath: cx.appendingPathComponent("lib/dxvk/aarch64-windows/d3d11.dll").path))
        st = await Engines.check(ctx, source: source)[0]
        XCTAssertFalse(st.updateAvailable)
    }

    func testFlatDistDirectory() async throws {
        // varbor-engines' dist/ for one build: the assets side by side
        let dist = root.appendingPathComponent("dist")
        try publish(files: releaseFiles, into: dist)
        let local = LocalEngineSource(dist)
        let found = try await local.metadata(tag: tag)
        let other = try await local.metadata(tag: "cx-26.3.0.39832")
        XCTAssertNotNil(found)
        XCTAssertNil(other)
        let dir = try await Engines.install(ctx, Engines.stockRunners(ctx)[0], source: local)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("CrossOver/lib/dxvk/aarch64-windows/d3d11.dll"), encoding: .utf8), "arm64ec dxvk")
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
        try publish(files: releaseFiles, sums: String(repeating: "0", count: 64))
        await refused("tarball sha")
        try publish(files: releaseFiles) { j in
            var d = j["dxmt"] as! [String: Any]
            var f = d["files"] as! [String: String]
            f["dxmt/aarch64-windows/d3d11.dll"] = String(repeating: "1", count: 64)
            d["files"] = f
            j["dxmt"] = d
        }
        await refused("file sha")
        try publish(files: releaseFiles, extra: ["dxmt/aarch64-windows/extra.dll": "x"])
        await refused("unlisted file")
        try publish(files: releaseFiles) { j in
            var d = j["dxmt"] as! [String: Any]
            var f = d["files"] as! [String: String]
            f["dxmt/../../escape"] = String(repeating: "1", count: 64)
            d["files"] = f
            j["dxmt"] = d
        }
        await refused("path outside dxmt/dxvk")
        try publish(files: releaseFiles, stock: "v0.80-1-g0000000")
        await refused("other stock DXMT")
        try publish(files: releaseFiles, crossover: "26.3.0.39832")
        await refused("other CrossOver")
        // a dir of that name VarboR didn't make
        try publish(files: releaseFiles)
        try fm.createDirectory(at: Engines.cloneDir(ctx, r), withIntermediateDirectories: true)
        do { try await Engines.install(ctx, r, source: source); XCTFail("foreign dir replaced") } catch {}
        XCTAssertFalse(fm.fileExists(atPath: Engines.cloneDir(ctx, r).appendingPathComponent("CrossOver").path))
    }
}
