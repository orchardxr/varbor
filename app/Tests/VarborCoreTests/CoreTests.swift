import Foundation
@testable import VarborCore
import XCTest

let regText = """
WINE REGISTRY Version 2
;; All keys relative to \\\\Machine

#arch=win64

[Software\\\\Khronos\\\\Vulkan\\\\Drivers] 1792658946
#time=1dd6202321352fc
"C:\\\\windows\\\\system32\\\\winevulkan.json"=dword:00000000

[System\\\\ControlSet001\\\\Control\\\\Session Manager\\\\Environment] 1792658946
#time=1dd6202321352fc
"PATH"=str(2):"C:\\\\windows\\\\system32"
"windir"="C:\\\\windows"

"""

final class RegistryTests: XCTestCase {
    func testSetInsertsSortedBlock() throws {
        var r = try WineRegistry(text: regText)
        XCTAssertNil(r.string(Rescan.openxrKey, "ActiveRuntime"))
        r.setString(Rescan.openxrKey, "ActiveRuntime", "Z:\\Users\\a b\\x.json", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(r.string(Rescan.openxrKey, "activeruntime"), "Z:\\Users\\a b\\x.json")
        let t = r.text
        let i = t.range(of: "[Software\\\\Khronos\\\\OpenXR\\\\1] 1800000000\n#time=")!
        XCTAssertLessThan(i.lowerBound, t.range(of: "[Software\\\\Khronos\\\\Vulkan")!.lowerBound)
        XCTAssertTrue(t.contains("\"ActiveRuntime\"=\"Z:\\\\Users\\\\a b\\\\x.json\"\n\n[Software"))
        r.deleteValue(Rescan.openxrKey, "ActiveRuntime")
        XCTAssertEqual(r.text, regText)
    }

    func testValueInExistingBlock() throws {
        var r = try WineRegistry(text: regText)
        r.setString(Rescan.hklmEnvKey, "VR_OVERRIDE", "Z:\\o")
        XCTAssertTrue(r.text.contains("\"windir\"=\"C:\\\\windows\"\n\"VR_OVERRIDE\"=\"Z:\\\\o\"\n"))
        r.setString(Rescan.hklmEnvKey, "VR_OVERRIDE", "Z:\\p")
        XCTAssertEqual(r.string(Rescan.hklmEnvKey, "VR_OVERRIDE"), "Z:\\p")
        r.deleteValue(Rescan.hklmEnvKey, "VR_OVERRIDE")
        XCTAssertEqual(r.text, regText)
    }

    func testEscapes() {
        XCTAssertEqual(WineRegistry.escape("a\"\\é"), "a\\\"\\\\\\x00e9")
        XCTAssertEqual(WineRegistry.unescape("a\\\"\\\\\\x00e9"), "a\"\\é")
    }
}

final class ScratchTreeTests: XCTestCase {
    var root: URL!
    var ctx: Context!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("varbor-tests-\(UUID().uuidString)")
        let steam = root.appendingPathComponent("Steam")
        ctx = Context(home: root, support: root.appendingPathComponent("varbor"), steamRoot: steam,
                      logDir: root.appendingPathComponent("logs"), runners: root.appendingPathComponent("runners"),
                      system: false)
        let fm = FileManager.default
        for p in ["steamapps/compatdata/100/pfx", "steamapps/compatdata/200/pfx",
                  "steamapps/compatdata/notproton-template/crossover-1-x86_64-unix/pfx"] {
            let d = steam.appendingPathComponent(p)
            try fm.createDirectory(at: d.appendingPathComponent("drive_c/users/steamuser"), withIntermediateDirectories: true)
            try regText.write(to: d.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
            try "WINE REGISTRY Version 2\n\n[Environment] 1\n\"TEMP\"=\"C:\\\\temp\"\n\n"
                .write(to: d.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        }
        // 200 already correct (as if cloned from a fixed template)
        let payload = root.appendingPathComponent("payload")
        for f in Deploy.required {
            let u = payload.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.write(to: u, atomically: true, encoding: .utf8)
        }
        try "{}".write(to: payload.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for r in ["crossover-1", "crossover-1-fex"] {
            let lib = ctx.runners.appendingPathComponent("\(r)/CrossOver/lib/wine")
            for f in ["x86_64-windows/ntdll.dll", "x86_64-unix/ntdll.so"] {
                try fm.createDirectory(at: lib.appendingPathComponent(f).deletingLastPathComponent(), withIntermediateDirectories: true)
                try "ntdll".write(to: lib.appendingPathComponent(f), atomically: true, encoding: .utf8)
            }
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func snapshot() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let u as URL in e where !u.path.contains("/varbor/") && !u.path.contains("varbor-backup") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                out[String(u.path.dropFirst(root.path.count))] = try Data(contentsOf: u)
            }
        }
        return out
    }

    func testExcludedPrefixIsRevertedAndRestored() throws {
        let p100 = { Steam(root: self.ctx.steamRoot).prefixes.first { $0.name == "100" }! }
        let original = try Data(contentsOf: p100().systemReg)
        try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        let runtime = { try WineRegistry(text: String(contentsOf: p100().systemReg, encoding: .utf8)).string(Rescan.openxrKey, "ActiveRuntime") }
        XCTAssertEqual(try runtime(), dosPath(ctx.runtimeJSON))

        let rep = try Varbor.setExcluded(ctx, p100().owner, true)
        XCTAssertTrue(rep.changed.contains("100"))
        XCTAssertNil(try runtime())
        XCTAssertEqual(try Data(contentsOf: p100().systemReg), original)
        XCTAssertEqual(Varbor.prefixStates(ctx).first { $0.name == "100" }?.state, "excluded")
        XCTAssertEqual(Varbor.rescan(ctx).changed, [])

        try Varbor.setExcluded(ctx, p100().owner, false)
        XCTAssertEqual(try runtime(), dosPath(ctx.runtimeJSON))
        XCTAssertEqual(Varbor.prefixStates(ctx).first { $0.name == "100" }?.state, "ok")
    }

    func testInstallIdempotentAndUninstallRoundTrip() throws {
        let before = try snapshot()
        let rep = try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(rep.changed.count, 3)
        XCTAssertEqual(rep.changed.first, "template/crossover-1-x86_64-unix")
        let p = Steam(root: ctx.steamRoot).prefixes.first { $0.name == "100" }!
        let reg = try WineRegistry(text: String(contentsOf: p.systemReg, encoding: .utf8))
        XCTAssertEqual(reg.string(Rescan.openxrKey, "ActiveRuntime"), dosPath(ctx.runtimeJSON))
        XCTAssertNil(reg.string(Rescan.hklmEnvKey, "VR_OVERRIDE"))
        let user = try WineRegistry(text: String(contentsOf: p.pfx.appendingPathComponent("user.reg"), encoding: .utf8))
        XCTAssertEqual(user.string(Rescan.wineVRKey, "openvr_vulkan_instance_extensions"), "VK_KHR_surface")
        XCTAssertEqual(user.rawValueLine(Rescan.wineVRKey, "state"), "\"state\"=dword:00000001")
        XCTAssertEqual(try String(contentsOf: p.pfx.appendingPathComponent("drive_c/vrclient/bin/vrclient_x64.dll"), encoding: .utf8),
                       "bridge/x86_64-windows/vrclient_x64.dll")
        let vrpath = p.pfx.appendingPathComponent("drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath")
        XCTAssertEqual(try String(contentsOf: vrpath, encoding: .utf8), Rescan.vrpathJSON(ctx))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: vrpath.path))[.posixPermissions] as? Int, 0o444)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.record.path))
        XCTAssertEqual(try String(contentsOf: ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-unix/wineopenxr.so"), encoding: .utf8),
                       "bridge/x86_64-unix/wineopenxr.so")
        XCTAssertEqual(try String(contentsOf: ctx.runners.appendingPathComponent("crossover-1-fex/CrossOver/lib/wine/x86_64-windows/vrclient_x64.so"), encoding: .utf8),
                       "bridge/x86_64-unix/vrclient_x64.so")

        let mid = try snapshot()
        let again = try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(again.changed, [])
        XCTAssertEqual(try snapshot(), mid)

        let un = Varbor.uninstall(ctx)
        XCTAssertEqual(un.busy, [])
        XCTAssertEqual(un.errors, [])
        XCTAssertEqual(try snapshot(), before)
    }

    func testCorrectPrefixIsNotTouched() throws {
        try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        let p200 = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/200")
        let rec = p200.appendingPathComponent("varbor-vr")
        let snap = try snapshot()
        let recData = try Data(contentsOf: rec)
        let rep = Rescan.run(ctx)
        XCTAssertTrue(rep.unchanged.contains("200"))
        XCTAssertEqual(try snapshot(), snap)
        XCTAssertEqual(try Data(contentsOf: rec), recData)
    }

    func testOldOpenCompositeValuesRemovedWithoutRecord() throws {
        // a game prefix cloned from an earlier version's template: VR_OVERRIDE into our dir, no record
        let sys = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/system.reg")
        var reg = try WineRegistry(text: regText)
        reg.setString(Rescan.hklmEnvKey, "VR_OVERRIDE", dosPath(ctx.support.appendingPathComponent("current/opencomposite")))
        reg.setString(Rescan.hklmEnvKey, "VR_LOG_PATH", "C:\\theirs")
        try reg.text.write(to: sys, atomically: true, encoding: .utf8)
        try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        let after = try WineRegistry(text: String(contentsOf: sys, encoding: .utf8))
        XCTAssertNil(after.string(Rescan.hklmEnvKey, "VR_OVERRIDE"))
        XCTAssertEqual(after.string(Rescan.hklmEnvKey, "VR_LOG_PATH"), "C:\\theirs")
    }

    func testForeignVRPathBackedUpAndRestored() throws {
        let f = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"runtime\":[\"C:\\\\other\"]}".write(to: f, atomically: true, encoding: .utf8)
        let theirs = try Data(contentsOf: f)
        try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), Rescan.vrpathJSON(ctx))
        _ = Varbor.uninstall(ctx)
        XCTAssertEqual(try Data(contentsOf: f), theirs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vrclient").path))
    }

    func testPreviousValueRestored() throws {
        let sys = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/system.reg")
        var reg = try WineRegistry(text: regText)
        reg.setString(Rescan.openxrKey, "ActiveRuntime", "C:\\other.json", now: Date(timeIntervalSince1970: 1))
        try reg.text.write(to: sys, atomically: true, encoding: .utf8)
        let orig = reg.text
        try Varbor.install(ctx, payload: root.appendingPathComponent("payload"))
        _ = Varbor.uninstall(ctx)
        XCTAssertEqual(try String(contentsOf: sys, encoding: .utf8), orig)
    }

    func testRunnerAddOnly() throws {
        try Deploy.install(ctx, payload: root.appendingPathComponent("payload"))
        let foreign = ctx.runners.appendingPathComponent("crossover-1-fex/CrossOver/lib/wine/x86_64-windows/wineopenxr.dll")
        try "theirs".write(to: foreign, atomically: true, encoding: .utf8)
        let r = try RunnerInstall.ensure(ctx)
        XCTAssertEqual(r.installed, 11)
        XCTAssertEqual(r.foreign, [foreign.path])
        let fex = ctx.runners.appendingPathComponent("crossover-1-fex/CrossOver/lib/wine/x86_64-windows/wineopenxr.so")
        XCTAssertEqual(try String(contentsOf: fex, encoding: .utf8), "bridge/x86_64-unix/wineopenxr.so")
        RunnerInstall.remove(ctx)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "theirs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-windows/wineopenxr.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fex.path))
    }

    func testRunnerFileFromEarlierVersionRemoved() throws {
        try Deploy.install(ctx, payload: root.appendingPathComponent("payload"))
        let old = ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-windows/oldbridge.dll")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        let changed = ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-windows/oldother.dll")
        try "old".write(to: changed, atomically: true, encoding: .utf8)
        try RunnerInstall.saveRecord(ctx, [old.path: Deploy.sha256(old)!, changed.path: "0"])
        try RunnerInstall.ensure(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
        XCTAssertNil(RunnerInstall.loadRecord(ctx)[changed.path])
    }

    func testMachoArchs() throws {
        let u = root.appendingPathComponent("fat")
        var d = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        for cpu: [UInt8] in [[1, 0, 0, 7], [1, 0, 0, 12]] { d += cpu + [UInt8](repeating: 0, count: 16) }
        try d.write(to: u)
        XCTAssertEqual(RunnerInstall.machoArchs(u), ["x86_64", "arm64"])
        try Data([0xCF, 0xFA, 0xED, 0xFE, 12, 0, 0, 1]).write(to: u)
        XCTAssertEqual(RunnerInstall.machoArchs(u), ["arm64"])
    }

}

