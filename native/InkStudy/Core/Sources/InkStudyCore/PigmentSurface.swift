import Foundation

/// Versioned, deterministic paint replay. Raw strokes remain the source of truth.
public struct PigmentSurface: Sendable {
    public static let version = "ryb-pigment-v1"
    public static let pressureVersion = "pigment-width-v1"
    public static let pressureFormula = "diameter = brushSize * (0.65 + 0.35 * clamp((force / maximumPossibleForce) / 0.6, 0, 1)); missing force uses display-only normalized force 0.35; deterministic RYB deposition on a 600-pixel-wide surface"
    public let width: Int
    public let height: Int
    public let paperWidth: Double
    public let paperHeight: Double
    public let modelVersion: String
    public private(set) var rgba: [UInt8]
    private var red: [Float]
    private var yellow: [Float]
    private var blue: [Float]
    private var cursor: TouchSample?
    private var untilNext = 3.0
    private var style = BrushStyle()
    private var carried = Array(repeating: SIMD3<Float>(1, 0, 0), count: 5)
    private var remainingDabs: [UUID: Int] = [:]

    public init(paperWidth: Double = 1200, paperHeight: Double = 850, width: Int = 600, modelVersion: String = Self.version) {
        self.paperWidth = paperWidth; self.paperHeight = paperHeight; self.width = width
        self.modelVersion = modelVersion
        height = max(1, Int((Double(width) * paperHeight / paperWidth).rounded()))
        red = Array(repeating: 0, count: width * height); yellow = red; blue = red
        rgba = Array(repeating: 255, count: width * height * 4)
    }

    public init(state: DrawingState) {
        self.init(metadata: state.metadata)
        for stroke in state.visibleStrokes { begin(style: stroke.style, samples: stroke.samples) }
    }

    public init(metadata: DocumentMetadata) {
        self.init(paperWidth: metadata.paperWidth, paperHeight: metadata.paperHeight,
            modelVersion: Self.modelVersion(for: metadata.background))
    }

    public static func modelVersion(for background: DrawingBackground?) -> String {
        background?.pigmentModel ?? version
    }

    public static func palette(for background: DrawingBackground?) -> [InkColor] {
        if background?.kind != "pigment" { return InkColor.palette }
        if modelVersion(for: background) == StandardPalette.mixingVersion { return StandardPalette.primaries }
        return usesSpectralPalette(background) ? InkColor.pigmentPalette : InkColor.legacyPalette
    }

    public static func usesSpectralPalette(_ background: DrawingBackground?) -> Bool {
        [SpectralMixing.version, PaletteMixing.version].contains(modelVersion(for: background))
    }

    public static func formula(for background: DrawingBackground?) -> String {
        if let formula = PaletteMixing.formula(for: modelVersion(for: background)) {
            return "diameter = brushSize * (0.65 + 0.35 * clamp((force / maximumPossibleForce) / 0.6, 0, 1)); missing force uses display-only normalized force 0.35; " + formula
        }
        guard modelVersion(for: background) == SpectralMixing.version else { return pressureFormula }
        return "diameter = brushSize * (0.65 + 0.35 * clamp((force / maximumPossibleForce) / 0.6, 0, 1)); missing force uses display-only normalized force 0.35; 600-pixel-wide spectral-wet-v2 surface, 3-paper-unit dabs, five paint-carrying brush lanes; Spectral.js LUT with barycentric interpolation"
    }

    public mutating func begin(style: BrushStyle, samples: [TouchSample]) {
        self.style = style; cursor = nil; untilNext = 3
        carried = Array(repeating: primary, count: 5)
        append(samples)
    }

    public mutating func append(_ samples: [TouchSample]) {
        guard ["red", "yellow", "blue"].contains(style.color.id) else { return }
        for sample in samples {
            guard let previous = cursor else {
                stamp(x: sample.x, y: sample.y, force: sample.normalizedForce)
                cursor = sample; continue
            }
            let dx = sample.x - previous.x, dy = sample.y - previous.y
            let distance = hypot(dx, dy)
            var along = untilNext
            while along <= distance {
                let t = along / distance
                let f0 = previous.normalizedForce ?? 0.35, f1 = sample.normalizedForce ?? 0.35
                stamp(x: previous.x + dx * t, y: previous.y + dy * t, force: f0 + (f1 - f0) * t,
                    directionX: dx / distance, directionY: dy / distance)
                along += 3
            }
            untilNext = along - distance
            cursor = sample
        }
    }

