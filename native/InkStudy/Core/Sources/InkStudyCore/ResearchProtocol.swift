import Foundation

public enum ResearchPurpose: String, Codable, Sendable, CaseIterable { case rehearsal, pilot, formal }
public enum ResearchGroup: String, Codable, Sendable, CaseIterable { case unassigned = "U", paper = "A", fixed = "B", adaptive = "C" }
public enum ResearchPhase: String, Codable, Sendable { case assessment, training, transfer }
public enum ResearchVisit: String, Codable, Sendable, CaseIterable {
    case practice, V1a, V1b, V2, V3, V4, V5, V6, V7
    public var label: String {
        switch self {
        case .practice: "模块练习"
        case .V1a: "色彩与线条基线"
        case .V1b: "综合表达基线"
        case .V2: "色彩训练一"
        case .V3: "色彩训练二与后测"
        case .V4: "线条训练一"
        case .V5: "线条训练二与后测"
        case .V6: "综合迁移"
        case .V7: "色彩与线条延迟测"
        }
    }
    public var requiredPrevious: [ResearchVisit] {
        switch self {
        case .practice, .V1a: []
        case .V1b: [.V1a]
        case .V2: [.V1a, .V1b]
        case .V3: [.V2]
        case .V4: [.V3]
        case .V5: [.V4]
        case .V6: [.V5]
        case .V7: [.V6]
        }
    }
}
public enum ResearchTaskKind: String, Codable, Sendable, CaseIterable {
    case familiarization, device, knowledge, mix, wheel, coloring, pressure, path, emotion, creation, interview, experience, paper, transition, rest
    public var label: String {
        switch self {
        case .familiarization: "同意与设备熟悉"
        case .device: "Pencil 信号检查"
        case .knowledge: "色彩知识"
        case .mix: "颜料混色"
        case .wheel: "六色色环"
        case .coloring: "选择线稿与上色"
        case .pressure: "轻、中、较重的线条"
        case .path: "直线、波浪与圆形"
        case .emotion: "情境中的线条"
        case .creation: "综合创作"
        case .interview: "作品谈话"
        case .experience: "体验记录"
        case .paper: "纸本训练与实施记录"
        case .transition: "进入独立测量"
        case .rest: "休息"
        }
    }
    public var isDrawing: Bool { [.mix, .device, .coloring, .pressure, .path, .emotion, .creation].contains(self) }
}

public struct ResearchConfiguration: Codable, Equatable, Sendable {
    public let id: UUID
    public let participantCode: String
    public let purpose: ResearchPurpose
    public let group: ResearchGroup
    public let visit: ResearchVisit
    public let formOrder: Int
    public let windFirst: Bool
    public let allocationReference: String
    public let practiceKind: ResearchTaskKind?
    public let createdAt: Date
    public let protocolVersion: String
    public let colorPaletteVersion: String?
    public let hintProtocolVersion: String?
    public init(id: UUID = UUID(), participantCode: String, purpose: ResearchPurpose, group: ResearchGroup,
                visit: ResearchVisit, formOrder: Int = 0, windFirst: Bool = true, allocationReference: String = "",
                practiceKind: ResearchTaskKind? = nil, createdAt: Date = Date(), protocolVersion: String = ResearchProtocol.version,
                colorPaletteVersion: String? = StandardPalette.version, hintProtocolVersion: String? = nil) {
        self.id = id; self.participantCode = participantCode; self.purpose = purpose; self.group = group
        self.visit = visit; self.formOrder = formOrder; self.windFirst = windFirst
        self.allocationReference = allocationReference; self.practiceKind = practiceKind
        self.createdAt = DrawingJSON.wallTime(createdAt); self.protocolVersion = protocolVersion
        self.colorPaletteVersion = colorPaletteVersion
        self.hintProtocolVersion = hintProtocolVersion
    }
}

public struct ResearchTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: ResearchTaskKind
    public let phase: ResearchPhase
    public let form: String
    public let subject: String?
    public let variant: String?
    public var label: String { subject.map { "\(kind.label)：\($0)" } ?? kind.label }
    public init(id: String, kind: ResearchTaskKind, phase: ResearchPhase, form: String, subject: String? = nil, variant: String? = nil) {
        self.id = id; self.kind = kind; self.phase = phase; self.form = form; self.subject = subject; self.variant = variant
    }
}

public enum ResearchProtocol {
    public static let legacyVersion = "native-research-v2-20260910-untimed"
    public static let version = "native-research-v3-20260910-0910V2"
    public static let supportedVersions = [legacyVersion, version]
    public static let formVersion = "native-forms-v1-pilot"
    public static let pressureTargetVersion = "native-force-targets-v1-pilot"
    public static let formalUnavailable = "正式采集尚未开放：需完成伦理、儿童预实验、题本与压力目标标定、评分和模型现场验证及版本冻结。"
    public static let orders = ["ABC", "ACB", "BAC", "BCA", "CAB", "CBA"]

