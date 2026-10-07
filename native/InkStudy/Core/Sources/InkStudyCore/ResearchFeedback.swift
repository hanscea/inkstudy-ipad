import Foundation

public struct LearningEvidence: Codable, Equatable, Sendable {
    public var task: String
    public var attempts: Int
    public var errorRate: Double = 0
    public var pressureError: Double = 0
    public var pressureSD: Double = 0
    public var pathDeviation: Double = 0
    public var inactivitySeconds: Double = 0
    public var coverage: Double = 1
    public init(task: String, attempts: Int) { self.task = task; self.attempts = attempts }
    public var features: [Double] {
        func clip(_ value: Double, minimum: Double = 0) -> Double { max(minimum, min(1, value)) }
        return ["mix", "wheel", "pressure", "path", "open"].map { task == $0 ? 1.0 : 0.0 } + [
            clip(Double(attempts) / 6), clip(errorRate), clip(pressureError / 0.5, minimum: -1), clip(pressureSD / 0.3),
            clip(pathDeviation / 0.15), clip(inactivitySeconds / 90), clip(coverage)
        ]
    }
}
public struct LearningInference: Codable, Equatable, Sendable {
    public let modelID: String
    public let weightsSHA256: String
    public let trainingSource: String
    public let fieldValidated: Bool
    public let features: [Double]
    public let predictedClass: String
    public let probabilities: [Double]
    public let confidence: Double
    public let threshold: Double
    public var accepted: Bool { confidence >= threshold }
}
public enum LearningModel {
    private struct Artifact: Decodable {
        let modelId: String
        let weightsSha256: String
        let trainingSource: String
        let fieldValidated: Bool
        let classes: [String]
        let weights: [[Double]]
        let threshold: Double
    }
    public static func infer(_ evidence: LearningEvidence) throws -> LearningInference {
        guard evidence.attempts >= 0, [evidence.errorRate, evidence.pressureError, evidence.pressureSD,
            evidence.pathDeviation, evidence.inactivitySeconds, evidence.coverage].allSatisfy(\.isFinite) else {
            throw DrawingError.invalidEvent("invalid_model_evidence")
        }
        guard let url = Bundle.module.url(forResource: "state-model", withExtension: "json") else {
            throw DrawingError.persistence("missing_model_artifact")
        }
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url))
        let features = evidence.features
        guard features.allSatisfy(\.isFinite), ["mix", "wheel", "pressure", "path", "open"].contains(evidence.task),
              artifact.classes.count == artifact.weights.count, artifact.weights.allSatisfy({ $0.count == features.count + 1 && $0.allSatisfy(\.isFinite) }) else {
            throw DrawingError.invalidEvent("invalid_model_features_or_artifact")
        }
        let logits = artifact.weights.map { row in row[0] + zip(row.dropFirst(), features).reduce(0) { $0 + $1.0 * $1.1 } }
        guard let maximum = logits.max() else { throw DrawingError.invalidEvent("empty_model") }
        let values = logits.map { exp($0 - maximum) }, sum = values.reduce(0, +)
        let probabilities = values.map { $0 / sum }
        let index = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] })!
        return .init(modelID: artifact.modelId, weightsSHA256: artifact.weightsSha256, trainingSource: artifact.trainingSource,
                     fieldValidated: artifact.fieldValidated, features: features, predictedClass: artifact.classes[index],
                     probabilities: probabilities, confidence: probabilities[index], threshold: artifact.threshold)
    }
}

public struct ResearchSupport: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let allowed: Bool
    public let trigger: String
    public let promptID: String?
    public let text: String?
    public let level: Int?
    public let adaptive: Bool
    public let reason: String
    public let inference: LearningInference?
    public let libraryVersion: String
    public var multimodal: MultimodalSupport? = nil
}

