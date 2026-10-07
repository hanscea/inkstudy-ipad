import Foundation

public enum StandardPalette {
    public static let version = "standard-rgb-v1-20260911"
    public static let mixingVersion = "standard-palette-v4"
    public static let primaryIDs = ["red", "yellow", "blue"]
    public static let targetIDs = ["orange", "green", "violet"]
    public static let primaryNames = ["red": "大红", "yellow": "柠檬黄", "blue": "湖蓝"]
    public static var primaries: [InkColor] { primaryIDs.map { id in InkColor.palette.first { $0.id == id }! } }
    public static func pair(for target: String) -> [String]? {
        switch target {
        case "orange": ["red", "yellow"]
        case "green": ["yellow", "blue"]
        case "violet": ["red", "blue"]
        default: nil
        }
    }
    private static let anchors: [SIMD3<Float>] = InkColor.palette.map {
        let hex = UInt32($0.hex.dropFirst(), radix: 16)!
        return SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255))
    }
    public static let formula = "standard-palette-v4; " + PaletteMixing.transportFormula
        + "; standard-rgb-v1-20260911 sRGB anchors: red #FF0000, yellow #FFFF00, blue #0000FF, orange #FFA500, green #00FF00, violet #800080; normalize local RYB pigment mass; piecewise barycentric interpolation on the primary vertices and equal-pair midpoints of the ratio triangle; equal-pair opaque paint yields the specified secondary; paper coverage blends toward white"

    @inline(__always) public static func color(_ weights: SIMD3<Float>) -> SIMD3<Float> {
        let sum = weights.x + weights.y + weights.z
        guard sum > 0 else { return SIMD3(repeating: 255) }
        let p = weights / sum
        let red = anchors[0], orange = anchors[1], yellow = anchors[2]
        let green = anchors[3], blue = anchors[4], violet = anchors[5]
        // Four triangles share the exact primary and equal-pair color anchors.
        let rgb: SIMD3<Float>
        if p.x >= 0.5 { rgb = red * (2 * p.x - 1) + orange * (2 * p.y) + violet * (2 * p.z) }
        else if p.y >= 0.5 { rgb = yellow * (2 * p.y - 1) + orange * (2 * p.x) + green * (2 * p.z) }
        else if p.z >= 0.5 { rgb = blue * (2 * p.z - 1) + violet * (2 * p.x) + green * (2 * p.y) }
        else { rgb = orange * (1 - 2 * p.z) + green * (1 - 2 * p.x) + violet * (1 - 2 * p.y) }
        return SIMD3(min(255, max(0, rgb.x)), min(255, max(0, rgb.y)), min(255, max(0, rgb.z)))
    }
}
