import Foundation
@testable import VarborCore
import XCTest

final class ComponentsTests: XCTestCase {
    var root: URL!
    var roots: Components.Roots!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("varbor-components-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        roots = Components.Roots(home: home, steamRoot: home.appendingPathComponent("Library/Application Support/Steam"),
                                 runners: home.appendingPathComponent("Library/Application Support/notproton/runners"),
                                 systemOpenXR: [root.appendingPathComponent("usr/local/share/openxr/1")],
                                 wivrnTrees: [root.appendingPathComponent("opt/wivrn")],
                                 applications: [root.appendingPathComponent("Applications")])
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testNothingInstalled() {
        let all = Components.all(roots)
        XCTAssertEqual(all.map(\.health), [.missing, .missing, .missing])
        XCTAssertEqual(all.map(\.page), [Components.notProtonPage, Components.wivrnPage, Components.openCompositePage])
    }

    func testVersions() {
        XCTAssertEqual(Components.versionNumbers("v0.2.1-3-gabc1234"), [0, 2, 1])
        XCTAssertNil(Components.versionNumbers("abc1234-dirty"))
        XCTAssertEqual(Components.atLeast("0.10.0", "0.9.9"), true)
        XCTAssertEqual(Components.atLeast("v0.1", "0.1.0"), true)
        XCTAssertEqual(Components.atLeast("0.0.9", "0.1.0"), false)
        XCTAssertNil(Components.atLeast("cff07db", "0.1.0"))
    }

