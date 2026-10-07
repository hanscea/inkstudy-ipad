import Foundation

public enum SpectralMixing {
    public static let version = "spectral-wet-v2"
    public static let sourceSHA256 = "dbaa1a8b44d2c734b48b6d44777b1f182c9740e9220d2cbded02002c8e6d271a"
    private static let divisions = 64
    private static let side = divisions + 1
    private static let table: [SIMD3<Float>] = {
        // Compiled data also works when resuming a drawing without a resource bundle.
        let bytes = SpectralLookupTable.bytes
        return stride(from: 0, to: bytes.count, by: 3).map {
            SIMD3(Float(bytes[$0]), Float(bytes[$0 + 1]), Float(bytes[$0 + 2]))
        }
    }()

    // The spectral calculation is performed offline by the attributed generator.
    // Barycentric interpolation keeps the per-pixel hot path small and continuous.
    @inline(__always) public static func color(_ weights: SIMD3<Float>) -> SIMD3<Float> {
        let sum = weights.x + weights.y + weights.z
        guard sum > 0 else { return SIMD3(repeating: 255) }
        let x = min(Float(divisions), max(0, weights.x / sum * Float(divisions)))
        let y = min(Float(divisions) - x, max(0, weights.y / sum * Float(divisions)))
        let i = Int(x), j = Int(y)
        let fx = x - Float(i), fy = y - Float(j)
        let base = table[i * side + j]
        guard i + j < divisions else { return base }
        let a = table[(i + 1) * side + j], b = table[i * side + j + 1]
        if fx + fy <= 1 { return base * (1 - fx - fy) + a * fx + b * fy }
        let c = table[(i + 1) * side + j + 1]
        return a * (1 - fy) + b * (1 - fx) + c * (fx + fy - 1)
    }
}