    public static func validate(_ configuration: ResearchConfiguration, prior: [ResearchRecord] = []) throws {
        let c = configuration
        guard supportedVersions.contains(c.protocolVersion) else { throw DrawingError.invalidEvent("不支持的研究协议版本。") }
        guard c.participantCode.range(of: "^[A-Za-z0-9_-]{2,32}$", options: .regularExpression) != nil else {
            throw DrawingError.invalidEvent("参与者编号只能含 2–32 位字母、数字、下划线或短横线；不要输入姓名。")
        }
        guard (0..<6).contains(c.formOrder) else { throw DrawingError.invalidEvent("题本顺序无效。") }
        guard c.purpose != .formal else { throw DrawingError.invalidEvent(formalUnavailable) }
        if c.hintProtocolVersion != nil, !MultimodalFeedback.enabled(c) {
            throw DrawingError.invalidEvent("新版提示只用于混色或力度模块的演练测试。")
        }
        if c.visit == .practice {
            guard c.purpose == .rehearsal, let kind = c.practiceKind,
                  [.mix, .wheel, .coloring, .pressure, .path, .emotion, .creation].contains(kind),
                  c.group == .fixed || c.group == .adaptive else { throw DrawingError.invalidEvent("模块练习只能用于演练。") }
            return
        }
        let baseline = c.visit == .V1a || c.visit == .V1b
        guard baseline ? c.group == .unassigned : c.group != .unassigned else {
            throw DrawingError.invalidEvent("基线须在分组前以 U 组完成，后续访次须填写已分配组别。")
        }
        guard c.purpose != .rehearsal else { return }
        let participant = prior.filter { $0.configuration.participantCode == c.participantCode && $0.configuration.purpose == c.purpose }
        guard participant.allSatisfy({ $0.configuration.protocolVersion == c.protocolVersion }) else {
            throw DrawingError.invalidEvent("同一参与者须沿用原研究协议版本。新版练习请使用新的演练或预实验代号。")
        }
        let states = try participant.map { try $0.replay() }
        guard !states.contains(where: { $0.endReason == nil }) else { throw DrawingError.invalidEvent("该参与者还有未结束访次，请先继续或登记停止。") }
        let completed = states.filter { $0.endReason == .completed }.map { $0.configuration.visit }
        guard c.visit.requiredPrevious.allSatisfy(completed.contains), !completed.contains(c.visit) else {
            throw DrawingError.invalidEvent("须完成前序访次；已完成的访次不能覆盖或重复采集。")
        }
        guard participant.allSatisfy({ $0.configuration.formOrder == c.formOrder && $0.configuration.windFirst == c.windFirst }) else {
            throw DrawingError.invalidEvent("同一参与者的题本与综合创作顺序已锁定。")
        }
        guard participant.allSatisfy({ $0.configuration.group == .unassigned || $0.configuration.group == c.group }) else {
            throw DrawingError.invalidEvent("同一参与者不能更换训练组别。")
        }
        if !baseline && c.allocationReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DrawingError.invalidEvent("请填写基线完成后的分配表编号。")
        }
    }

    public static func tasks(for c: ResearchConfiguration) -> [ResearchTask] {
        let letter = String(Array(orders[min(5, max(0, c.formOrder))])[c.visit == .V7 ? 2 : [.V3, .V5].contains(c.visit) ? 1 : 0])
        var tasks: [ResearchTask] = []
        func add(_ kind: ResearchTaskKind, _ phase: ResearchPhase, _ subject: String? = nil) {
            tasks.append(.init(id: "\(c.visit.rawValue)-\(kind.rawValue)-\(tasks.count + 1)", kind: kind, phase: phase,
                               form: phase == .training ? "T-\(c.visit.rawValue)" : letter, subject: subject,
                               variant: c.protocolVersion == version && phase == .training && kind == .pressure ? "pressure-profiles-v2" : nil))
        }
        func colorTest() { add(.knowledge, .assessment); add(.coloring, .assessment); add(.interview, .assessment, "色彩") }
        func lineTest() {
            add(.device, .assessment); add(.pressure, .assessment); add(.path, .assessment)
            for emotion in ["平静", "开心", "紧张"] { add(.emotion, .assessment, emotion) }
        }
        func colorTrain() {
            if c.group == .paper { add(.paper, .training, "色彩"); return }
            add(.mix, .training); add(.wheel, .training); add(.coloring, .training)
        }
        func lineTrain() {
            if c.group == .paper { add(.paper, .training, "线条"); return }
            add(.device, .training)
            if c.visit == .V4 { add(.pressure, .training) }
            else {
                add(.path, .training)
                for emotion in ["平静", "开心", "紧张"] { add(.emotion, .training, emotion) }
            }
        }
        switch c.visit {
        case .practice:
            if c.practiceKind == .emotion {
                for emotion in ["平静", "开心", "紧张"] { add(.emotion, .training, emotion) }
            } else if let kind = c.practiceKind { add(kind, .training, kind == .creation ? "自由主题" : nil) }
        case .V1a:
            add(.familiarization, .assessment); colorTest(); add(.rest, .assessment); lineTest()
        case .V1b, .V6:
            add(.familiarization, .transfer)
            let wind = c.visit == .V1b ? c.windFirst : !c.windFirst
            add(.creation, .transfer, wind ? "风" : "雨"); add(.interview, .transfer, "综合作品")
            if c.visit == .V6 { add(.experience, .transfer) }
        case .V2: colorTrain()
        case .V3: colorTrain(); add(.transition, .assessment); colorTest()
        case .V4: lineTrain()
        case .V5: lineTrain(); add(.transition, .assessment); lineTest()
        case .V7: colorTest(); add(.rest, .assessment); lineTest()
        }
        return tasks
    }

    public static func generationAllowed(participantCode: String?, records: [ResearchRecord]) -> Bool {
        guard let participantCode else { return true }
        let research = records.filter { $0.configuration.participantCode == participantCode && $0.configuration.purpose != .rehearsal }
        guard !research.isEmpty else { return true }
        let required = ResearchVisit.allCases.filter { $0 != .practice }
        let completed = research.compactMap { record -> ResearchVisit? in
            guard let state = try? record.replay(), state.endReason == .completed else { return nil }
            return state.configuration.visit
        }
        return required.allSatisfy(completed.contains)
    }
}

