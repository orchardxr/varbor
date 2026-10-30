import Foundation
@testable import VarborCore
import XCTest

final class MigrationTests: XCTestCase {
    var root: URL!
    var ctx: Context!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("varbor-migration-\(UUID().uuidString)")
        ctx = Context(home: root, support: root.appendingPathComponent("AS/varbor"), steamRoot: root.appendingPathComponent("Steam"),
                      logDir: root.appendingPathComponent("Logs/VarboR"), runners: root.appendingPathComponent("runners"), system: false)
        ctx.legacySupport = root.appendingPathComponent("AS/macvr")
        ctx.legacyLogDir = root.appendingPathComponent("Logs/MacVR")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSupportAndLogsMoved() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ctx.legacySupport!.appendingPathComponent("state"), withIntermediateDirectories: true)
        try "x=1\n".write(to: ctx.legacySupport!.appendingPathComponent("state/runner-files"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: ctx.legacyLogDir!, withIntermediateDirectories: true)
        Migration.run(ctx)
        XCTAssertEqual(try String(contentsOf: ctx.support.appendingPathComponent("state/runner-files"), encoding: .utf8), "x=1\n")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: ctx.legacySupport!.path), "varbor")
        XCTAssertTrue(fm.fileExists(atPath: ctx.logDir.path))
        Migration.run(ctx)
        XCTAssertTrue(fm.fileExists(atPath: ctx.support.appendingPathComponent("state/runner-files").path))
    }

    func testPrefixRecordAndOldValuesTakenOver() throws {
        let fm = FileManager.default
        let owner = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100")
        let pfx = owner.appendingPathComponent("pfx")
        try fm.createDirectory(at: pfx.appendingPathComponent("drive_c/users/steamuser"), withIntermediateDirectories: true)
        var reg = try WineRegistry(text: regText)
        reg.setString(Rescan.openxrKey, "ActiveRuntime", dosPath(ctx.legacySupport!.appendingPathComponent("current/bridge/wineopenxr.json")))
        reg.setString(Rescan.hklmEnvKey, "VR_OVERRIDE", dosPath(ctx.legacySupport!.appendingPathComponent("current/opencomposite")))
        try reg.text.write(to: pfx.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n\n".write(to: pfx.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try "reg|system.reg|\(Rescan.openxrKey)|ActiveRuntime=-\nversion=1\n"
            .write(to: owner.appendingPathComponent("macvr-vr"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: owner.appendingPathComponent("macvr-backup"), withIntermediateDirectories: true)
        try regText.write(to: owner.appendingPathComponent("macvr-backup/system.reg.orig"), atomically: true, encoding: .utf8)

        let payload = root.appendingPathComponent("payload")
        for f in Deploy.required {
            let u = payload.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.write(to: u, atomically: true, encoding: .utf8)
        }
        try Varbor.install(ctx, payload: payload)
        XCTAssertFalse(fm.fileExists(atPath: owner.appendingPathComponent("macvr-vr").path))
        XCTAssertTrue(fm.fileExists(atPath: owner.appendingPathComponent("varbor-backup/system.reg.orig").path))
        let after = try WineRegistry(text: String(contentsOf: pfx.appendingPathComponent("system.reg"), encoding: .utf8))
        XCTAssertEqual(after.string(Rescan.openxrKey, "ActiveRuntime"), dosPath(ctx.runtimeJSON))
        XCTAssertNil(after.string(Rescan.hklmEnvKey, "VR_OVERRIDE"))
        // the record kept MacVR's "nothing before us", so uninstall still leaves no value behind
        _ = Varbor.uninstall(ctx)
        XCTAssertEqual(try String(contentsOf: pfx.appendingPathComponent("system.reg"), encoding: .utf8), regText)
    }

    func testBottleLibPathMoved() throws {
        let old = ctx.legacySupport!.appendingPathComponent("bottle-lib").path
        let text = confText + "[Wine]\n\"LibPath\" = \"${CX_ROOT}/lib:\(old)\"\n"
        var rec = Record(values: [Bottles.recordKey: "-", Bottles.sectionRecordKey: "created"])
        let fixed = try XCTUnwrap(Bottles.fixedConf(CXConfigFile(text: text), ctx, &rec))
        XCTAssertEqual(fixed.get("Wine", "LibPath"), "${CX_ROOT}/lib:\(ctx.bottleLib.path)")
        XCTAssertEqual(try XCTUnwrap(Bottles.revertedConf(CXConfigFile(text: text), ctx, rec)).text, confText)
    }

    func testUpdateAssetIsVarboRZip() {
        XCTAssertEqual(Updater.appAsset(["MacVR-0.1.0.zip", "VarboR-0.1.0.zip"]), "VarboR-0.1.0.zip")
        XCTAssertNil(Updater.appAsset(["MacVR-0.0.5.zip"]))
    }
}
