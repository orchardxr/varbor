import Foundation
@testable import MacVRCore
import XCTest

let confText = """
;;  CrossOver Bottle Configuration File
[Bottle]
;; Template             The template this bottle is based on.
"Template" = "win10_64"
"WineArch" = "win64"
[ManagedUpdatePolicy]
"^cxbottle.conf$"     = "Link,ReplaceFiles"

[EnvironmentVariables]
;;"PROMPT" = "$p$g"

"""

final class CXConfigTests: XCTestCase {
    func testParseFields() {
        let c = CXConfigFile(text: confText + "\"CX_GRAPHICS_BACKEND\" = \"dxmt\" ; set by the GUI\nPlain = a b \n")
        XCTAssertEqual(c.get("bottle", "winearch"), "win64")
        XCTAssertEqual(c.get("EnvironmentVariables", "CX_GRAPHICS_BACKEND"), "dxmt")
        XCTAssertEqual(c.get("EnvironmentVariables", "Plain"), "a b")
        XCTAssertNil(c.get("EnvironmentVariables", "PROMPT"))
        XCTAssertEqual(CXConfigFile.field("\"a\\\"b\" = \"c\\\\d\"")?.value, "c\\d")
        XCTAssertEqual(CXConfigFile.fieldLine("a\"b", "c\\d"), "\"a\\\"b\" = \"c\\\\d\"")
    }

    func testLibPathAddedAndRevertedByteIdentical() throws {
        let ctx = Context(home: URL(fileURLWithPath: "/h"), support: URL(fileURLWithPath: "/h/S p/macvr"),
                          steamRoot: URL(fileURLWithPath: "/h/Steam"), logDir: URL(fileURLWithPath: "/h/l"),
                          runners: URL(fileURLWithPath: "/h/r"), system: false)
        var rec = Record()
        let fixed = try XCTUnwrap(Bottles.fixedConf(CXConfigFile(text: confText), ctx, &rec))
        XCTAssertEqual(fixed.get("Wine", "LibPath"), "${CX_ROOT}/lib:/h/S p/macvr/bottle-lib")
        XCTAssertTrue(fixed.text.hasSuffix("\n\n[Wine]\n\"LibPath\" = \"${CX_ROOT}/lib:/h/S p/macvr/bottle-lib\"\n"))
        XCTAssertEqual(rec[Bottles.recordKey], "-")
        XCTAssertNil(Bottles.fixedConf(fixed, ctx, &rec))
        XCTAssertEqual(try XCTUnwrap(Bottles.revertedConf(fixed, ctx, rec)).text, confText)

        let own = confText + "[wine]\n\"LibPath\" = \"/opt/lib\"\n\"BinPath\" = \"/opt/bin\"\n"
        var rec2 = Record()
        let fixed2 = try XCTUnwrap(Bottles.fixedConf(CXConfigFile(text: own), ctx, &rec2))
        XCTAssertEqual(fixed2.get("Wine", "LibPath"), "/opt/lib:/h/S p/macvr/bottle-lib")
        XCTAssertEqual(fixed2.get("Wine", "BinPath"), "/opt/bin")
        XCTAssertNil(rec2[Bottles.sectionRecordKey])
        XCTAssertEqual(try XCTUnwrap(Bottles.revertedConf(fixed2, ctx, rec2)).text, own)
    }
}

