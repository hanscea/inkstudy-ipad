import Foundation

public enum PaletteMixing {
    public static let version = "spectral-palette-v3"
    public static let loadDabs = 50
    public static let massPerDab: Float = 48
    public static let loadMass = Float(loadDabs) * massPerDab
    public static func supports(_ model: String?) -> Bool { model == version || model == StandardPalette.mixingVersion }
    public static let transportFormula = "600-pixel reference grid; fixed 3-paper-unit dabs; brushStyle.pigmentLoadID identifies one finite load of 2400 reference-grid mass units released over 50 in-bounds dabs; reusing an ID never refills it; nil ID means stir only; each color-button tap records a new load ID; unused paint stays off the palette; paired local flux = (0.26 * source - 0.08 * destination) * squared radial weight, applied simultaneously across a 0.22-brush-radius offset; no evaporation or mass cap"
    public static let formula = "spectral-palette-v3; " + transportFormula + "; Spectral.js LUT maps local pigment ratios to color"
    public static func formula(for model: String?) -> String? {
        if model == StandardPalette.mixingVersion { return StandardPalette.formula }
        return model == version ? formula : nil
    }
}
