import Foundation

public enum HintStrategy: String, Codable, CaseIterable, Sendable {
    case mixObserve = "mix_observe", mixAddRed = "mix_add_red", mixAddYellow = "mix_add_yellow"
    case mixAddBlue = "mix_add_blue", mixStir = "mix_stir", mixCompare = "mix_compare"
    case pressureObserve = "pressure_observe", pressureLighter = "pressure_lighter"
    case pressureFirmer = "pressure_firmer", pressureSteady = "pressure_steady"
    case pressureFollow = "pressure_follow", pressurePencil = "pressure_pencil"

    public var text: String {
        switch self {
        case .mixObserve: "看看两种颜色碰到一起的地方。"
        case .mixAddRed: "蘸一点红色，涂到已有的颜色上。"
        case .mixAddYellow: "蘸一点黄色，涂到已有的颜色上。"
        case .mixAddBlue: "蘸一点蓝色，涂到已有的颜色上。"
        case .mixStir: "点“只搅拌”，在颜料上慢慢转圈。"
        case .mixCompare: "看看调出的颜色，再看看目标色。"
        case .pressureObserve: "看看刚画的线，再看看目标线。"
        case .pressureLighter: "下一条轻一点，不用使劲压。"
        case .pressureFirmer: "下一条稍加一点力，手要舒服。"
        case .pressureSteady: "慢慢画，让手上的力气稳一点。"
        case .pressureFollow: "跟着目标线，试试力气怎样变。"
        case .pressurePencil: "用画笔试一条，才能看到力气的变化。"
        }
    }
    public var colorID: String? {
        switch self { case .mixAddRed: "red"; case .mixAddYellow: "yellow"; case .mixAddBlue: "blue"; default: nil }
    }
}

/// Local provenance and normalized measurements. Only `summary` is sent to the model gateway.
public struct HintEvidence: Codable, Equatable, Sendable {
    public let drawingID: UUID
    public let drawingSequence: Int
    public let task: String
    public let target: String
    public let strokeCount: Int
    public let metrics: [String: Double]
    public let focusX: Double
    public let focusY: Double
    public init(drawingID: UUID, drawingSequence: Int, task: String, target: String, strokeCount: Int,
                metrics: [String: Double], focusX: Double = 0.5, focusY: Double = 0.5) {
        self.drawingID = drawingID; self.drawingSequence = drawingSequence; self.task = task
        self.target = target; self.strokeCount = strokeCount; self.metrics = metrics
        self.focusX = focusX; self.focusY = focusY
    }
    public static let metricKeys: Set<String> = ["redPaintUnits", "yellowPaintUnits", "bluePaintUnits", "mixedAreaFraction",
        "pigmentRatioVariance", "signedPressureError", "pressureMAE", "normalizedForceSD", "pencilSampleCount", "sampleCount", "dynamicPressureTarget"]
    public var valid: Bool {
        ["mix", "pressure"].contains(task) && drawingSequence > 0 && strokeCount > 0 && strokeCount <= 100_000 &&
        !target.isEmpty && target.count <= 60 && metrics.keys.allSatisfy(Self.metricKeys.contains) &&
        metrics.values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) &&
        focusX.isFinite && focusY.isFinite && (0...1).contains(focusX) && (0...1).contains(focusY) &&
        (task != "mix" || StandardPalette.pair(for: target) != nil)
    }
    public var summary: HintSummary { .init(task: task, target: target, strokeCount: strokeCount, metrics: metrics) }
}

public struct HintSummary: Codable, Equatable, Sendable {
    public let task: String
    public let target: String
    public let strokeCount: Int
    public let metrics: [String: Double]
}

public struct MultimodalSupport: Codable, Equatable, Sendable {
    public let strategy: HintStrategy
    public let evidence: HintEvidence
    public let source: String
    public let model: String?
    public let requestID: UUID?
    public let latencyMilliseconds: Int?
    public let fallbackReason: String?
}

public enum HintDeliveryKind: String, Codable, Sendable {
    case displayed, audioStarted, audioFinished, audioStopped, audioFailed, dismissed
}

