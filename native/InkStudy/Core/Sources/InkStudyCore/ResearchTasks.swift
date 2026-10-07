import Foundation

public struct ColorQuestion: Codable, Equatable, Sendable, Identifiable {
    public struct Option: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let colors: [String]
    }
    public let id: String
    public let prompt: String
    public let stimulus: [String]
    public let options: [Option]
    public let answer: String
}

public enum ColorExercises {
    public static let names = ["red": "红色", "orange": "橙色", "yellow": "黄色", "green": "绿色", "blue": "蓝色", "violet": "紫色"]
    public static let pairs = [("red", "yellow", "orange"), ("yellow", "blue", "green"), ("blue", "red", "violet")]
    public static func mix(_ first: String, _ second: String) -> String? {
        if first == second { return first }
        return pairs.first { Set([$0.0, $0.1]) == Set([first, second]) }?.2
    }
    public static func wheelScore(_ slots: [String]) -> Int {
        let order = InkColor.palette.map(\.id)
        guard slots.count == 6, Set(slots) == Set(order) else { return 0 }
        return slots.indices.filter { i in
            let index = order.firstIndex(of: slots[i])!
            return Set([slots[(i + 5) % 6], slots[(i + 1) % 6]]) == Set([order[(index + 5) % 6], order[(index + 1) % 6]])
        }.count
    }
    public static func questions(form: String) -> [ColorQuestion] {
        let letter = ["B", "C"].contains(form) ? form : "A"
        let offset = letter == "A" ? 0 : letter == "B" ? 2 : 4
        let object = letter == "A" ? "圆形色卡" : letter == "B" ? "小旗上的色块" : "拼图上的色块"
        let options = InkColor.palette.map { ColorQuestion.Option(id: $0.id, colors: [$0.id]) }
        let secondary = options.filter { ["orange", "green", "violet"].contains($0.id) }
        let pairOptions = pairs.map { ColorQuestion.Option(id: "\($0.0)+\($0.1)", colors: [$0.0, $0.1]) }
        var result: [ColorQuestion] = (0..<4).map { i in
            let color = InkColor.palette[(i + offset) % 6]
            return .init(id: "\(letter)-identify-\(i + 1)", prompt: "请在\(object)中找到\(names[color.id]!)。", stimulus: [],
                         options: seededShuffle(options, seed: "\(letter)-identify-\(i)"), answer: color.id)
        }
        for (index, pair) in seededShuffle(pairs, seed: "\(letter)-mix").enumerated() {
            result.append(.init(id: "\(letter)-mix-forward-\(index + 1)", prompt: "这两种原色颜料混合后，会得到哪种间色？",
                                stimulus: [pair.0, pair.1], options: seededShuffle(secondary, seed: "\(letter)-f-\(index)"), answer: pair.2))
            result.append(.init(id: "\(letter)-mix-reverse-\(index + 1)", prompt: "调出上面的间色，应该选择哪一对原色颜料？",
                                stimulus: [pair.2], options: seededShuffle(pairOptions, seed: "\(letter)-r-\(index)"), answer: "\(pair.0)+\(pair.1)"))
        }
        let applications = letter == "A" ? [0, 1, 2, 0] : letter == "B" ? [1, 2, 0, 1] : [2, 0, 1, 2]
        for (i, index) in applications.enumerated() {
            let pair = pairs[index], forward = i.isMultiple(of: 2)
            result.append(.init(id: "\(letter)-application-\(i + 1)",
                prompt: forward ? "给新的\(object)上色。上面两种原色混合后是什么颜色？" : "要为新\(object)调出上面的间色，应选哪一对原色？",
                stimulus: forward ? [pair.0, pair.1] : [pair.2],
                options: seededShuffle(forward ? secondary : pairOptions, seed: "\(letter)-a-\(i)"), answer: forward ? pair.2 : "\(pair.0)+\(pair.1)"))
        }
        return result
    }
}

public func seededShuffle<T>(_ values: [T], seed text: String) -> [T] {
    var seed: UInt32 = 2_166_136_261
    for code in text.utf16 { seed = (seed ^ UInt32(code)) &* 16_777_619 }
    var result = values
    guard result.count > 1 else { return result }
    for i in stride(from: result.count - 1, through: 1, by: -1) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        result.swapAt(i, Int(seed) % (i + 1))
    }
    return result
}

public struct ResearchPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct ResearchLineTrial: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String
    public let target: Double
    public let reverse: Bool
    public let pressureProfile: PressureProfile?
    public init(id: String, label: String, kind: String, target: Double, reverse: Bool, pressureProfile: PressureProfile? = nil) {
        self.id = id; self.label = label; self.kind = kind; self.target = target; self.reverse = reverse; self.pressureProfile = pressureProfile
    }
    public var background: DrawingBackground { .init(kind: "guide", subject: kind, target: target, reverse: reverse, pressureProfile: pressureProfile) }
    public func targetForce(at progress: Double) -> Double { pressureProfile?.force(at: progress) ?? target }
}

public enum PressureProfile: String, Codable, Sendable, CaseIterable {
    case lightToFirm, firmToLight, lightFirmLight
    public var label: String {
        switch self {
        case .lightToFirm: "从细到粗"
        case .firmToLight: "从粗到细"
        case .lightFirmLight: "细到粗再到细"
        }
    }
    public func force(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .lightToFirm: return 0.15 + 0.35 * t
        case .firmToLight: return 0.50 - 0.35 * t
        case .lightFirmLight: return 0.15 + 0.35 * (1 - abs(2 * t - 1))
        }
    }
}

