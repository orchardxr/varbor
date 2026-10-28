import CMacVRXR
import Foundation
import simd

struct PixelRect: Equatable {
    var x, y, w, h: Int
}

struct ScenePanel {
    var debugName: String
    var rect: PixelRect
    var quad: mxr_quad
    var rectKey: Int { rect.x &* 73856093 ^ rect.y &* 19349663 ^ rect.w &* 83492791 ^ rect.h }
}

struct SceneRenderModel {
    var source: String
    var transform: simd_float4x4
    var color: SIMD3<Float>
    var opacity: Float
    var properties: [String: Any]
}

// SteamVR's scene graph (vsg nodes from the page's SGApp, via VRHTML.UpdateSceneGraph). The root is in the standing
// (STAGE) universe. Panels show the rect uv_min..uv_max of the page with width/height in metres (one of them may be
// derived from the rect's aspect), centred at -origin * size / 2 in their node's frame.
struct SceneGraph {
    var panels = [ScenePanel]()
    var renderModels = [SceneRenderModel]()
    private static var warned = Set<String>()

    init(root: [String: Any], pageWidth: Int, pageHeight: Int) {
        walk(root, matrix_identity_float4x4, 1, SIMD3<Float>(1, 1, 1), pageWidth, pageHeight)
    }

    private mutating func walk(_ node: [String: Any], _ parent: simd_float4x4, _ opacity: Float, _ tint: SIMD3<Float>,
                               _ pw: Int, _ ph: Int) {
        let type = node["type"] as? String ?? "transform"
        let p = node["properties"] as? [String: Any] ?? [:]
        var m = parent
        var op = opacity
        var color = tint
        switch type {
        case "transform":
            for k in ["parent-path", "parent-id"] where p[k] != nil {
                SceneGraph.warnOnce("transform \(k) \(p[k]!) not supported, using the parent node")
            }
            if let o = p["parent-origin"] as? String, o != "Standing" {
                SceneGraph.warnOnce("transform parent-origin \(o) treated as Standing")
            }
            m = parent * SceneGraph.trs(p)
        case "opacity":
            op *= Float(SceneGraph.number(p["opacity"]) ?? 1)
        case "tint":
            color *= SceneGraph.color(p["color"])
        case "panel":
            if let panel = SceneGraph.panel(p, m, op, color, pw, ph) { panels.append(panel) }
        case "rendermodel":
            if let src = p["source"] as? String {
                renderModels.append(SceneRenderModel(source: src, transform: m, color: color, opacity: op, properties: p))
            }
        case "texture":
            break
        default:
            SceneGraph.warnOnce("scene graph node \(type) ignored")
        }
        for c in node["children"] as? [[String: Any]] ?? [] { walk(c, m, op, color, pw, ph) }
    }

    static func warnOnce(_ s: String) {
        if warned.insert(s).inserted { log(s) }
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func floats(_ v: Any?) -> [Float]? {
        guard let a = v as? [Any] else { return nil }
        let f = a.compactMap { number($0) }.map { Float($0) }
        return f.count == a.count ? f : nil
    }

    static func color(_ v: Any?) -> SIMD3<Float> {
        if let s = v as? String, s.hasPrefix("#"), s.count >= 7, let n = UInt32(s.dropFirst().prefix(6), radix: 16) {
            return SIMD3(Float((n >> 16) & 255), Float((n >> 8) & 255), Float(n & 255)) / 255
        }
        if let f = floats(v), f.count >= 3 {
            let c = SIMD3(f[0], f[1], f[2])
            return c.max() > 1 ? c / 255 : c
        }
        return SIMD3(1, 1, 1)
    }

    static func trs(_ p: [String: Any]) -> simd_float4x4 {
        let t = floats(p["translation"]) ?? [0, 0, 0]
        let r = floats(p["rotation"]) ?? [1, 0, 0, 0] // w x y z
        let s = floats(p["scale"]) ?? [1, 1, 1]
        var m = matrix_identity_float4x4
        if r.count == 4 {
            let q = simd_quatf(ix: r[1], iy: r[2], iz: r[3], r: r[0])
            m = simd_float4x4(q.length > 0 ? q.normalized : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        }
        if s.count == 3 {
            m.columns.0 *= s[0]
            m.columns.1 *= s[1]
            m.columns.2 *= s[2]
        }
        if t.count == 3 { m.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
        return m
    }

    static func panel(_ p: [String: Any], _ m: simd_float4x4, _ opacity: Float, _ tint: SIMD3<Float>,
                      _ pw: Int, _ ph: Int) -> ScenePanel? {
        guard let uv0 = floats(p["uv_min"]), let uv1 = floats(p["uv_max"]), uv0.count == 2, uv1.count == 2 else {
            return nil
        }
        let x0 = Int((uv0[0] * Float(pw)).rounded()), y0 = Int((uv0[1] * Float(ph)).rounded())
        let x1 = Int((uv1[0] * Float(pw)).rounded()), y1 = Int((uv1[1] * Float(ph)).rounded())
        let rect = PixelRect(x: max(0, x0), y: max(0, y0), w: min(pw, x1) - max(0, x0), h: min(ph, y1) - max(0, y0))
        guard rect.w > 0, rect.h > 0 else { return nil }
        let aspect = Float(rect.h) / Float(rect.w)
        var w = number(p["width"]).map { Float($0) }
        var h = number(p["height"]).map { Float($0) }
        if w == nil, let h0 = h { w = h0 / aspect }
        if h == nil, let w0 = w { h = w0 * aspect }
        guard var width = w, var height = h else {
            warnOnce("panel without width/height (target-dpi-panel-id / render model panels) not supported")
            return nil
        }
        let origin = floats(p["origin"]) ?? [0, 0]
        let local = SIMD4<Float>(-origin[0] * width / 2, -origin[1] * height / 2, 0, 1)
        let pos = m * local
        let sx = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        width *= sx
        height *= sy
        let rot = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / max(sx, 1e-6),
                                SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / max(sy, 1e-6),
                                SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / max(sz, 1e-6))
        let q = simd_quatf(rot).normalized
        let a = max(0, min(1, opacity))
        var quad = mxr_quad()
        quad.position = (pos.x, pos.y, pos.z)
        quad.orientation = (q.imag.x, q.imag.y, q.imag.z, q.real)
        quad.width = width
        quad.height = height
        quad.rect = (Int32(rect.x), Int32(rect.y), Int32(rect.w), Int32(rect.h))
        quad.color_scale = (tint.x * a, tint.y * a, tint.z * a, a)
        let name = (p["debug_name"] as? String) ?? (p["id"] as? String) ?? "panel\(number(p["sgid"]).map { Int($0) } ?? 0)"
        return ScenePanel(debugName: name, rect: rect, quad: quad)
    }
}