public enum MultimodalFeedback {
    public static let version = "multimodal-preview-v1-20260917"
    public static func enabled(_ configuration: ResearchConfiguration) -> Bool {
        configuration.hintProtocolVersion == version && configuration.purpose == .rehearsal && configuration.visit == .practice &&
        [.mix, .pressure].contains(configuration.practiceKind)
    }
    public static func fixed(task: String, level: Int) -> HintStrategy {
        let items: [HintStrategy] = task == "mix" ? [.mixObserve, .mixStir, .mixCompare] : [.pressureObserve, .pressureFollow, .pressureSteady]
        return items[min(2, max(0, level - 1))]
    }
    public static func candidates(_ e: HintEvidence) -> [HintStrategy] {
        if e.task == "mix", let pair = StandardPalette.pair(for: e.target) {
            let amounts = pair.map { max(0, e.metrics[$0 + "PaintUnits"] ?? 0) }
            let add: (String) -> HintStrategy = { $0 == "red" ? .mixAddRed : $0 == "yellow" ? .mixAddYellow : .mixAddBlue }
            if amounts[0] < 0.02 && amounts[1] >= 0.02 { return [add(pair[0]), .mixObserve] }
            if amounts[1] < 0.02 && amounts[0] >= 0.02 { return [add(pair[1]), .mixObserve] }
            if amounts[0] + amounts[1] < 0.04 { return [.mixObserve] }
            if (e.metrics["mixedAreaFraction"] ?? 0) < 0.65 || (e.metrics["pigmentRatioVariance"] ?? 1) > 0.08 {
                return [.mixStir, .mixObserve]
            }
            if amounts[0] > amounts[1] * 2 { return [add(pair[1]), .mixCompare] }
            if amounts[1] > amounts[0] * 2 { return [add(pair[0]), .mixCompare] }
            return [.mixCompare, .mixObserve]
        }
        guard (e.metrics["pencilSampleCount"] ?? 0) >= 8 else { return [.pressurePencil, .pressureObserve] }
        if (e.metrics["dynamicPressureTarget"] ?? 0) == 1 { return [.pressureFollow, .pressureObserve] }
        let error = e.metrics["signedPressureError"] ?? 0
        if error > 0.10 { return [.pressureLighter, .pressureObserve] }
        if error < -0.10 { return [.pressureFirmer, .pressureObserve] }
        if (e.metrics["normalizedForceSD"] ?? 0) > 0.12 { return [.pressureSteady, .pressureObserve] }
        return [.pressureObserve, .pressureSteady]
    }
    public static func blockReason(phase: ResearchPhase, group: ResearchGroup, evidence: HintEvidence?, history: [ResearchSupport], at: Date) -> String? {
        guard phase == .training, [.fixed, .adaptive].contains(group) else { return "feedback_disabled_outside_training" }
        guard evidence?.valid == true else { return "first_independent_attempt_required" }
        let accepted = history.filter(\.allowed)
        guard accepted.count < 3 else { return "prompt_limit_reached" }
        guard accepted.last.map({ at.timeIntervalSince($0.at) >= 15 }) ?? true else { return "cooldown_active" }
        return nil
    }
    public static func support(evidence: HintEvidence, group: ResearchGroup, level: Int, strategy: HintStrategy,
                               source: String, trigger: String, at: Date = Date(), model: String? = nil,
                               requestID: UUID? = nil, latencyMilliseconds: Int? = nil, fallbackReason: String? = nil) -> ResearchSupport {
        .init(id: UUID(), at: DrawingJSON.wallTime(at), allowed: true, trigger: trigger,
            promptID: strategy.rawValue + "-\(level)", text: strategy.text, level: level,
            adaptive: group == .adaptive, reason: fallbackReason ?? trigger, inference: nil, libraryVersion: version,
            multimodal: .init(strategy: strategy, evidence: evidence, source: source, model: model, requestID: requestID,
                latencyMilliseconds: latencyMilliseconds, fallbackReason: fallbackReason))
    }
}
