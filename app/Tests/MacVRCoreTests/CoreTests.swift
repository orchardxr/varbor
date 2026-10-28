import Foundation
@testable import MacVRCore
import XCTest

final class LaunchOptionsTests: XCTestCase {
    let ours = [("WINEDLLPATH", "/Users/x/Library/Application Support/macvr/current/bridge")]

    func testMergeKeepsUserTokens() {
        let s = "WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt WINEDLLPATH=\"/old/drive_c/macvr\" %command% -condebug -vconsole"
        let m = LaunchOptions.apply(s, ours: ours)
        XCTAssertEqual(m.result, "MACVR=1 WINEDLLPATH=\"/Users/x/Library/Application Support/macvr/current/bridge\" "
                       + "WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt %command% -condebug -vconsole")
        XCTAssertEqual(m.displaced, ["WINEDLLPATH=\"/old/drive_c/macvr\""])
        XCTAssertEqual(LaunchOptions.apply(m.result, ours: ours).result, m.result)
        XCTAssertEqual(LaunchOptions.remove(m.result, keys: ["WINEDLLPATH"], restore: m.displaced, addedCommand: false),
                       "WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt WINEDLLPATH=\"/old/drive_c/macvr\" %command% -condebug -vconsole")
    }

    func testMergeWithoutCommand() {
        let m = LaunchOptions.apply("-novid", ours: ours)
        XCTAssertTrue(m.addedCommand)
        XCTAssertTrue(m.result.hasSuffix("%command% -novid"))
        XCTAssertEqual(LaunchOptions.remove(m.result, keys: ["WINEDLLPATH"], restore: [], addedCommand: true), "-novid")
        XCTAssertEqual(LaunchOptions.remove(LaunchOptions.apply("", ours: ours).result, keys: ["WINEDLLPATH"],
                                            restore: [], addedCommand: true), "")
    }

    func testTokenValue() {
        let t = LaunchOptions.tokenize("A=\"x y\" B='z' %command%")
        XCTAssertEqual(t.map(\.raw), ["A=\"x y\"", "B='z'", "%command%"])
        XCTAssertEqual(t[0].value, "x y")
        XCTAssertNil(t[2].key)
    }

    func testLegacyRemoval() {
        let s = "WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt WINEDLLPATH=\"/a b/compatdata/546560/pfx/drive_c/macvr\" %command% -condebug"
        XCTAssertEqual(SteamConfig.withoutLegacy(s), "WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt %command% -condebug")
        XCTAssertEqual(SteamConfig.withoutLegacy("WINEDLLPATH=/p/drive_c/macvr"), nil)
    }
}

final class VDFTests: XCTestCase {
    let text = """
    "UserLocalConfigStore"
    {
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"apps"
    \t\t\t\t{
    \t\t\t\t\t"546560"
    \t\t\t\t\t{
    \t\t\t\t\t\t"LaunchOptions"\t\t"A=1 B=\\"x y\\" %command%"
    \t\t\t\t\t\t"Playtime"\t\t"5"
    \t\t\t\t\t}
    \t\t\t\t\t"7"
    \t\t\t\t\t{
    \t\t\t\t\t\t"Playtime"\t\t"1"
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    }

    """

    func testRead() throws {
        XCTAssertEqual(try LocalConfig.launchOptions(text, appid: "546560"), "A=1 B=\"x y\" %command%")
        XCTAssertNil(try LocalConfig.launchOptions(text, appid: "7"))
    }

    func testReplaceTouchesOnlyValue() throws {
        let out = try LocalConfig.setLaunchOptions(text, appid: "546560", to: "C=\"q\" %command%")
        XCTAssertEqual(out, text.replacingOccurrences(of: "A=1 B=\\\"x y\\\" %command%", with: "C=\\\"q\\\" %command%"))
        XCTAssertEqual(try LocalConfig.setLaunchOptions(out, appid: "546560", to: "C=\"q\" %command%"), out)
    }

