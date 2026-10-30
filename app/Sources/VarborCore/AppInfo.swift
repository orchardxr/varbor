import Foundation

/// Steam's binary app info cache (`appcache/appinfo.vdf`, versions 40 and 41): what an app's `common` section says
/// about VR, the same fields the WiVRn server patch 0010 reads for the headset's app list.
public struct AppInfo: Equatable {
    public var type = ""
    public var name = ""
    /// The `common` key or category that marked VR support, nil if none.
    public var vrFlag: String?

    static let vrKeys = ["openvrsupport", "openxrsupport", "onlyvrsupport"]
    /// VR Supported, VR Only
    static let vrCategories = ["category_53", "category_54"]

    /// Games and demos with VR support; SteamVR and other tools are excluded by their type.
    public var isVRGame: Bool {
        vrFlag != nil && ["game", "demo"].contains(type.lowercased())
    }

    struct Truncated: Error {}

    /// Entries for `apps` (all apps when nil). Entries whose data doesn't parse are left out.
    public static func read(_ data: Data, apps: Set<UInt32>? = nil) throws -> [UInt32: AppInfo] {
        let d = [UInt8](data)
        var p = 0
        func u32() throws -> UInt32 {
            guard p + 4 <= d.count else { throw Truncated() }
            defer { p += 4 }
            return UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 24
        }
        func u64() throws -> UInt64 { UInt64(try u32()) | UInt64(try u32()) << 32 }
        func cstring() throws -> String {
            guard let end = d[p...].firstIndex(of: 0) else { throw Truncated() }
            defer { p = end + 1 }
            return String(decoding: d[p..<end], as: UTF8.self)
        }

        let magic = try u32()
        guard magic & 0xffff_ff00 == 0x0756_4400, magic & 0xff >= 40 else { throw Truncated() }
        _ = try u32()  // universe
        var table: [String]?
        if magic & 0xff >= 41 {
            let offset = Int(try u64())
            let back = p
            guard offset < d.count else { throw Truncated() }
            p = offset
            let n = try u32()
            table = try (0..<n).map { _ in try cstring() }
            p = back
        }

        var path: [String] = []
        var cur = AppInfo()
        func key() throws -> String {
            guard let table else { return try cstring() }
            let i = Int(try u32())
            guard i < table.count else { throw Truncated() }
            return table[i]
        }
        func value(_ k: String, _ set: Bool) {
            let at = path.map { $0.lowercased() }
            if at == ["appinfo", "common"], vrKeys.contains(k.lowercased()), set, cur.vrFlag == nil {
                cur.vrFlag = k.lowercased()
            } else if at == ["appinfo", "common", "category"], vrCategories.contains(k.lowercased()), set,
                      cur.vrFlag == nil {
                cur.vrFlag = k.lowercased()
            }
        }
        func dict() throws {
            while true {
                guard p < d.count else { throw Truncated() }
                let t = d[p]
                p += 1
                if t == 8 { return }
                let k = try key()
                switch t {
                case 0:
                    path.append(k)
                    try dict()
                    path.removeLast()
                case 1:
                    let s = try cstring()
                    if path.map({ $0.lowercased() }) == ["appinfo", "common"] {
                        if k.lowercased() == "type" { cur.type = s }
                        if k.lowercased() == "name" { cur.name = s }
                    }
                    value(k, !s.isEmpty && s != "0")
                case 2: value(k, try u32() != 0)
                case 3: _ = try u32()
                case 7, 10: _ = try u64()
                default: throw Truncated()
                }
            }
        }

        var out: [UInt32: AppInfo] = [:]
        while true {
            let id = try u32()
            if id == 0 { break }
            let size = Int(try u32())
            let next = p + size
            guard next <= d.count else { throw Truncated() }
            if apps?.contains(id) ?? true {
                // info_state, last_updated, pics_token, SHA1, change number, SHA1 of the binary data
                p += 4 + 4 + 8 + 20 + 4 + 20
                path = []
                cur = AppInfo()
                if (try? dict()) != nil { out[id] = cur }
            }
            p = next
        }
        return out
    }
}