public struct DrawingContext: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let taskID: String
    public let trialID: String
    public let purpose: ResearchPurpose
    public let phase: ResearchPhase
    public let form: String
    public init(sessionID: UUID, task: ResearchTask, trialID: String, purpose: ResearchPurpose) {
        self.sessionID = sessionID; taskID = task.id; self.trialID = trialID
        self.purpose = purpose; phase = task.phase; form = task.form
    }
}

public struct DrawingBackground: Codable, Equatable, Sendable {
    public var kind: String
    public var subject: String
    public var target: Double?
    public var reverse: Bool
    public var pressureProfile: PressureProfile?
    public var pigmentModel: String?
    public init(kind: String, subject: String, target: Double? = nil, reverse: Bool = false, pressureProfile: PressureProfile? = nil, pigmentModel: String? = nil) {
        self.kind = kind; self.subject = subject; self.target = target; self.reverse = reverse; self.pressureProfile = pressureProfile
        self.pigmentModel = pigmentModel
    }
}

public enum NarrationKind: String, Codable, Sendable { case instruction, feedback }
public struct ResearchNarration: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let taskID: String
    public let text: String
    public let kind: NarrationKind
    public let feedbackID: UUID?
    public let voiceID: String
    public let requestedAt: Date
}

public enum ResearchEndReason: String, Codable, Sendable { case completed, stopped, technicalError }
public struct ResearchResponse: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let questionID: String
    public let value: String
    public let correct: Bool?
    public let metrics: [String: Double]
    public let at: Date
}
public struct ResearchDrawingReference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let trialID: String
    public let background: DrawingBackground?
    public var finished: Bool = false
    public var selectedStrokeID: UUID?
    public var valid: Bool?
    public var metrics: [String: Double] = [:]
    public var reason: String?
    public init(id: UUID = UUID(), trialID: String, background: DrawingBackground?) {
        self.id = id; self.trialID = trialID; self.background = background
    }
}
public enum OperatorHelpKind: String, Codable, CaseIterable, Sendable {
    case tools = "工具位置", undo = "撤销与重做操作", pencil = "笔连接或设备故障", reading = "照读界面文字", pause = "暂停与恢复"
    public var script: String {
        switch self {
        case .tools: "只指出所需按钮的位置，不替儿童选择颜色或画法。"
        case .undo: "示范按钮用途，不代替儿童修改作品。"
        case .pencil: "检查连接与触控；不示范任务答案。"
        case .reading: "原样照读界面文字，不追加学习建议。"
        case .pause: "协助休息、停止或恢复，不催促完成。"
        }
    }
}
public struct OperatorHelpRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let taskID: String
    public let kind: OperatorHelpKind
    public let operatorCode: String
    public let beganAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double? { endedAt.map { max(0, $0.timeIntervalSince(beganAt)) } }
}