public enum LineExercises {
    // Native targets are versioned separately from browser force values and await field calibration.
    public static let targets: [(String, Double)] = [("轻", 0.15), ("中", 0.30), ("较重", 0.50)]
    public static func trials(task: ResearchTask) -> [ResearchLineTrial] {
        if task.kind == .pressure {
            if task.phase == .training, task.variant == "pressure-profiles-v2" {
                let steady = targets.enumerated().map { index, target in
                    ResearchLineTrial(id: "\(task.id)-steady-\(index)", label: target.0, kind: "pressure", target: target.1, reverse: false)
                }
                let changing = PressureProfile.allCases.map { profile in
                    ResearchLineTrial(id: "\(task.id)-\(profile.rawValue)", label: profile.label, kind: "pressure",
                        target: profile.force(at: 0), reverse: false, pressureProfile: profile)
                }
                return steady + changing
            }
            return (0..<2).flatMap { repeatIndex in
                seededShuffle(targets, seed: "\(task.form)-\(repeatIndex)").enumerated().map { index, target in
                    .init(id: "\(task.id)-\(repeatIndex)-\(index)", label: target.0, kind: "pressure", target: target.1, reverse: repeatIndex == 1)
                }
            }
        }
        return seededShuffle(["straight", "wave", "circle"], seed: task.form).flatMap { kind in
            (0..<2).map { repeatIndex in
                .init(id: "\(task.id)-\(kind)-\(repeatIndex)", label: kind == "straight" ? "直线" : kind == "wave" ? "波浪线" : "圆形",
                      kind: kind, target: 0.30, reverse: repeatIndex == 1)
            }
        }
    }
    public static func path(kind: String, reverse: Bool = false, width: Double = 1200, height: Double = 850) -> [ResearchPoint] {
        let points: [ResearchPoint] = (0...100).map { index in
            let t = Double(index) / 100
            if kind == "circle" {
                let radius = min(width, height) * 0.30
                return .init(x: width / 2 + radius * cos(t * .pi * 2), y: height / 2 + radius * sin(t * .pi * 2))
            }
            return .init(x: 100 + t * (width - 200), y: height / 2 + (kind == "wave" ? sin(t * .pi * 2) * 135 : 0))
        }
        return reverse ? points.reversed() : points
    }
    public static func metrics(stroke: InkStroke, trial: ResearchLineTrial?) -> [String: Double] {
        let samples = stroke.samples.filter { $0.phase != .ended && $0.phase != .cancelled }
        let pencil = samples.filter { $0.input == .pencil && $0.propertiesExpectingUpdates == 0 && $0.normalizedForce != nil }
        let pressure = pencil.compactMap(\.normalizedForce)
        var result: [String: Double] = ["sampleCount": Double(samples.count), "pencilSampleCount": Double(pencil.count),
                                        "durationSeconds": max(0, (samples.last?.uptime ?? 0) - (samples.first?.uptime ?? 0))]
        if !pressure.isEmpty {
            let mean = pressure.reduce(0, +) / Double(pressure.count)
            result["normalizedForceMean"] = mean
            result["normalizedForceSD"] = sqrt(pressure.reduce(0) { $0 + pow($1 - mean, 2) } / Double(pressure.count))
            result["normalizedForceRange"] = pressure.max()! - pressure.min()!
            if let trial {
                let expected = pencil.map { sample in
                    let progress = min(1, max(0, (sample.x - 100) / 1000))
                    return trial.targetForce(at: trial.reverse ? 1 - progress : progress)
                }
                result["targetNormalizedForce"] = expected.reduce(0, +) / Double(expected.count)
                let errors = zip(pressure, expected).map { $0 - $1 }
                result["signedPressureError"] = errors.reduce(0, +) / Double(errors.count)
                result["pressureMAE"] = errors.reduce(0) { $0 + abs($1) } / Double(errors.count)
                if trial.pressureProfile != nil {
                    result["dynamicPressureTarget"] = 1
                    result["targetForceMinimum"] = expected.min()
                    result["targetForceMaximum"] = expected.max()
                }
            }
        }
        if let trial, !samples.isEmpty {
            let target = path(kind: trial.kind, reverse: trial.reverse)
            let coverage = target.filter { point in samples.contains { hypot($0.x - point.x, $0.y - point.y) < 65 } }.count
            let deviation = samples.reduce(0.0) { sum, point in
                sum + (target.map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? 0)
            } / Double(samples.count) / hypot(1200, 850)
            result["pathCoverage"] = Double(coverage) / Double(target.count)
            result["normalizedPathDeviation"] = deviation
        }
        return result
    }
    public static func valid(metrics: [String: Double], rehearsal: Bool, deviceCheck: Bool = false) -> Bool {
        guard (metrics["sampleCount"] ?? 0) >= (rehearsal ? 2 : 20) else { return false }
        if rehearsal { return true }
        guard (metrics["pencilSampleCount"] ?? 0) >= 20 else { return false }
        return !deviceCheck || (metrics["normalizedForceRange"] ?? 0) > 0.02
    }
}