    private mutating func stamp(x: Double, y: Double, force: Double?, directionX: Double = 1, directionY: Double = 0) {
        if PaletteMixing.supports(modelVersion) {
            paletteStamp(x: x, y: y, force: force, dx: directionX, dy: directionY)
            return
        }
        if modelVersion == SpectralMixing.version {
            wetStamp(x: x, y: y, force: force, dx: directionX, dy: directionY)
            return
        }
        let scale = Double(width) / paperWidth
        let pressure = min(1, max(0, (force ?? 0.35) / 0.6))
        let radius = style.size * (0.65 + 0.35 * pressure) * scale / 2
        let cx = x * scale, cy = y * Double(height) / paperHeight
        let x0 = max(0, Int(floor(cx - radius))), x1 = min(width - 1, Int(ceil(cx + radius)))
        let y0 = max(0, Int(floor(cy - radius))), y1 = min(height - 1, Int(ceil(cy + radius)))
        guard x0 <= x1, y0 <= y1 else { return }
        for py in y0...y1 {
            for px in x0...x1 {
                let distance = hypot(Double(px) + 0.5 - cx, Double(py) + 0.5 - cy) / radius
                guard distance < 1 else { continue }
                let index = py * width + px
                let grain = Float((px * 17 + py * 31 + px * py * 3) % 23) / 23
                let amount = Float(min(1, (1 - distance) * 6)) * (0.09 + grain * 0.025)
                let total = red[index] + yellow[index] + blue[index]
                if total > 4 {
                    let retention = 4 / total
                    red[index] *= retention; yellow[index] *= retention; blue[index] *= retention
                }
                switch style.color.id {
                case "red": red[index] += amount
                case "yellow": yellow[index] += amount
                default: blue[index] += amount
                }
                let mixed = Self.color(red: red[index], yellow: yellow[index], blue: blue[index])
                let opacity = min(1, (red[index] + yellow[index] + blue[index]) * 12)
                let texture = 0.975 + grain * 0.025
                for (channel, value) in [mixed.0, mixed.1, mixed.2].enumerated() {
                    rgba[index * 4 + channel] = UInt8(min(255, max(0, (255 * (1 - opacity) + value * opacity * texture).rounded())))
                }
            }
        }
    }

    private var primary: SIMD3<Float> {
        switch style.color.id {
        case "red": SIMD3(1, 0, 0)
        case "yellow": SIMD3(0, 1, 0)
        default: SIMD3(0, 0, 1)
        }
    }

    public func remainingLoadFraction(for style: BrushStyle) -> Double {
        guard PaletteMixing.supports(modelVersion), let id = style.pigmentLoadID else { return 0 }
        return Double(remainingDabs[id] ?? PaletteMixing.loadDabs) / Double(PaletteMixing.loadDabs)
    }

    public var pigmentMass: SIMD3<Double> {
        SIMD3(red.reduce(0) { $0 + Double($1) }, yellow.reduce(0) { $0 + Double($1) }, blue.reduce(0) { $0 + Double($1) })
    }

