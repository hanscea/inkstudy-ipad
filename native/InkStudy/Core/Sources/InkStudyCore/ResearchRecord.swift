import Foundation

public enum ResearchAction: Codable, Equatable, Sendable {
    case entered
    case draft(key: String, value: String)
    case answered(questionID: String, value: String, metrics: [String: Double])
    case drawingLinked(ResearchDrawingReference)
    case drawingFinished(id: UUID, strokeID: UUID?, valid: Bool, metrics: [String: Double], reason: String?)
    case feedback(ResearchSupport)
    case hintObserved(HintEvidence)
    case hintDelivered(feedbackID: UUID, kind: HintDeliveryKind)
    case narrationRequested(text: String, kind: NarrationKind, feedbackID: UUID?, voiceID: String)
    case helpStarted(kind: OperatorHelpKind, operatorCode: String)
    case helpFinished
    case taskCompleted
    case paused
    case resumed
    case stopped(ResearchEndReason)
}
public struct ResearchEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int
    public let taskID: String
    public let at: Date
    public let action: ResearchAction
    public init(id: UUID = UUID(), sequence: Int, taskID: String, at: Date = Date(), action: ResearchAction) {
        self.id = id; self.sequence = sequence; self.taskID = taskID; self.at = DrawingJSON.wallTime(at); self.action = action
    }
}
public struct ResearchActivity: Sendable {
    public let task: ResearchTask
    public var beganAt: Date?
    public var finishedAt: Date?
    public var drafts: [String: String] = [:]
    public var responses: [ResearchResponse] = []
    public var drawings: [ResearchDrawingReference] = []
    public var feedback: [ResearchSupport] = []
    public var narrations: [ResearchNarration] = []
    public var hintEvidence: HintEvidence?
    public var selectedTrials: [String: UUID] = [:]
    public var latestMetrics: [String: Double] { drawings.last(where: \.finished)?.metrics ?? responses.last?.metrics ?? [:] }
    public var attemptCount: Int { task.kind == .mix ? responses.count : responses.count + drawings.filter(\.finished).count }
}
public struct ResearchRecord: Codable, Equatable, Sendable, Identifiable {
    public let format: String
    public let configuration: ResearchConfiguration
    public var events: [ResearchEvent]
    public var id: UUID { configuration.id }
    public init(configuration: ResearchConfiguration, events: [ResearchEvent] = []) {
        format = "inkstudy-research-v1"; self.configuration = configuration; self.events = events
    }
    public func replay() throws -> ResearchState {
        guard format == "inkstudy-research-v1", ResearchProtocol.supportedVersions.contains(configuration.protocolVersion) else {
            throw DrawingError.invalidEvent("不支持的研究记录版本；原文件保留。")
        }
        var state = ResearchState(configuration: configuration)
        var ids = Set<UUID>()
        for event in events {
            guard ids.insert(event.id).inserted else { throw DrawingError.invalidEvent("重复的研究事件。") }
            try state.apply(event)
        }
        return state
    }
}
public struct ResearchState: Sendable {
    public let configuration: ResearchConfiguration
    public var activities: [ResearchActivity]
    public private(set) var currentIndex = 0
    public private(set) var lastSequence = 0
    public private(set) var isPaused = false
    public private(set) var endReason: ResearchEndReason?
    public private(set) var endedAt: Date?
    public private(set) var helps: [OperatorHelpRecord] = []
    public var current: ResearchActivity? { activities.indices.contains(currentIndex) ? activities[currentIndex] : nil }
    public var activeHelp: OperatorHelpRecord? { helps.last.flatMap { $0.endedAt == nil ? $0 : nil } }
    public var allDrawingIDs: [UUID] { activities.flatMap { $0.drawings.map(\.id) } }
    public init(configuration: ResearchConfiguration) {
        self.configuration = configuration
        activities = ResearchProtocol.tasks(for: configuration).map { .init(task: $0) }
    }
    public var completionProblem: String? {
        guard let a = current else { return nil }
        switch a.task.kind {
        case .knowledge:
            return Set(a.responses.map(\.questionID)).count == ColorExercises.questions(form: a.task.form).count ? nil : "请完成所有色卡选择。"
        case .mix:
            return Set(a.responses.map(\.questionID)).isSuperset(of: ["orange", "green", "violet"]) ? nil : "请分别尝试三种目标间色。"
        case .wheel: return a.responses.isEmpty ? "请摆放六种颜色并检查一次。" : nil
        case .pressure, .path:
            let done = Set(a.selectedTrials.keys)
            return LineExercises.trials(task: a.task).allSatisfy { done.contains($0.id) } ? nil : "每条引导线至少需要一次有效记录；演练可用手指预览。"
        case .device, .coloring, .emotion, .creation:
            return a.drawings.contains(where: { $0.finished && $0.valid == true }) ? nil : "请先保存这次绘画记录。"
        case .familiarization: return a.drafts["assent"] == "yes" && a.drafts["familiarized"] == "yes" ? nil : "请记录儿童同意与设备熟悉；不同意时结束访次。"
        case .interview:
            return ["meaning", "choices", "change"].allSatisfy { !(a.drafts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? nil : "请记录三项谈话；未作答时填写“未作答”。"
        case .experience:
            let choices = ["enjoyment": ["有趣", "一般", "没意思", "未作答"], "difficulty": ["容易", "有点难", "很难", "未作答"], "again": ["想", "不确定", "不想", "未作答"]]
            return choices.allSatisfy { $0.value.contains(a.drafts[$0.key] ?? "") } ? nil : "请记录三项体验选择，可选未作答。"
        case .paper:
            return a.drafts["paperCompleted"] == "yes" && ["teacherCode", "paperArtifactCode", "implementationNotes"].allSatisfy {
                !(a.drafts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ? nil : "请完整记录教师、纸本作品编号和实施情况；提前停止须登记停止。"
        case .transition, .rest: return nil
        }
    }

    public mutating func apply(_ event: ResearchEvent) throws {
        guard event.sequence == lastSequence + 1, let activity = current, event.taskID == activity.task.id,
              endReason == nil, event.at.timeIntervalSince1970.isFinite else { throw DrawingError.invalidEvent("研究事件顺序或任务状态不一致。") }
        if isPaused {
            switch event.action {
            case .resumed, .stopped, .helpFinished: break
            default: throw DrawingError.invalidEvent("请先恢复访次。")
            }
        }
        switch event.action {
        case .entered:
            if activities[currentIndex].beganAt == nil { activities[currentIndex].beganAt = event.at }
        case .draft(let key, let value):
            guard key.count <= 80, value.count <= 3000 else { throw DrawingError.invalidEvent("记录过长。") }
            activities[currentIndex].drafts[key] = value
        case let .answered(questionID, value, metrics):
            guard value.count <= 3000, metrics.values.allSatisfy(\.isFinite) else { throw DrawingError.invalidEvent("回答无效。") }
            var correct: Bool?
            switch activity.task.kind {
            case .knowledge:
                guard let question = ColorExercises.questions(form: activity.task.form).first(where: { $0.id == questionID }),
                      question.options.contains(where: { $0.id == value }), !activity.responses.contains(where: { $0.questionID == questionID }) else {
                    throw DrawingError.invalidEvent("色彩题须记录首次独立回答。")
                }
                correct = question.answer == value
            case .mix:
                let parts = value.split(separator: "+").map(String.init)
                guard ["orange", "green", "violet"].contains(questionID), parts.count == 2,
                      parts.allSatisfy({ ["red", "yellow", "blue"].contains($0) }) else { throw DrawingError.invalidEvent("调色选项无效。") }
                correct = ColorExercises.mix(parts[0], parts[1]) == questionID
            case .wheel:
                let slots = value.split(separator: ",").map(String.init)
                guard slots.count == 6, Set(slots) == Set(InkColor.palette.map(\.id)) else { throw DrawingError.invalidEvent("请把六种颜色各放一次。") }
                correct = ColorExercises.wheelScore(slots) == 6
            default: throw DrawingError.invalidEvent("此任务不接收选择题回答。")
            }
            activities[currentIndex].responses.append(.init(id: event.id, questionID: questionID, value: value, correct: correct, metrics: metrics, at: event.at))
        case .drawingLinked(let reference):
            guard activity.task.kind.isDrawing, !allDrawingIDs.contains(reference.id), !reference.finished else { throw DrawingError.invalidEvent("绘画关联无效。") }
            if [.pressure, .path].contains(activity.task.kind) {
                guard LineExercises.trials(task: activity.task).contains(where: { $0.id == reference.trialID }),
                      activity.task.phase == .training || activity.selectedTrials[reference.trialID] == nil else {
                    throw DrawingError.invalidEvent("测量已固定首次有效笔迹，不能替换为后续更好的结果。")
                }
            }
            activities[currentIndex].drawings.append(reference)
        case let .drawingFinished(id, strokeID, valid, metrics, reason):
            guard let index = activity.drawings.firstIndex(where: { $0.id == id }), !activity.drawings[index].finished,
                  metrics.values.allSatisfy(\.isFinite) else { throw DrawingError.invalidEvent("绘画结果不能重复覆盖。") }
            activities[currentIndex].drawings[index].finished = true
            activities[currentIndex].drawings[index].selectedStrokeID = strokeID
            activities[currentIndex].drawings[index].valid = valid
            activities[currentIndex].drawings[index].metrics = metrics
            activities[currentIndex].drawings[index].reason = reason
            if valid && activities[currentIndex].selectedTrials[activity.drawings[index].trialID] == nil {
                activities[currentIndex].selectedTrials[activity.drawings[index].trialID] = id
            }
        case .hintObserved(let evidence):
            guard MultimodalFeedback.enabled(configuration), activity.task.phase == .training,
                  evidence.valid, evidence.task == activity.task.kind.rawValue,
                  activity.drawings.contains(where: { $0.id == evidence.drawingID }), activeHelp == nil else {
                throw DrawingError.invalidEvent("提示观察数据无效。")
            }
            activities[currentIndex].hintEvidence = evidence
        case let .hintDelivered(feedbackID, _):
            guard MultimodalFeedback.enabled(configuration), activity.feedback.contains(where: { $0.id == feedbackID && $0.allowed }) else {
                throw DrawingError.invalidEvent("没有可关联的提示。")
            }
        case .feedback(let support):
            if support.allowed {
                let previous = activity.feedback.filter(\.allowed)
                let modern = MultimodalFeedback.enabled(configuration)
                guard activity.task.phase == .training, [.fixed, .adaptive].contains(configuration.group),
                      modern ? activity.hintEvidence?.valid == true : activity.attemptCount > 0,
                      previous.count < 3, previous.last.map({ support.at.timeIntervalSince($0.at) >= 15 }) ?? true,
                      support.level == previous.count + 1, support.text != nil,
                      modern || configuration.group != .fixed || (!support.adaptive && support.text == ResearchFeedback.fixed[previous.count]) else {
                    throw DrawingError.invalidEvent("提示不符合分组、阶段或次数规则。")
                }
                if modern {
                    guard let detail = support.multimodal, support.libraryVersion == MultimodalFeedback.version,
                          detail.evidence == activity.hintEvidence, support.text == detail.strategy.text,
                          configuration.group == .fixed
                            ? (!support.adaptive && detail.source == "fixed" && detail.strategy == MultimodalFeedback.fixed(task: activity.task.kind.rawValue, level: previous.count + 1))
                            : (support.adaptive && ["deepseek", "local_fallback"].contains(detail.source) && MultimodalFeedback.candidates(detail.evidence).contains(detail.strategy)) else {
                        throw DrawingError.invalidEvent("提示内容与观察或组别不一致。")
                    }
                } else if support.multimodal != nil { throw DrawingError.invalidEvent("旧访次不能改变提示版本。") }
            }
            activities[currentIndex].feedback.append(support)
        case let .narrationRequested(text, kind, feedbackID, voiceID):
            guard configuration.protocolVersion == ResearchProtocol.version, activeHelp == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 3000, !voiceID.isEmpty, voiceID.count <= 240 else { throw DrawingError.invalidEvent("朗读请求无效。") }
            if kind == .feedback {
                guard activity.task.phase == .training, let feedbackID,
                      activity.feedback.contains(where: { $0.id == feedbackID && $0.allowed && $0.text == text }) else {
                    throw DrawingError.invalidEvent("只能朗读本项已经显示的学习提示。")
                }
            } else if feedbackID != nil { throw DrawingError.invalidEvent("任务说明不能关联学习提示。") }
            activities[currentIndex].narrations.append(.init(id: event.id, taskID: activity.task.id, text: text,
                kind: kind, feedbackID: feedbackID, voiceID: voiceID, requestedAt: event.at))
        case let .helpStarted(kind, operatorCode):
            guard activeHelp == nil, operatorCode.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else {
                throw DrawingError.invalidEvent("请填写专员编号并先结束上次协助。")
            }
            helps.append(.init(id: event.id, taskID: activity.task.id, kind: kind, operatorCode: operatorCode, beganAt: event.at))
        case .helpFinished:
            guard activeHelp != nil else { throw DrawingError.invalidEvent("没有正在进行的协助。") }
            helps[helps.count - 1].endedAt = event.at
        case .taskCompleted:
            guard activeHelp == nil else { throw DrawingError.invalidEvent("请先结束当前协助计时。") }
            if let problem = completionProblem { throw DrawingError.invalidEvent(problem) }
            activities[currentIndex].finishedAt = event.at; currentIndex += 1
            if currentIndex == activities.count { endReason = .completed; endedAt = event.at }
            else { activities[currentIndex].beganAt = event.at }
        case .paused: isPaused = true
        case .resumed: isPaused = false
        case .stopped(let reason):
            guard reason != .completed else { throw DrawingError.invalidEvent("不能跳过任务直接标记完成。") }
            if activeHelp != nil { helps[helps.count - 1].endedAt = event.at }
            endReason = reason; endedAt = event.at
        }
        lastSequence = event.sequence
    }

    public func learningEvidence() -> LearningEvidence {
        guard let a = current else { return .init(task: "open", attempts: 0) }
        let kind = a.task.kind
        var evidence = LearningEvidence(task: [.mix, .wheel, .pressure, .path].contains(kind) ? kind.rawValue : "open", attempts: a.attemptCount)
        if !a.responses.isEmpty { evidence.errorRate = Double(a.responses.filter { $0.correct == false }.count) / Double(a.responses.count) }
        let metrics = a.latestMetrics
        evidence.pressureError = metrics["signedPressureError"] ?? 0; evidence.pressureSD = metrics["normalizedForceSD"] ?? 0
        evidence.pathDeviation = metrics["normalizedPathDeviation"] ?? 0; evidence.coverage = metrics["pathCoverage"] ?? 1
        return evidence
    }
}
