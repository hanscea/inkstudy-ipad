import SwiftUI
import UIKit
import InkStudyCore

@MainActor
final class ResearchController: ObservableObject {
    @Published private(set) var records: [ResearchRecord] = []
    @Published private(set) var record: ResearchRecord?
    @Published private(set) var state: ResearchState?
    @Published private(set) var isBusy = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?
    @Published var notice: String?
    @Published var exportURL: URL?
    @Published var artworkRecord: ResearchRecord?
    @Published private(set) var hintBusy = false
    @Published var visibleHint: ResearchSupport?
    let hintClient: HintClient
    var hintSelector: any HintSelecting
    var stopHintAudio: (() -> Void)?
    private var hintOperation = UUID()
    weak var canvas: StudioModel?
    let directory: URL
    private var store: ResearchStore?
    private var pending: [ResearchEvent] = []
    private var writer: Task<Void, Never>?
    private var started = false
    private let preferences: UserDefaults
    private let selectionKey = "InkStudy.currentResearchID"

    init(directory: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let client = HintClient(preferences: preferences)
        hintClient = client; hintSelector = client
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("InkStudy")
        do { store = try ResearchStore(directory: self.directory.appendingPathComponent("Research")) }
        catch { saveError = error.localizedDescription }
    }

    var locked: Bool { isBusy || saveError != nil || state?.isPaused == true || state?.endReason != nil }
    var current: ResearchActivity? { state?.current }
    var usesMultimodalHints: Bool { state.map { MultimodalFeedback.enabled($0.configuration) } ?? false }
    var saveLabel: String { saveError != nil ? "保存失败，操作已暂停" : isSaving ? "正在保存到本机" : "已自动保存到本机" }

    func start() async {
        guard !started, let store else { return }; started = true
        do {
            records = try await store.list()
            if let id = preferences.string(forKey: selectionKey).flatMap(UUID.init(uuidString:)),
               let record = records.first(where: { $0.id == id }), try record.replay().endReason == nil {
                self.record = record; state = try record.replay()
            }
        } catch { saveError = error.localizedDescription }
    }

    func create(_ configuration: ResearchConfiguration) async {
        guard !isBusy, let store else { return }; isBusy = true
        defer { isBusy = false }
        do {
            try await flushCanvas(); try await flush()
            let created = try await store.create(configuration)
            record = created; state = try created.replay(); pending = []; canvas = nil
            preferences.set(created.id.uuidString, forKey: selectionKey)
            records = try await store.list()
        } catch { notice = error.localizedDescription }
    }

    func open(_ id: UUID) async {
        guard !isBusy, let store else { return }; isBusy = true
        defer { isBusy = false }
        do {
            try await flushCanvas(); try await flush()
            let loaded = try await store.load(id)
            record = loaded; state = try loaded.replay(); canvas = nil
            preferences.set(id.uuidString, forKey: selectionKey)
        } catch { notice = error.localizedDescription }
    }

