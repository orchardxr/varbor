import Foundation
@testable import MacVRCore
import XCTest

/// Writes appinfo.vdf like Steam: v41 keys go through a string table at the end, v40 keys are inline.
private struct AppInfoWriter {
    enum V { case s(String), u(UInt32), u64(UInt64), d([(String, V)]) }

    let version: UInt8
    var table: [String] = []
    var apps = Data()

    init(version: UInt8) { self.version = version }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    mutating func key(_ k: String) -> Data {
        guard version >= 41 else { return Data(k.utf8) + [0] }
        if !table.contains(k) { table.append(k) }
        return Self.le32(UInt32(table.firstIndex(of: k)!))
    }

    mutating func dict(_ items: [(String, V)]) -> Data {
        var out = Data()
        for (k, v) in items {
            switch v {
            case .s(let s): out += [1] + key(k) + Data(s.utf8) + [0]
            case .u(let u): out += [2] + key(k) + Self.le32(u)
            case .u64(let u): out += [7] + key(k) + Self.le64(u)
            case .d(let d): out += [0] + key(k) + dict(d)
            }
        }
        return out + [8]
    }

    mutating func add(_ id: UInt32, common: [(String, V)]) {
        let body = Data(repeating: 0xab, count: 60) + dict([("appinfo", .d([("appid", .u(id)), ("common", .d(common))]))])
        apps += Self.le32(id) + Self.le32(UInt32(body.count)) + body
    }

    func data() -> Data {
        var head = Self.le32(0x0756_4400 | UInt32(version)) + Self.le32(1)
        let tail = apps + Self.le32(0)
        guard version >= 41 else { return head + tail }
        head += Self.le64(UInt64(head.count + 8 + tail.count))
        return head + tail + Self.le32(UInt32(table.count)) + table.reduce(Data()) { $0 + Data($1.utf8) + [0] }
    }
}

final class AppInfoTests: XCTestCase {
    func sample(version: UInt8) -> Data {
        var w = AppInfoWriter(version: version)
        w.add(546560, common: [("name", .s("Half-Life: Alyx")), ("type", .s("Game")), ("openvrsupport", .s("1")),
                               ("onlyvrsupport", .u(1)), ("size", .u64(1 << 40))])
        w.add(250820, common: [("name", .s("SteamVR")), ("type", .s("Tool")),
                               ("category", .d([("category_53", .u(1))]))])
        w.add(1000001, common: [("name", .s("Flat Game")), ("type", .s("Game")),
                                ("controllervr", .d([("steamvr", .u(1))])), ("openvrsupport", .s("0"))])
        w.add(739630, common: [("name", .s("Phasmophobia")), ("type", .s("game")),
                               ("category", .d([("category_2", .u(1)), ("category_53", .u(1))]))])
        return w.data()
    }

    func testVRGamesV41() throws {
        let info = try AppInfo.read(sample(version: 41))
        XCTAssertEqual(info.count, 4)
        XCTAssertEqual(info[546560], AppInfo(type: "Game", name: "Half-Life: Alyx", vrFlag: "openvrsupport"))
        XCTAssertTrue(info[546560]!.isVRGame)
        XCTAssertEqual(info[250820]?.vrFlag, "category_53")
        XCTAssertFalse(info[250820]!.isVRGame)
        XCTAssertNil(info[1000001]?.vrFlag)
        XCTAssertFalse(info[1000001]!.isVRGame)
        XCTAssertTrue(info[739630]!.isVRGame)
    }

    func testV40InlineKeysAndFilter() throws {
        let info = try AppInfo.read(sample(version: 40), apps: [546560, 250820])
        XCTAssertEqual(Set(info.keys), [546560, 250820])
        XCTAssertTrue(info[546560]!.isVRGame)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try AppInfo.read(Data("not appinfo".utf8)))
        let d = sample(version: 41)
        XCTAssertThrowsError(try AppInfo.read(d.prefix(d.count / 2)))
    }

    func testSteamVRGamesUsesAppInfoThenDLL() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macvr-appinfo-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let sa = root.appendingPathComponent("steamapps")
        for (id, dir) in [("546560", "Alyx"), ("250820", "SteamVR"), ("1000001", "Flat"), ("42", "Unknown")] {
            try fm.createDirectory(at: sa.appendingPathComponent("common/\(dir)/bin"), withIntermediateDirectories: true)
            try "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(dir)\"\n\t\"installdir\"\t\t\"\(dir)\"\n}\n"
                .write(to: sa.appendingPathComponent("appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        // in appinfo as flat: the DLL doesn't matter; 42 isn't in appinfo: the DLL decides
        try Data().write(to: sa.appendingPathComponent("common/Flat/bin/openvr_api.dll"))
        try Data().write(to: sa.appendingPathComponent("common/Unknown/bin/openvr_api.dll"))
        try fm.createDirectory(at: root.appendingPathComponent("appcache"), withIntermediateDirectories: true)
        try sample(version: 41).write(to: root.appendingPathComponent("appcache/appinfo.vdf"))

        let games = Steam(root: root).vrGames().map { "\($0.0.appid) \($0.1)" }
        XCTAssertEqual(games, ["42 bin/openvr_api.dll", "546560 appinfo openvrsupport"])
    }
}