final class RunnerRegistrationTests: XCTestCase {
    func testScriptNestsKeysAndEscapes() {
        let s = RunnerRegistration.script([
            RegValue(file: "system.reg", key: Rescan.openxrKey, name: "ActiveRuntime", value: "Z:\\a b\\it's 100%.json"),
            RegValue(file: "system.reg", key: Rescan.hklmEnvKey, name: "VR_OVERRIDE", value: "Z:\\oc"),
            .dword(file: "system.reg", key: Rescan.wineVRKey, name: "state", 1),
            RegValue(file: "user.reg", key: Rescan.hkcuEnvKey, name: "VR_LOG_PATH", value: "Z:\\log"),
        ])
        XCTAssertTrue(s.hasPrefix("HKLM\n{\n\tNoRemove 'Software'\n\t{\n\t\tNoRemove 'Khronos'\n"))
        XCTAssertTrue(s.contains("val 'ActiveRuntime' = s 'Z:\\a b\\it''s 100%%.json'\n"))
        XCTAssertTrue(s.contains("NoRemove 'Session Manager'"))
        XCTAssertTrue(s.contains("val 'state' = d '1'\n"))
        XCTAssertTrue(s.contains("HKCU\n{\n\tNoRemove 'Environment'\n\t{\n\t\tval 'VR_LOG_PATH' = s 'Z:\\log'\n\t}\n}\n"))
        XCTAssertEqual(s.filter { $0 == "{" }.count, s.filter { $0 == "}" }.count)
    }

    func testFillKeepsSize() throws {
        let region = Data("VARBOR-RGS-BEGIN".utf8) + Data(repeating: 0x20, count: 40) + Data("VARBOR-RGS-END".utf8)
        let dll = Data("MZhead".utf8) + region + Data("tail".utf8)
        let out = try XCTUnwrap(RunnerRegistration.fill(dll, script: "HKLM\n{\n}\n"))
        XCTAssertEqual(out.count, dll.count)
        XCTAssertEqual(out.prefix(14), Data("MZheadHKLM\n{\n}".utf8))
        XCTAssertTrue(out.suffix(4) == Data("tail".utf8))
        XCTAssertThrowsError(try RunnerRegistration.fill(dll, script: String(repeating: "x", count: 100)))
        XCTAssertNil(try RunnerRegistration.fill(Data("MZ".utf8), script: ""))
    }
}

final class LogRotationTests: XCTestCase {
    func testKeepsAtMostTenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("varbor-logrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("x.log")
        for run in 1...14 {
            Log.rotate(log)
            try "run \(run)".write(to: log, atomically: true, encoding: .utf8)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 10)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "run 14")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("x.1.log"), encoding: .utf8), "run 13")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("x.9.log"), encoding: .utf8), "run 5")
    }
}