    private mutating func paletteStamp(x: Double, y: Double, force: Double?, dx: Double, dy: Double) {
        let scale = Double(width) / paperWidth
        let pressure = min(1, max(0, (force ?? 0.35) / 0.6))
        let radius = max(0.5, style.size * (0.65 + 0.35 * pressure) * scale / 2)
        let cx = x * scale, cy = y * Double(height) / paperHeight
        let x0 = max(0, Int(floor(cx - radius))), x1 = min(width - 1, Int(ceil(cx + radius)))
        let y0 = max(0, Int(floor(cy - radius))), y1 = min(height - 1, Int(ceil(cy + radius)))
        guard x0 <= x1, y0 <= y1 else { return }
        let inverseRadius2 = 1 / (radius * radius)
        var weights: [Float] = []
        weights.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        var weightSum: Float = 0
        for py in y0...y1 {
            for px in x0...x1 {
                let xx = Double(px) + 0.5 - cx, yy = Double(py) + 0.5 - cy
                let edge = Float(max(0, 1 - (xx * xx + yy * yy) * inverseRadius2))
                let weight = edge * edge
                weights.append(weight); weightSum += weight
            }
        }
        guard weightSum > 0 else { return }
        var deposited: Float = 0
        if let id = style.pigmentLoadID {
            let remaining = remainingDabs[id] ?? PaletteMixing.loadDabs
            if remaining > 0 {
                // Quantity follows the fixed simulation grid, not pixel density or frame rate.
                deposited = PaletteMixing.massPerDab * Float(pow(Double(width) / 600, 2)) / weightSum
                remainingDabs[id] = remaining - 1
            }
        }
        if deposited > 0 {
            let color = primary
            var n = 0
            for py in y0...y1 {
                for px in x0...x1 {
                    let index = py * width + px, amount = weights[n] * deposited
                    red[index] += color.x * amount; yellow[index] += color.y * amount; blue[index] += color.z * amount
                    n += 1
                }
            }
        }

        let reach = max(1, radius * 0.22)
        var ox = Int((dx * reach).rounded()), oy = Int((dy * reach).rounded())
        if ox == 0 && oy == 0 { ox = 1 }
        let left = max(0, x0 + min(0, ox)), right = min(width - 1, x1 + max(0, ox))
        let top = max(0, y0 + min(0, oy)), bottom = min(height - 1, y1 + max(0, oy))
        let rowWidth = right - left + 1
        var changes = Array(repeating: SIMD3<Float>.zero, count: rowWidth * (bottom - top + 1))
        var n = 0
        for py in y0...y1 {
            for px in x0...x1 {
                let weight = weights[n]; n += 1
                let qx = px + ox, qy = py + oy
                guard weight > 0, qx >= 0, qx < width, qy >= 0, qy < height else { continue }
                let a = py * width + px, b = qy * width + qx
                let first = SIMD3(red[a], yellow[a], blue[a]), second = SIMD3(red[b], yellow[b], blue[b])
                // Accumulate paired fluxes before applying them, so scan order cannot accelerate transport.
                let flux = first * (weight * 0.26) - second * (weight * 0.08)
                changes[(py - top) * rowWidth + px - left] -= flux
                changes[(qy - top) * rowWidth + qx - left] += flux
            }
        }
        for py in top...bottom {
            for px in left...right {
                let index = py * width + px
                let mass = SIMD3(red[index], yellow[index], blue[index]) + changes[(py - top) * rowWidth + px - left]
                red[index] = mass.x; yellow[index] = mass.y; blue[index] = mass.z
                let opacity = min(1, (mass.x + mass.y + mass.z) * 6)
                let mixed = modelVersion == StandardPalette.mixingVersion ? StandardPalette.color(mass) : SpectralMixing.color(mass)
                let color = SIMD3<Float>(repeating: 255 * (1 - opacity)) + mixed * opacity
                rgba[index * 4] = UInt8(min(255, max(0, color.x.rounded())))
                rgba[index * 4 + 1] = UInt8(min(255, max(0, color.y.rounded())))
                rgba[index * 4 + 2] = UInt8(min(255, max(0, color.z.rounded())))
            }
        }
    }

    private mutating func wetStamp(x: Double, y: Double, force: Double?, dx: Double, dy: Double) {
        let scale = Double(width) / paperWidth
        let pressure = min(1, max(0, (force ?? 0.35) / 0.6))
        let radius = style.size * (0.65 + 0.35 * pressure) * scale / 2
        let cx = x * scale, cy = y * Double(height) / paperHeight
        let x0 = max(0, Int(floor(cx - radius))), x1 = min(width - 1, Int(ceil(cx + radius)))
        let y0 = max(0, Int(floor(cy - radius))), y1 = min(height - 1, Int(ceil(cy + radius)))
        guard x0 <= x1, y0 <= y1 else { return }
        let fresh = primary

        // Lanes pick up the existing wet paint before deposition. Their reservoir
        // travels with the brush, while fresh paint gradually replenishes it.
        for lane in 0..<5 {
            let lateral = Double(lane - 2) * radius * 0.34
            let px = Int((cx - dy * lateral + dx * radius * 0.2).rounded())
            let py = Int((cy + dx * lateral + dy * radius * 0.2).rounded())
            if px >= 0, px < width, py >= 0, py < height {
                let index = py * width + px
                let local = SIMD3(red[index], yellow[index], blue[index])
                let mass = local.x + local.y + local.z
                if mass > 0.02 {
                    let pickup = 0.045 * min(1, mass * 3)
                    carried[lane] = carried[lane] * (1 - pickup) + local / mass * pickup
                }
            }
            carried[lane] = carried[lane] * 0.98 + fresh * 0.02
        }
        let ink = carried.map { $0 * 0.75 + fresh * 0.25 }
        let inverseRadius = 1 / radius
        for py in y0...y1 {
            for px in x0...x1 {
                let xx = (Double(px) + 0.5 - cx) * inverseRadius
                let yy = (Double(py) + 0.5 - cy) * inverseRadius
                let d2 = xx * xx + yy * yy
                guard d2 < 1 else { continue }
                let index = py * width + px
                let grain = Float((px * 17 + py * 31 + px * py * 3) % 23) / 23
                let edge = Float(min(1, (1 - sqrt(d2)) * 4))
                let amount = edge * edge * (3 - 2 * edge) * (0.072 + grain * 0.012)
                let band = min(4, max(0, Float((-dy * xx + dx * yy) / 0.34 + 2)))
                let low = min(3, Int(band)), fraction = band - Float(low)
                let deposit = ink[low] * (1 - fraction) + ink[low + 1] * fraction
                var mass = SIMD3(red[index], yellow[index], blue[index])
                let total = mass.x + mass.y + mass.z
                if total > 1.2 { mass *= 1.2 / total }
                mass += deposit * amount
                red[index] = mass.x; yellow[index] = mass.y; blue[index] = mass.z
                let mixed = SpectralMixing.color(mass)
                let opacity = min(1, (mass.x + mass.y + mass.z) * 6)
                let color = SIMD3<Float>(repeating: 255 * (1 - opacity)) + mixed * (opacity * (0.985 + grain * 0.015))
                rgba[index * 4] = UInt8(min(255, max(0, color.x.rounded())))
                rgba[index * 4 + 1] = UInt8(min(255, max(0, color.y.rounded())))
                rgba[index * 4 + 2] = UInt8(min(255, max(0, color.z.rounded())))
            }
        }
    }