    func testNotProtonRunnersAndTools() throws {
        let np = roots.home.appendingPathComponent("Library/Application Support/notproton")
        try write("{\"version\":\"1.2.2\"}", np.appendingPathComponent("install-build.json"))
        XCTAssertEqual(Components.notProton(roots).health, .missing)
        try write("ntdll", roots.runners.appendingPathComponent("crossover-27.0.0.41073-fex/CrossOver/lib/wine/x86_64-windows/ntdll.dll"))
        XCTAssertEqual(Components.notProton(roots).health, .warning)
        try write("notproton-fex-41073\t27.0.0.41073-fex\tfex\tCrossOver - FEX\n", np.appendingPathComponent("tools"))
        let s = Components.notProton(roots)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.version, "1.2.2")
        XCTAssertEqual(s.items, ["runner crossover-27.0.0.41073-fex", "tool notproton-fex-41073"])
    }

    func makeWiVRn(_ tree: URL, version: String, stamp: Bool = true) throws {
        try write("x", tree.appendingPathComponent("lib/wivrn/libopenxr_wivrn.dylib"))
        try write("{\"file_format_version\":\"1.0.0\",\"runtime\":{\"name\":\"WiVRn\",\"library_path\":\"../../../lib/wivrn/libopenxr_wivrn.dylib\"}}",
                  tree.appendingPathComponent("share/openxr/1/openxr_wivrn.json"))
        try write("wivrn-macos=\(version)\nwivrn=v26.9 abc\nprefix=\(tree.path)\n", tree.appendingPathComponent("share/wivrn/build-info"))
        if stamp { try write("stamp\n", tree.appendingPathComponent("share/wivrn/ipc-stamp")) }
    }

    func testWiVRnActiveInstall() throws {
        let tree = root.appendingPathComponent("wivrn-install")
        try makeWiVRn(tree, version: "v0.3.0")
        let active = roots.home.appendingPathComponent(".config/openxr/1/active_runtime.json")
        try fm.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: active, withDestinationURL: tree.appendingPathComponent("share/openxr/1/openxr_wivrn.json"))
        let s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .ok, "\(s.notes)")
        XCTAssertEqual(s.location, tree.standardizedFileURL.path)
        XCTAssertEqual(s.version, "v0.3.0")
        XCTAssertEqual(s.notes, ["WiVRn v26.9"])
    }

    func testWiVRnAppBundle() throws {
        // WiVRn.app: Contents/Frameworks/libopenxr_wivrn.dylib, Contents/Resources/{openxr/1,wivrn}
        let contents = root.appendingPathComponent("Applications/WiVRn.app/Contents")
        try write("x", contents.appendingPathComponent("Frameworks/libopenxr_wivrn.dylib"))
        try write("{\"file_format_version\":\"1.0.0\",\"runtime\":{\"name\":\"WiVRn\",\"library_path\":\"../../../Frameworks/libopenxr_wivrn.dylib\"}}",
                  contents.appendingPathComponent("Resources/openxr/1/openxr_wivrn.json"))
        try write("wivrn-macos=04576b5-dirty\nwivrn=v26.9 bbc6e4c\napp=26.9.0\n", contents.appendingPathComponent("Resources/wivrn/build-info"))
        try write("stamp\n", contents.appendingPathComponent("Resources/wivrn/ipc-stamp"))
        let active = roots.home.appendingPathComponent(".config/openxr/1/active_runtime.json")
        try fm.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: active, withDestinationURL: contents.appendingPathComponent("Resources/openxr/1/openxr_wivrn.json"))
        var s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .ok, "\(s.notes)")
        XCTAssertEqual(s.location, contents.standardizedFileURL.path)
        XCTAssertEqual(s.version, "04576b5-dirty")
        XCTAssertEqual(s.notes, ["WiVRn v26.9"])
        // the same registered in /usr/local/share/openxr/1 instead
        try fm.removeItem(at: active)
        try fm.createDirectory(at: roots.systemOpenXR[0], withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: roots.systemOpenXR[0].appendingPathComponent("active_runtime.json"),
                                  withDestinationURL: contents.appendingPathComponent("Resources/openxr/1/openxr_wivrn.json"))
        s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .ok, "\(s.notes)")
        // a version= line wins over the commit
        try write("version=0.2.0\nwivrn-macos=04576b5\n", contents.appendingPathComponent("Resources/wivrn/build-info"))
        XCTAssertEqual(Components.wivrn(roots).version, "0.2.0")
    }

    func testWiVRnOutdatedInactiveAndForeign() throws {
        try makeWiVRn(roots.wivrnTrees[0], version: "v0.0.1", stamp: false)
        var s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .outdated)
        XCTAssertTrue(s.notes.contains("needs \(Components.minimumWiVRn) or newer"))
        XCTAssertTrue(s.notes.contains(Components.wivrnRegistersOnConnect))
        XCTAssertTrue(s.notes.contains { $0.contains("ipc-stamp") })

        try fm.removeItem(at: roots.wivrnTrees[0])
        try write("{\"runtime\":{\"library_path\":\"/x/libopenxr_monado.dylib\"}}",
                  roots.systemOpenXR[0].appendingPathComponent("active_runtime.json"))
        s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .warning)
        XCTAssertEqual(s.location, "/x/libopenxr_monado.dylib")
    }

    func testWiVRnNoActiveRuntimeUntilHeadsetConnects() throws {
        try makeWiVRn(roots.wivrnTrees[0], version: "v0.3.0")
        let s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .ok, "\(s.notes)")
        XCTAssertEqual(s.notes, ["WiVRn v26.9", Components.wivrnRegistersOnConnect])
    }

    func testWiVRnInstalledButAnotherRuntimeActive() throws {
        try makeWiVRn(roots.wivrnTrees[0], version: "v0.3.0")
        let active = roots.home.appendingPathComponent(".config/openxr/1/active_runtime.json")
        try write("{\"runtime\":{\"library_path\":\"/x/libopenxr_monado.dylib\"}}", active)
        var s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .warning)
        XCTAssertEqual(s.location, roots.wivrnTrees[0].standardizedFileURL.path)
        XCTAssertTrue(s.notes.contains { $0.hasPrefix("another OpenXR runtime is active (/x/libopenxr_monado.dylib)") }, "\(s.notes)")
        XCTAssertFalse(s.notes.contains(Components.wivrnRegistersOnConnect))

        try write("not json", active)
        s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .warning)
        XCTAssertTrue(s.notes.contains { $0.hasPrefix("another OpenXR runtime is active (\(active.path))") }, "\(s.notes)")

        try fm.removeItem(at: active)
        try fm.createSymbolicLink(at: active, withDestinationURL: roots.wivrnTrees[0].appendingPathComponent("share/openxr/1/openxr_wivrn.json"))
        s = Components.wivrn(roots)
        XCTAssertEqual(s.health, .ok, "\(s.notes)")
        XCTAssertEqual(s.notes, ["WiVRn v26.9"])
    }

    func makeOC(_ rt: URL, version: String, sync: Bool) throws {
        try write("MZ" + (sync ? Components.openCompositeSyncSymbol : "_other"), rt.appendingPathComponent("bin/osx64/vrclient.dylib"))
        try write("cff07db opencomposite-macos \(version)\n", rt.appendingPathComponent("bin/osx64/version.txt"))
    }

    func vrpath(_ runtimes: [String]) throws {
        let d = try JSONSerialization.data(withJSONObject: ["runtime": runtimes, "jsonid": "vrpathreg", "version": 1])
        try write(String(decoding: d, as: UTF8.self),
                  roots.home.appendingPathComponent("Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"))
    }

    func testOpenComposite() throws {
        let rt = roots.home.appendingPathComponent("Library/Application Support/OpenComposite/runtime")
        XCTAssertEqual(Components.openComposite(roots).health, .missing)
        XCTAssertEqual(Components.openComposite(roots).notes, ["not installed"])
        try makeOC(rt, version: "0.2.0", sync: true)
        // installed, not registered: WiVRn registers it while its server runs
        var s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.version, "0.2.0")
        XCTAssertEqual(s.location, rt.path)
        XCTAssertEqual(s.notes, [Components.openCompositeActivatedByWiVRn])
        try vrpath([])
        XCTAssertEqual(Components.openComposite(roots).notes, [Components.openCompositeActivatedByWiVRn])

        // registered (by WiVRn, or install.sh --register), also with a trailing slash
        try vrpath(["/gone", rt.path + "/"])
        s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.location, rt.path)
        XCTAssertEqual(s.notes, ["/gone comes first in openvrpaths.vrpath but has no vrclient.dylib"])

        // another runtime with a vrclient.dylib registered first: the bridge loads that one
        let other = roots.home.appendingPathComponent("Other/runtime")
        try makeOC(other, version: "0.1.0", sync: true)
        try vrpath([other.path, rt.path])
        s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .warning)
        XCTAssertEqual(s.location, rt.path)
        XCTAssertTrue(s.notes.contains { $0.hasPrefix("\(other.path) is registered first") }, "\(s.notes)")

        // only a registered install elsewhere (OPENCOMPOSITE_HOME)
        try fm.removeItem(at: rt)
        s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.location, other.path)
        XCTAssertEqual(s.version, "0.1.0")
        try vrpath([])
        try makeOC(rt, version: "0.2.0", sync: true)

        // a commit-only build: shown as is, no version warning
        try makeOC(rt, version: "dd200ad", sync: true)
        s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.version, "dd200ad")
        XCTAssertEqual(s.notes.filter { $0.contains("version") }, [])
        // share/opencomposite/build-info's version= wins
        try write("version=0.3.0\n", rt.appendingPathComponent("share/opencomposite/build-info"))
        XCTAssertEqual(Components.openComposite(roots).version, "0.3.0")

        try fm.removeItem(at: rt.appendingPathComponent("share"))
        try makeOC(rt, version: "unknown", sync: false)
        s = Components.openComposite(roots)
        XCTAssertEqual(s.health, .outdated)
        XCTAssertTrue(s.notes.contains { $0.contains("oc_metal_submit_sync") })
    }
}