    func testInsertAndRemove() throws {
        let a = try LocalConfig.setLaunchOptions(text, appid: "7", to: "%command% -x")
        XCTAssertEqual(try LocalConfig.launchOptions(a, appid: "7"), "%command% -x")
        XCTAssertTrue(a.contains("\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"%command% -x\"\n\t\t\t\t\t\t\"Playtime\""))
        XCTAssertEqual(try LocalConfig.setLaunchOptions(a, appid: "7", to: nil), text)
        let b = try LocalConfig.setLaunchOptions(text, appid: "99", to: "Z=1 %command%")
        XCTAssertEqual(try LocalConfig.launchOptions(b, appid: "99"), "Z=1 %command%")
        XCTAssertTrue(b.contains("\t\t\t\t\t\"99\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"Z=1 %command%\"\n\t\t\t\t\t}\n\t\t\t\t}"))
    }
}

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
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macvr-tests-\(UUID().uuidString)")
        let steam = root.appendingPathComponent("Steam")
        ctx = Context(home: root, support: root.appendingPathComponent("macvr"), steamRoot: steam,
                      serverLogDir: root.appendingPathComponent("logs"), runners: root.appendingPathComponent("runners"),
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
            try (f.hasSuffix("ipc-stamp") ? "stamp\n" : f).write(to: u, atomically: true, encoding: .utf8)
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
        for case let u as URL in e where !u.path.contains("/macvr/") && !u.path.contains("macvr-backup") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                out[String(u.path.dropFirst(root.path.count))] = try Data(contentsOf: u)
            }
        }
        return out
    }

    func testInstallIdempotentAndUninstallRoundTrip() throws {
        let before = try snapshot()
        let rep = try MacVR.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(rep.changed.count, 3)
        XCTAssertEqual(rep.changed.first, "template/crossover-1-x86_64-unix")
        let p = Steam(root: ctx.steamRoot).prefixes.first { $0.name == "100" }!
        let reg = try WineRegistry(text: String(contentsOf: p.systemReg, encoding: .utf8))
        XCTAssertEqual(reg.string(Rescan.openxrKey, "ActiveRuntime"), dosPath(ctx.runtimeJSON))
        XCTAssertEqual(reg.string(Rescan.hklmEnvKey, "VR_OVERRIDE"), dosPath(ctx.openCompositeDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.record.path))
        XCTAssertEqual(try String(contentsOf: ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-unix/wineopenxr.so"), encoding: .utf8),
                       "bridge/x86_64-unix/wineopenxr.so")

        let mid = try snapshot()
        let again = try MacVR.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(again.changed, [])
        XCTAssertEqual(try snapshot(), mid)

        let un = MacVR.uninstall(ctx, server: nil)
        XCTAssertEqual(un.busy, [])
        XCTAssertEqual(un.errors, [])
        XCTAssertEqual(try snapshot(), before)
    }

    func testCorrectPrefixIsNotTouched() throws {
        try Deploy.install(ctx, payload: root.appendingPathComponent("payload"))
        var reg = try WineRegistry(text: regText)
        for v in Rescan.desired(ctx) where v.file == "system.reg" { reg.setRaw(v.key, v.name, v.line) }
        let p200 = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/200")
        try reg.text.write(to: p200.appendingPathComponent("pfx/system.reg"), atomically: true, encoding: .utf8)
        let rep = Rescan.run(ctx)
        XCTAssertTrue(rep.unchanged.contains("200"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p200.appendingPathComponent("macvr-vr").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p200.appendingPathComponent("macvr-backup").path))
        // uninstall still removes values that are ours (inherited from the template)
        _ = MacVR.uninstall(ctx, server: nil)
        XCTAssertEqual(try String(contentsOf: p200.appendingPathComponent("pfx/system.reg"), encoding: .utf8), regText)
    }

    func testPreviousValueRestored() throws {
        let sys = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/system.reg")
        var reg = try WineRegistry(text: regText)
        reg.setString(Rescan.openxrKey, "ActiveRuntime", "C:\\other.json", now: Date(timeIntervalSince1970: 1))
        try reg.text.write(to: sys, atomically: true, encoding: .utf8)
        let orig = reg.text
        try MacVR.install(ctx, payload: root.appendingPathComponent("payload"))
        _ = MacVR.uninstall(ctx, server: nil)
        XCTAssertEqual(try String(contentsOf: sys, encoding: .utf8), orig)
    }

    func testModeSwitchVRPath() throws {
        try MacVR.install(ctx, payload: root.appendingPathComponent("payload"))
        try ctx.setSetting("openvr", "vrpath")
        _ = Rescan.run(ctx)
        let f = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath")
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), Rescan.vrpathJSON(ctx))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.path))[.posixPermissions] as? Int, 0o444)
        let reg = try WineRegistry(text: String(contentsOf: f.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("system.reg"), encoding: .utf8))
        XCTAssertNil(reg.string(Rescan.hklmEnvKey, "VR_OVERRIDE"))
        XCTAssertNotNil(reg.string(Rescan.openxrKey, "ActiveRuntime"))
        try ctx.setSetting("openvr", "hklm-env")
        _ = Rescan.run(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testRunnerAddOnly() throws {
        try Deploy.install(ctx, payload: root.appendingPathComponent("payload"))
        let foreign = ctx.runners.appendingPathComponent("crossover-1-fex/CrossOver/lib/wine/x86_64-windows/wineopenxr.dll")
        try "theirs".write(to: foreign, atomically: true, encoding: .utf8)
        let r = try RunnerInstall.ensure(ctx)
        XCTAssertEqual(r.installed, 5)
        XCTAssertEqual(r.foreign, [foreign.path])
        let fex = ctx.runners.appendingPathComponent("crossover-1-fex/CrossOver/lib/wine/x86_64-windows/wineopenxr.so")
        XCTAssertEqual(try String(contentsOf: fex, encoding: .utf8), "bridge/x86_64-unix/wineopenxr.so")
        RunnerInstall.remove(ctx)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "theirs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.runners.appendingPathComponent("crossover-1/CrossOver/lib/wine/x86_64-windows/wineopenxr.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fex.path))
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

    func testLegacyKeptUntilProven() throws {
        let c = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/drive_c")
        try FileManager.default.createDirectory(at: c.appendingPathComponent("macvr/x86_64-unix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c.appendingPathComponent("windows/system32"), withIntermediateDirectories: true)
        try "x".write(to: c.appendingPathComponent("windows/system32/wineopenxr.dll"), atomically: true, encoding: .utf8)
        try "{}".write(to: c.appendingPathComponent("windows/system32/wineopenxr.json"), atomically: true, encoding: .utf8)
        var rep = try MacVR.install(ctx, payload: root.appendingPathComponent("payload"))
        XCTAssertEqual(rep.legacyPending, ["100"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.appendingPathComponent("macvr").path))
        try "p".write(to: Rescan.provenFile(ctx, "100"), atomically: true, encoding: .utf8)
        rep = Rescan.run(ctx)
        XCTAssertEqual(rep.legacyPending, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.appendingPathComponent("macvr").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.appendingPathComponent("windows/system32/wineopenxr.dll").path))
        let rec = Record.load(ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/macvr-vr"))!
        XCTAssertTrue(rec["legacy"]!.hasPrefix("removed:"))
    }

    func testWineCopyOfRunnerBuiltinIsNotLegacy() throws {
        let c = ctx.steamRoot.appendingPathComponent("steamapps/compatdata/100/pfx/drive_c")
        try FileManager.default.createDirectory(at: c.appendingPathComponent("windows/system32"), withIntermediateDirectories: true)
        try "x".write(to: c.appendingPathComponent("windows/system32/wineopenxr.dll"), atomically: true, encoding: .utf8)
        let p = Steam(root: ctx.steamRoot).prefixes.first { $0.name == "100" }!
        XCTAssertEqual(Rescan.legacyItems(p, ctx), [])
    }
}

final class ServerStatusTests: XCTestCase {
    func testParse() {
        let log = """
        WiVRn 26.9 starting
        Client connected
         INFO [client_connected] Client 2 connected
         INFO [ipc_handle_instance_describe_client] Client info:
        \tid: 2
        \tapplication_name: 'OpenComposite_hlvr'
        \tpid: 27676
        """
        var s = ServerStatus.parse(Substring(log))
        XCTAssertTrue(s.headset)
        XCTAssertEqual(s.gameNames, ["hlvr"])
        XCTAssertEqual(s.clientPids[2], 27676)
        s = ServerStatus.parse(Substring(log + "\n INFO [client_disconnected] Client 2 disconnected\n WARN [run_net] Network exception: Error on control socket, Session paused."))
        XCTAssertFalse(s.headset)
        XCTAssertEqual(s.gameNames, [])
        s = ServerStatus.parse(Substring(log + "\nWiVRn 26.9 starting\n"))
        XCTAssertEqual(s, ServerStatus())
    }

    func testWebOverlaysClientIsNotAGame() {
        let log = """
        WiVRn 26.9 starting
        Client connected
         INFO [client_connected] Client 2 connected
        \tapplication_name: 'OpenComposite_hlvr'
        \tpid: 27676
         INFO [client_connected] Client 3 connected
        \tapplication_name: 'MacVR web overlays'
        \tpid: 27700
        """
        let s = ServerStatus.parse(Substring(log))
        XCTAssertEqual(s.gameNames, ["hlvr"])
        XCTAssertEqual(Array(s.clientPids.values), [27676])
    }
}

final class RunnerRegistrationTests: XCTestCase {
    func testScriptNestsKeysAndEscapes() {
        let s = RunnerRegistration.script([
            RegValue(file: "system.reg", key: Rescan.openxrKey, name: "ActiveRuntime", value: "Z:\\a b\\it's 100%.json"),
            RegValue(file: "system.reg", key: Rescan.hklmEnvKey, name: "VR_OVERRIDE", value: "Z:\\oc"),
            RegValue(file: "user.reg", key: Rescan.hkcuEnvKey, name: "VR_LOG_PATH", value: "Z:\\log"),
        ])
        XCTAssertTrue(s.hasPrefix("HKLM\n{\n\tNoRemove 'Software'\n\t{\n\t\tNoRemove 'Khronos'\n"))
        XCTAssertTrue(s.contains("val 'ActiveRuntime' = s 'Z:\\a b\\it''s 100%%.json'\n"))
        XCTAssertTrue(s.contains("NoRemove 'Session Manager'"))
        XCTAssertTrue(s.contains("HKCU\n{\n\tNoRemove 'Environment'\n\t{\n\t\tval 'VR_LOG_PATH' = s 'Z:\\log'\n\t}\n}\n"))
        XCTAssertEqual(s.filter { $0 == "{" }.count, s.filter { $0 == "}" }.count)
    }

    func testFillKeepsSize() throws {
        let region = Data("MACVR-RGS-BEGIN".utf8) + Data(repeating: 0x20, count: 40) + Data("MACVR-RGS-END".utf8)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macvr-logrot-\(UUID().uuidString)")
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