final class BottleTreeTests: XCTestCase {
    var root: URL!
    var ctx: Context!
    var bottle: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macvr-bottle-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        ctx = Context(home: root, support: root.appendingPathComponent("macvr"), steamRoot: root.appendingPathComponent("Steam"),
                      logDir: root.appendingPathComponent("logs"), runners: root.appendingPathComponent("runners"),
                      system: false)
        try fm.createDirectory(at: ctx.steamRoot.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        bottle = root.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Game One")
        try makeBottle(bottle)
        let payload = root.appendingPathComponent("payload")
        for f in Deploy.required {
            let u = payload.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.write(to: u, atomically: true, encoding: .utf8)
        }
        try "{}".write(to: payload.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try Deploy.install(ctx, payload: payload)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeBottle(_ b: URL, conf: String = confText) throws {
        try FileManager.default.createDirectory(at: b.appendingPathComponent("drive_c/users/crossover"), withIntermediateDirectories: true)
        try regText.write(to: b.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n\n[Environment] 1\n\"TEMP\"=\"C:\\\\temp\"\n\n"
            .write(to: b.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try conf.write(to: b.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
    }

    func files(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let u as URL in e {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                out[String(u.path.dropFirst(dir.path.count))] = try Data(contentsOf: u)
            }
        }
        return out
    }

    func testAddRescanUninstallRoundTrip() throws {
        let before = try files(bottle)
        let rep = try MacVR.addBottle(ctx, bottle)
        XCTAssertEqual(rep.changed, ["bottle/Game One"])
        XCTAssertEqual(ctx.bottles.map(\.path), [bottle.path])
        let reg = try WineRegistry(text: String(contentsOf: bottle.appendingPathComponent("system.reg"), encoding: .utf8))
        XCTAssertEqual(reg.string(Rescan.openxrKey, "ActiveRuntime"), dosPath(ctx.runtimeJSON))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("drive_c/vrclient/bin/vrclient_x64.dll").path))
        XCTAssertTrue(Bottles.confOK(ctx, bottle))
        for f in RunnerInstall.files {
            XCTAssertEqual(try String(contentsOf: Bottles.libWine(ctx).appendingPathComponent(f.dst), encoding: .utf8),
                           "bridge/" + f.src)
        }
        let p = Bottles.prefix(ctx, bottle)
        XCTAssertTrue(p.owner.path.hasPrefix(ctx.stateDir.path))
        XCTAssertEqual(Record.load(p.record)?[Bottles.recordKey], "-")
        XCTAssertNil(try files(bottle).keys.first { $0.contains("macvr") })
        let st = try XCTUnwrap(MacVR.prefixStates(ctx).first { $0.kind == .bottle })
        XCTAssertEqual(st.state, "ok")
        XCTAssertTrue(st.userAdded)
        XCTAssertNotNil(st.warning)

        let mid = try files(bottle)
        XCTAssertEqual(MacVR.rescan(ctx).changed, [])
        XCTAssertEqual(try files(bottle), mid)

        let un = MacVR.uninstall(ctx)
        XCTAssertEqual(un.errors, [])
        XCTAssertEqual(try files(bottle), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.bottleLib.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.owner.path))
    }

    func testUnlinkedCurrentControlSet() throws {
        var r = try WineRegistry(text: regText.replacingOccurrences(of: "ControlSet001", with: "CurrentControlSet"))
        r.setString(Rescan.hklmEnvKeyUnlinked, "VR_OVERRIDE", dosPath(ctx.support.appendingPathComponent("current/opencomposite")))
        try r.text.write(to: bottle.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let unlinked = regText.replacingOccurrences(of: "ControlSet001", with: "CurrentControlSet")
        try MacVR.addBottle(ctx, bottle)
        let text = try String(contentsOf: bottle.appendingPathComponent("system.reg"), encoding: .utf8)
        XCTAssertFalse(text.contains("ControlSet001"))
        XCTAssertNil(try WineRegistry(text: text).string(Rescan.hklmEnvKeyUnlinked, "VR_OVERRIDE"))
        XCTAssertEqual(MacVR.prefixStates(ctx).first?.missing, [])
        _ = MacVR.uninstall(ctx)
        XCTAssertEqual(try String(contentsOf: bottle.appendingPathComponent("system.reg"), encoding: .utf8), unlinked)
    }

    func testRemoveRevertsAndForgets() throws {
        let before = try files(bottle)
        try MacVR.addBottle(ctx, bottle)
        try MacVR.removeBottle(ctx, bottle)
        XCTAssertEqual(ctx.bottles, [])
        XCTAssertEqual(try files(bottle), before)
        XCTAssertThrowsError(try MacVR.removeBottle(ctx, bottle))
    }

    func testForbiddenAndInvalidBottlesRefused() throws {
        try ctx.setPathList("protected-paths", [root.appendingPathComponent("Protected")])
        let cxp = root.appendingPathComponent("Protected/other")
        try makeBottle(cxp)
        let before = try files(cxp)
        XCTAssertThrowsError(try MacVR.addBottle(ctx, cxp)) { XCTAssertTrue("\($0)".contains("Protected")) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cxp)
        XCTAssertThrowsError(try MacVR.addBottle(ctx, link))
        XCTAssertThrowsError(try MacVR.addLibrary(ctx, root.appendingPathComponent("Protected")))
        // a forbidden path put into the settings by hand is still skipped
        try ctx.setPathList("bottles", [cxp])
        _ = MacVR.rescan(ctx)
        XCTAssertEqual(try files(cxp), before)

        let b32 = root.appendingPathComponent("b32")
        try makeBottle(b32, conf: confText.replacingOccurrences(of: "win64", with: "win32"))
        XCTAssertThrowsError(try MacVR.addBottle(ctx, b32)) { XCTAssertTrue("\($0)".contains("32-bit")) }
        XCTAssertThrowsError(try MacVR.addBottle(ctx, root.appendingPathComponent("Steam")))
    }

    func testBackendWarning() throws {
        XCTAssertTrue(Bottles.backendWarning(bottle)!.contains("Auto"))
        for (b, warn) in [("dxmt", false), ("DXVK", false), ("d3dmetal", true)] {
            try (confText + "\"CX_GRAPHICS_BACKEND\" = \"\(b)\"\n").write(to: Bottles.conf(bottle), atomically: true, encoding: .utf8)
            XCTAssertEqual(Bottles.backendWarning(bottle) != nil, warn, b)
        }
    }

    func testSettingsLists() throws {
        let a = URL(fileURLWithPath: "/x/with space/\"q\"/a=b")
        try ctx.setPathList("bottles", [a, URL(fileURLWithPath: "/y")])
        XCTAssertEqual(ctx.bottles.map(\.path), [a.path, "/y"])
        try ctx.setPathList("bottles", [])
        XCTAssertNil(ctx.settings["bottles"])
        XCTAssertEqual(ctx.extraLibraries, [])
    }

    func testExtraLibraryDiscovery() throws {
        let lib = root.appendingPathComponent("Ext Lib")
        let pfx = lib.appendingPathComponent("steamapps/compatdata/300/pfx")
        try FileManager.default.createDirectory(at: pfx, withIntermediateDirectories: true)
        try regText.write(to: pfx.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let before = try files(lib)
        XCTAssertFalse(ctx.steam.prefixes.contains { $0.name == "300" })
        XCTAssertThrowsError(try MacVR.addLibrary(ctx, root.appendingPathComponent("nothing")))
        let rep = try MacVR.addLibrary(ctx, lib.appendingPathComponent("steamapps"))
        XCTAssertEqual(ctx.extraLibraries.map(\.path), [lib.path])
        XCTAssertEqual(rep.changed, ["300"])
        XCTAssertEqual(ctx.steam.libraries.map(\.path), [ctx.steamRoot.path, lib.path])
        XCTAssertTrue(MacVR.prefixStates(ctx).first { $0.name == "300" }!.userAdded)
        try MacVR.addLibrary(ctx, lib)
        XCTAssertEqual(ctx.extraLibraries.count, 1)
        try MacVR.removeLibrary(ctx, lib)
        XCTAssertEqual(ctx.extraLibraries, [])
        XCTAssertEqual(try files(lib).filter { !$0.key.contains("/macvr-backup/") }, before)
    }

    func testLibraryListedBySteamIsNotDuplicated() throws {
        let lib = root.appendingPathComponent("Lib2")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try "\"libraryfolders\"\n{\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"\(lib.path)\"\n\t}\n}\n"
            .write(to: ctx.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        try ctx.setPathList("steam-libraries", [lib.appendingPathComponent("./")])
        XCTAssertEqual(ctx.steam.libraries.map(\.path), [ctx.steamRoot.path, lib.path])
    }
}