    @discardableResult
    func enqueue(_ action: ResearchAction) -> Bool {
        switch action {
        case .drawingLinked, .taskCompleted, .paused, .helpStarted, .stopped: stopHintAudio?()
        default: break
        }
        guard saveError == nil, var record, var state, let current = state.current else { return false }
        let event = ResearchEvent(sequence: state.lastSequence + 1, taskID: current.task.id, action: action)
        do {
            try state.apply(event); record.events.append(event)
            switch action {
            case .drawingLinked, .taskCompleted, .paused, .helpStarted, .stopped:
                hideHint(); hintOperation = UUID()
            default: break
            }
            self.record = record; self.state = state; pending.append(event); startWriter()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func draft(_ key: String, _ value: String) {
        guard !locked, current?.drafts[key] != value else { return }
        enqueue(.draft(key: key, value: value))
    }

    @discardableResult
    func perform(_ action: ResearchAction) async -> Bool {
        guard !isBusy, saveError == nil else { return false }; isBusy = true
        defer { isBusy = false }
        do {
            try await flushCanvas()
            guard enqueue(action) else { return false }
            try await flush()
            if let store { records = try await store.list() }
            return true
        } catch { saveError = error.localizedDescription; return false }
    }

    func finishTask() async {
        if await perform(.taskCompleted) { canvas = nil }
    }

    func requestHint(trigger: String = "help_request", inactivitySeconds: Double = 0) async {
        guard !locked, canvas?.isDrawing != true, state?.activeHelp == nil, let state, let current else { return }
        if usesMultimodalHints { await requestMultimodalHint(trigger: trigger); return }
        var evidence = state.learningEvidence(); evidence.inactivitySeconds = inactivitySeconds
        let decision = ResearchFeedback.decide(group: state.configuration.group, phase: current.task.phase,
            evidence: evidence, history: current.feedback, trigger: trigger)
        if await perform(.feedback(decision)), !decision.allowed, trigger == "help_request" {
            let explanations = ["first_independent_attempt_required": "先按自己的想法试一次，再查看提示。",
                "prompt_limit_reached": "本项的三次提示已用完，你可以继续练习。", "cooldown_active": "先试试刚才的提示，稍后可以再看。"]
            notice = explanations[decision.reason] ?? "这个阶段不提供学习提示。"
        }
    }

    func automaticHint(at: Date = Date()) async {
        if usesMultimodalHints {
            guard !locked, !hintBusy, visibleHint == nil, canvas?.isDrawing != true, state?.activeHelp == nil,
                  let current, current.task.phase == .training, let lastInput = canvas?.lastSavedAt,
                  at.timeIntervalSince(lastInput) >= 45,
                  current.feedback.filter(\.allowed).last.map({ $0.at < lastInput && at.timeIntervalSince($0.at) >= 15 }) ?? true,
                  current.feedback.filter(\.allowed).count < 3,
                  canvas?.visibleCount ?? 0 > 0 else { return }
            await requestMultimodalHint(trigger: "inactivity"); return
        }
        guard !locked, canvas?.isDrawing != true, let current, current.task.phase == .training,
              [.mix, .wheel, .pressure, .path].contains(current.task.kind), current.attemptCount > 0,
              state?.activeHelp == nil, let record else { return }
        let accepted = current.feedback.filter(\.allowed)
        guard accepted.count < 3, accepted.last.map({ at.timeIntervalSince($0.at) >= 15 }) ?? true else { return }
        let events = record.events.filter { $0.taskID == current.task.id }
        let attemptDate = events.last { event in
            switch event.action { case .answered, .drawingFinished: true; default: false }
        }?.at ?? record.configuration.createdAt
        let interactionDate = events.last { event in
            switch event.action { case .draft, .answered, .drawingFinished, .resumed, .helpFinished: true; default: false }
        }?.at ?? attemptDate
        let lastInput = max(interactionDate, canvas?.lastSavedAt ?? interactionDate)
        let sinceInput = at.timeIntervalSince(lastInput)
        let latestPrompt = accepted.last?.at ?? .distantPast
        // Both digital groups use identical trigger timing. Only prompt selection differs.
        if latestPrompt < attemptDate {
            if current.responses.suffix(2).count == 2, current.responses.suffix(2).allSatisfy({ $0.correct == false }) {
                await requestHint(trigger: "incorrect_streak"); return
            }
            let recent = current.drawings.filter { $0.finished && $0.valid == true }.suffix(2)
            if recent.count == 2, recent.allSatisfy({ item in
                current.task.kind == .pressure ? (item.metrics["pressureMAE"] ?? 0) > 0.12 : (item.metrics["normalizedPathDeviation"] ?? 0) > 0.035
            }) { await requestHint(trigger: "off_target_streak"); return }
        }
        if sinceInput >= 45, latestPrompt < lastInput { await requestHint(trigger: "inactivity", inactivitySeconds: sinceInput) }
    }

    func leave() async -> Bool {
        guard !isBusy, saveError == nil else { return false }
        if state?.endReason == nil, state?.isPaused == false {
            guard await perform(.paused) else { return false }
        }
        do {
            try await flushCanvas(); try await flush()
            record = nil; state = nil; canvas = nil
            hideHint(); hintOperation = UUID()
            preferences.removeObject(forKey: selectionKey)
            if let store { records = try await store.list() }
            return true
        } catch { saveError = error.localizedDescription; return false }
    }

    func flushCanvas() async throws {
        guard let canvas else { return }
        canvas.interruptCanvas?(.navigation); canvas.endActive(.navigation)
        try await canvas.flush()
    }

    private func startWriter() {
        guard writer == nil, !pending.isEmpty, let store, let id = record?.id else { return }
        isSaving = true
        writer = Task { @MainActor [weak self] in
            guard let self else { return }
            while let event = self.pending.first {
                do {
                    _ = try await store.append(id: id, eventID: event.id, taskID: event.taskID, action: event.action, at: event.at)
                    self.pending.removeFirst()
                } catch { self.saveError = error.localizedDescription; break }
            }
            self.isSaving = false; self.writer = nil
        }
    }

    func flush() async throws {
        if let saveError { throw DrawingError.persistence(saveError) }
        startWriter()
        if let writer { await writer.value }
        if let saveError { throw DrawingError.persistence(saveError) }
        guard pending.isEmpty else { throw DrawingError.persistence("研究记录尚未写入。") }
    }

    func retry() async {
        canvas?.retrySave()
        if store == nil {
            do { store = try ResearchStore(directory: directory.appendingPathComponent("Research")) }
            catch { saveError = error.localizedDescription; return }
        }
        saveError = nil
        if record == nil { started = false; await start() }
        else {
            do { try await flush(); try await flushCanvas() }
            catch { saveError = error.localizedDescription }
        }
    }

    func saveForBackground() {
        canvas?.saveForBackground()
        if state?.endReason == nil, state?.isPaused == false { enqueue(.paused) }
        let application = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        token = application.beginBackgroundTask(withName: "Save research") {
            Task { @MainActor in
                if token != .invalid { application.endBackgroundTask(token); token = .invalid }
            }
        }
        Task { @MainActor in
            do { try await flush() } catch { saveError = error.localizedDescription }
            if token != .invalid { application.endBackgroundTask(token); token = .invalid }
        }
    }

    func export(_ selected: ResearchRecord) async {
        guard !isBusy, saveError == nil else { return }; isBusy = true
        defer { isBusy = false }
        do {
            try await flushCanvas(); try await flush()
            guard let store else { throw DrawingError.persistence("研究存储不可用。") }
            let saved = try await store.load(selected.id)
            exportURL = try await ResearchExport.create(record: saved, directory: directory)
        } catch { notice = "导出未完成：\(error.localizedDescription)" }
    }

    func preview(_ selected: ResearchRecord) async {
        guard !isBusy, saveError == nil, canvas?.isDrawing != true else { return }; isBusy = true
        defer { isBusy = false }
        do {
            try await flushCanvas(); try await flush()
            guard let store else { throw DrawingError.persistence("研究存储不可用。") }
            artworkRecord = try await store.load(selected.id)
        } catch { notice = "预览未完成：\(error.localizedDescription)" }
    }

    func hideHint() { visibleHint = nil }

    func hintDelivered(_ id: UUID, kind: HintDeliveryKind) {
        guard usesMultimodalHints, state?.isPaused == false, state?.endReason == nil,
              current?.feedback.contains(where: { $0.id == id && $0.allowed }) == true else { return }
        enqueue(.hintDelivered(feedbackID: id, kind: kind))
    }

    private func requestMultimodalHint(trigger: String) async {
        guard !hintBusy, let configuration = state?.configuration, let task = current?.task,
              let canvas, let drawing = canvas.state, !canvas.isDrawing else { return }
        hintBusy = true
        defer { hintBusy = false }
        let operation = UUID(); hintOperation = operation
        let sequence = drawing.lastSequence
        let evidence = await Task.detached(priority: .userInitiated) { HintObservation.make(drawing: drawing, task: task) }.value
        guard hintOperation == operation, record?.id == configuration.id, self.canvas?.state?.metadata.id == drawing.metadata.id,
              self.canvas?.state?.lastSequence == sequence, !locked, state?.activeHelp == nil, self.canvas?.isDrawing != true else { return }
        if let reason = MultimodalFeedback.blockReason(phase: task.phase, group: configuration.group, evidence: evidence,
            history: current?.feedback ?? [], at: Date()) {
            if trigger == "help_request" {
                notice = ["first_independent_attempt_required": "先自己画一笔，再看看提示。",
                    "cooldown_active": "先试试刚才的提示，稍后可以再看。", "prompt_limit_reached": "三次提示已用完，可以继续练习。"] [reason] ?? "此时不提供学习提示。"
            }
            return
        }
        guard let evidence, enqueue(.hintObserved(evidence)) else { return }
        let level = (current?.feedback.filter(\.allowed).count ?? 0) + 1
        var strategy = MultimodalFeedback.fixed(task: evidence.task, level: level)
        var source = "fixed", model: String?, requestID: UUID?, latency: Int?, fallback: String?
        if configuration.group == .adaptive {
            requestID = UUID()
            do {
                let result = try await hintSelector.select(evidence: evidence, level: level, requestID: requestID!)
                guard result.requestID == requestID, result.version == MultimodalFeedback.version,
                      MultimodalFeedback.candidates(evidence).contains(result.strategy) else { throw HintClientError(code: "invalid_strategy") }
                strategy = result.strategy; source = "deepseek"; model = result.model; latency = result.latencyMilliseconds
            } catch {
                strategy = MultimodalFeedback.candidates(evidence)[0]; source = "local_fallback"
                fallback = (error as? HintClientError)?.code ?? "provider_unavailable"
            }
        }
        // A late response must never describe a new paper, changed brush, resumed task, or newer stroke.
        guard hintOperation == operation, record?.id == configuration.id, current?.task.id == task.id,
              self.canvas?.state?.metadata.id == drawing.metadata.id, self.canvas?.state?.lastSequence == sequence,
              !locked, state?.activeHelp == nil, self.canvas?.isDrawing != true,
              MultimodalFeedback.blockReason(phase: task.phase, group: configuration.group, evidence: evidence,
                history: current?.feedback ?? [], at: Date()) == nil else { return }
        let support = MultimodalFeedback.support(evidence: evidence, group: configuration.group, level: level,
            strategy: strategy, source: source, trigger: trigger, model: model, requestID: requestID,
            latencyMilliseconds: latency, fallbackReason: fallback)
        if enqueue(.feedback(support)) {
            do {
                try await flush()
                guard hintOperation == operation, !locked, self.canvas?.isDrawing != true,
                      self.canvas?.state?.lastSequence == sequence else { return }
                visibleHint = support
            } catch { saveError = error.localizedDescription }
        }
    }
}

enum HintObservation {
    static func make(drawing: DrawingState, task: ResearchTask) -> HintEvidence? {
        let strokes = drawing.visibleStrokes.filter { $0.endReason == .lifted && !$0.samples.contains(where: { $0.propertiesExpectingUpdates != 0 }) }
        guard !strokes.isEmpty, task.phase == .training, [.mix, .pressure].contains(task.kind), drawing.activeStrokeID == nil else { return nil }
        var metrics: [String: Double], target: String
        var paintFocus: (x: Double, y: Double)?
        if task.kind == .mix {
            guard drawing.metadata.background?.pigmentModel == StandardPalette.mixingVersion else { return nil }
            let surface = PigmentSurface(state: drawing)
            metrics = surface.metrics; paintFocus = surface.paintedFocus
            target = drawing.metadata.background?.subject ?? "orange"
        } else {
            guard let trial = LineExercises.trials(task: task).first(where: { $0.id == drawing.metadata.context?.trialID }), let stroke = strokes.last else { return nil }
            metrics = LineExercises.metrics(stroke: stroke, trial: trial)
            target = trial.pressureProfile?.rawValue ?? (trial.target < 0.2 ? "light" : trial.target < 0.4 ? "medium" : "firm")
        }
        metrics = metrics.filter { HintEvidence.metricKeys.contains($0.key) }
        let points = strokes.flatMap(\.samples).filter { $0.x.isFinite && $0.y.isFinite }
        let x = points.isEmpty ? 0.5 : points.reduce(0) { $0 + $1.x } / Double(points.count) / drawing.metadata.paperWidth
        let y = points.isEmpty ? 0.5 : points.reduce(0) { $0 + $1.y } / Double(points.count) / drawing.metadata.paperHeight
        return .init(drawingID: drawing.metadata.id, drawingSequence: drawing.lastSequence, task: task.kind.rawValue,
            target: target, strokeCount: strokes.count, metrics: metrics, focusX: paintFocus?.x ?? min(0.9, max(0.1, x)), focusY: paintFocus?.y ?? min(0.9, max(0.1, y)))
    }
}