    public var paintedFocus: (x: Double, y: Double)? {
        var xs = 0.0, ys = 0.0, count = 0.0
        for i in red.indices where red[i] + yellow[i] + blue[i] > 0.02 {
            xs += Double(i % width); ys += Double(i / width); count += 1
        }
        guard count > 0 else { return nil }
        let cx = xs / count, cy = ys / count
        var closest = 0, distance = Double.infinity
        // Snap to a painted cell: the center of two separate patches can be blank paper.
        for i in red.indices where red[i] + yellow[i] + blue[i] > 0.02 {
            let d = pow(Double(i % width) - cx, 2) + pow(Double(i / width) - cy, 2)
            if d < distance { closest = i; distance = d }
        }
        return ((Double(closest % width) + 0.5) / Double(width), (Double(closest / width) + 0.5) / Double(height))
    }

    public var metrics: [String: Double] {
        var painted = 0, mixed = 0
        for index in red.indices {
            let total = red[index] + yellow[index] + blue[index]
            guard total > 0.02 else { continue }
            painted += 1
            let colors = (red[index] / total > 0.08 ? 1 : 0) + (yellow[index] / total > 0.08 ? 1 : 0) + (blue[index] / total > 0.08 ? 1 : 0)
            if colors >= 2 { mixed += 1 }
        }
        var result = ["paintedPixels": Double(painted), "mixedPixels": Double(mixed),
            "mixedAreaFraction": painted == 0 ? 0 : Double(mixed) / Double(painted)]
        if PaletteMixing.supports(modelVersion) {
            let mass = pigmentMass, total = mass.x + mass.y + mass.z
            let fractions = total > 0 ? mass / total : .zero
            var variance = 0.0
            for index in red.indices {
                let local = SIMD3(Double(red[index]), Double(yellow[index]), Double(blue[index]))
                let amount = local.x + local.y + local.z
                guard amount > 0 else { continue }
                let difference = local / amount - fractions
                variance += amount * (difference.x * difference.x + difference.y * difference.y + difference.z * difference.z)
            }
            let unit = Double(PaletteMixing.loadMass) * pow(Double(width) / 600, 2)
            result["redPaintUnits"] = mass.x / unit; result["yellowPaintUnits"] = mass.y / unit; result["bluePaintUnits"] = mass.z / unit
            result["pigmentRatioVariance"] = total > 0 ? variance / total : 0
            result["depositedLoadCount"] = Double(remainingDabs.count)
        }
        return result
    }

    public static func color(red: Float, yellow: Float, blue: Float) -> (Float, Float, Float) {
        let maximum = max(red, yellow, blue)
        guard maximum > 0 else { return (255, 255, 255) }
        let r = red / maximum, y = yellow / maximum, b = blue / maximum
        func channel(_ white: Float, _ red: Float, _ yellow: Float, _ orange: Float,
                     _ blue: Float, _ violet: Float, _ green: Float, _ brown: Float) -> Float {
            let noBlue = (white * (1 - r) + red * r) * (1 - y) + (yellow * (1 - r) + orange * r) * y
            let withBlue = (blue * (1 - r) + violet * r) * (1 - y) + (green * (1 - r) + brown * r) * y
            return noBlue * (1 - b) + withBlue * b
        }
        return (channel(255, 219, 237, 232, 40, 119, 61, 103),
                channel(255, 64, 185, 120, 103, 80, 152, 83),
                channel(255, 53, 31, 46, 173, 149, 96, 66))
    }
}