public enum ResearchFeedback {
    public static let version = "native-prompts-v1-20260910"
    public static let fixed = [
        "你已经完成了一次尝试。再观察一下，然后试试另一种方法。",
        "先停一停，看一看刚才的结果，再决定下一步。",
        "可以把任务分成小步骤，一次只比较一个变化。"
    ]
    private static let prompts: [String: [String]] = [
        "color_relation": ["你已经试过一次了，可以再看看刚才的结果。", "把两种颜色分开比较，再想想它们混合后会出现哪一种间色。", "先确定第一个原色，再寻找能和它组成目标间色的另一个原色。"],
        "wheel_relation": ["色环还可以继续调整，先看看已经摆出的颜色。", "在色环上找找它的两个原色邻居，再决定位置。", "先放好三个原色，再把每个间色放在组成它的两个原色之间。"],
        "pressure_light": ["刚才的一笔已经画完，可以再试一次。", "看看线条结果和目标粗细之间的差别。", "在舒服的范围内一点点调整力度，不需要使劲压屏幕。"],
        "pressure_heavy": ["刚才的一笔已经画完，可以再试一次。", "看看线条结果和目标粗细之间的差别。", "先轻轻落笔，再逐步接近目标，保持舒服的力度。"],
        "pressure_unstable": ["你已经完成一笔，可以停下来观察一下。", "看看这一笔的力度有没有突然变化。", "先找到舒服的力度，再保持手腕和移动节奏稳定。"],
        "path_deviation": ["刚才的路径已经记录，可以再试一笔。", "看看线条在哪一段离开了引导线。", "沿着路径分段观察方向，转弯时慢一点。"],
        "exploration_pause": ["你可以按自己的想法继续。", "可以看看线条之间的距离、方向或粗细。", "下一笔只改变一种画法，再比较两次结果。"],
        "general": ["你可以按自己的想法继续试一试。", "先观察刚才的结果，再决定下一步。", "下一次只改变一个地方，看看有什么不同。"]
    ]
    public static func decide(group: ResearchGroup, phase: ResearchPhase, evidence: LearningEvidence,
                              history: [ResearchSupport], trigger: String = "help_request", at: Date = Date()) -> ResearchSupport {
        let accepted = history.filter(\.allowed)
        func result(allowed: Bool, reason: String, promptID: String? = nil, text: String? = nil,
                    level: Int? = nil, adaptive: Bool = false, inference: LearningInference? = nil) -> ResearchSupport {
            .init(id: UUID(), at: DrawingJSON.wallTime(at), allowed: allowed, trigger: trigger, promptID: promptID,
                  text: text, level: level, adaptive: adaptive, reason: reason, inference: inference, libraryVersion: version)
        }
        guard phase == .training else { return result(allowed: false, reason: "feedback_disabled_outside_training") }
        guard group == .fixed || group == .adaptive else { return result(allowed: false, reason: "no_digital_prompt_for_group") }
        guard evidence.attempts > 0 else { return result(allowed: false, reason: "first_independent_attempt_required") }
        guard accepted.count < 3 else { return result(allowed: false, reason: "prompt_limit_reached") }
        guard accepted.last.map({ at.timeIntervalSince($0.at) >= 15 }) ?? true else { return result(allowed: false, reason: "cooldown_active") }
        let index = accepted.count
        if group == .fixed { return result(allowed: true, reason: trigger, promptID: "fixed-\(index + 1)", text: fixed[index], level: index + 1) }
        do {
            let inference = try LearningModel.infer(evidence)
            guard inference.accepted else {
                return result(allowed: true, reason: "low_model_confidence", promptID: "fallback-fixed-\(index + 1)", text: fixed[index], level: index + 1, inference: inference)
            }
            let selected = inference.predictedClass
            let isColor = ["color_relation", "wheel_relation"].contains(selected)
            let isLine = selected.hasPrefix("pressure_") || selected == "path_deviation"
            if (isColor && !["mix", "wheel"].contains(evidence.task)) || (isLine && !["pressure", "path"].contains(evidence.task)) {
                return result(allowed: true, reason: "model_domain_mismatch", promptID: "fallback-fixed-\(index + 1)", text: fixed[index], level: index + 1, inference: inference)
            }
            return result(allowed: true, reason: trigger, promptID: "\(selected)-\(index + 1)", text: (prompts[selected] ?? fixed)[index],
                          level: index + 1, adaptive: true, inference: inference)
        } catch {
            return result(allowed: true, reason: "model_unavailable", promptID: "fallback-fixed-\(index + 1)", text: fixed[index], level: index + 1)
        }
    }
}
