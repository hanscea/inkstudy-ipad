import Foundation
import SwiftUI
import UIKit
import InkStudyCore

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isBusy = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var saveError: String?
    @Published private(set) var startupError: String?
    @Published private(set) var library: [DocumentMetadata] = []
    @Published private(set) var pressure: Double?
    @Published private(set) var observedPressureRange: ClosedRange<Double>?
    @Published private(set) var hasSeenPencil = false
    @Published private(set) var pigmentLoadFraction = 0.0
    @Published var shareFiles: ExportFiles?
    @Published var notice: String?
    @Published var interactionLocked = false

    private(set) var state: DrawingState?
    var interruptCanvas: ((StrokeEndReason) -> Void)?
    var didApplyEvent: ((DrawingEvent) -> Void)?
    var researchEventObserver: ((DrawingEvent) -> Void)?
    private var store: (any DrawingRepository)?
    private var pending: [DrawingEvent] = []
    private var writer: Task<Void, Never>?
    private var started = false
    private let preferences: UserDefaults
    private let currentDocumentKey = "InkStudy.currentDocumentID"
    private let dataDirectory: URL

    init(directory: URL? = nil, repository: (any DrawingRepository)? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testName = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--test-store=") })
        dataDirectory = directory ?? documents.appendingPathComponent(testName.map { "UITests-" + $0.dropFirst("--test-store=".count) } ?? "InkStudy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dataDirectory.path)
            store = try repository ?? JournalStore(url: dataDirectory.appendingPathComponent("drawings.sqlite"))
        } catch { startupError = error.localizedDescription }
    }

    var canDraw: Bool { !interactionLocked && !isLoading && !isBusy && saveError == nil && startupError == nil && state != nil }
    var brush: BrushStyle { state?.brush ?? .init() }
    var palette: [InkColor] {
        if state?.metadata.background?.kind == "pigment" { return PigmentSurface.palette(for: state?.metadata.background) }
        return state?.metadata.colorPaletteVersion == StandardPalette.version ? InkColor.palette : InkColor.legacyPalette
    }
    var isDrawing: Bool { state?.activeStrokeID != nil }
    var canUndo: Bool { canDraw && state?.canUndo == true }
    var canRedo: Bool { canDraw && state?.canRedo == true }
    var fingerInputEnabled: Bool { state?.fingerInputEnabled == true }
    var visibleCount: Int { state?.visibleStrokeIDs.count ?? 0 }
    var originalCount: Int { state?.strokes.count ?? 0 }
    var sampleCount: Int { state?.sampleCount ?? 0 }

    var saveLabel: String {
        if startupError != nil { return "本地存储无法打开" }
        if saveError != nil { return "保存失败，请重试" }
        if isLoading { return "正在恢复画纸" }
        if isSaving { return "正在保存到本机" }
        return "已自动保存到本机"
    }

    var pressureLabel: String {
        if let range = observedPressureRange, range.upperBound - range.lowerBound > 0.02 { return "已收到变化的压感信号" }
        if hasSeenPencil { return "已识别 Pencil，等待压感变化" }
        return fingerInputEnabled ? "手指预览，不记录为压力" : "使用 Apple Pencil 绘画"
    }

    func start() async {
        guard !started else { return }; started = true
        guard let store else { isLoading = false; return }
        do {
            library = try await store.list().filter { $0.context == nil }
            let savedID = preferences.string(forKey: currentDocumentKey).flatMap(UUID.init(uuidString:))
            if let metadata = library.first(where: { $0.id == savedID }) ?? library.first {
                try await restore(metadata.id)
            } else { try await makeDocument() }
            isLoading = false
        } catch { startupError = error.localizedDescription; isLoading = false }
    }

    private func restore(_ id: UUID) async throws {
        guard let store else { throw DrawingError.persistence("storage unavailable") }
        let document = try await store.load(id: id)
        state = try document.replay(); pressure = nil; hasSeenPencil = false; observedPressureRange = nil
        preferences.set(id.uuidString, forKey: currentDocumentKey)
        revision += 1
        if let unfinished = state?.activeStrokeID {
            record(.strokeEnded(strokeID: unfinished, reason: .recovered))
            notice = "已恢复上次画纸；中断时的笔迹也已保留。"
            try await flush()
        }
        lastSavedAt = document.events.last?.recordedAt ?? document.metadata.createdAt
    }

    private func makeDocument() async throws {
        guard let store else { throw DrawingError.persistence("storage unavailable") }
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm"
        let metadata = DocumentMetadata(title: formatter.string(from: Date()), deviceModel: UIDevice.current.model,
                                        osVersion: UIDevice.current.systemVersion, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0")
        try await store.create(metadata)
        state = try DrawingState(metadata: metadata)
        preferences.set(metadata.id.uuidString, forKey: currentDocumentKey)
        pressure = nil; hasSeenPencil = false; observedPressureRange = nil
        revision += 1; lastSavedAt = metadata.createdAt
        library = try await store.list().filter { $0.context == nil }
    }

    func newDocument() async {
        guard canDraw else { return }
        interruptCanvas?(.navigation); endActive(.navigation); isBusy = true
        defer { isBusy = false }
        do { try await flush(); try await makeDocument() }
        catch { notice = "无法新建画纸：\(error.localizedDescription)" }
    }

    func openDocument(_ id: UUID) async {
        guard canDraw, id != state?.metadata.id, library.contains(where: { $0.id == id && $0.context == nil }) else { return }
        interruptCanvas?(.navigation); endActive(.navigation); isBusy = true
        defer { isBusy = false }
        do { try await flush(); try await restore(id) }
        catch { notice = "无法打开画纸：\(error.localizedDescription)" }
    }

    func activateResearchDocument(id: UUID, context: DrawingContext, background: DrawingBackground?, neutral: Bool,
                                  initialBrush: BrushStyle? = nil, fingerInput: Bool? = nil) async throws {
        guard let store else { throw DrawingError.persistence("本地画纸存储不可用。") }
        interruptCanvas?(.navigation); endActive(.navigation)
        try await flush()
        isLoading = true
        defer { isLoading = false }
        let existing = try await store.list()
        if let metadata = existing.first(where: { $0.id == id }) {
            guard metadata.context == context else { throw DrawingError.invalidEvent("研究画纸关联不匹配。") }
        } else {
            let metadata = DocumentMetadata(id: id, title: "\(context.taskID) · \(context.trialID)", deviceModel: UIDevice.current.model,
                osVersion: UIDevice.current.systemVersion, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0",
                context: context, background: background, neutralRendering: neutral)
            try await store.create(metadata)
        }
        // Research documents do not replace the free-studio selection or appear in its editable library.
        let document = try await store.load(id: id)
        state = try document.replay(); pressure = nil; hasSeenPencil = false; observedPressureRange = nil
        if state?.activeStrokeID != nil { endActive(.recovered); try await flush() }
        started = true; revision += 1; lastSavedAt = document.events.last?.recordedAt ?? document.metadata.createdAt
        // Persist protocol defaults before input unlocks, without changing any existing strokes.
        if originalCount == 0 {
            let hasBrush = document.events.contains { if case .brushChanged = $0.payload { return true }; return false }
            if !hasBrush, let initialBrush, initialBrush != brush, !record(.brushChanged(style: initialBrush)) {
                throw DrawingError.persistence(saveError ?? "研究画笔设置无法保存。")
            }
            if let fingerInput {
                let enabled = fingerInput && context.purpose == .rehearsal
                if enabled != fingerInputEnabled, !record(.fingerInputChanged(enabled: enabled)) {
                    throw DrawingError.persistence(saveError ?? "研究输入设置无法保存。")
                }
            }
            try await flush()
        }
    }

    func storedDocument(_ id: UUID? = nil) async throws -> StoredDocument {
        guard let store, let target = id ?? state?.metadata.id else { throw DrawingError.persistence("没有可读取的画纸。") }
        if target == state?.metadata.id { try await flush() }
        return try await store.load(id: target)
    }

    @discardableResult
    func beginStroke(id: UUID, transform: CanvasTransform, samples: [TouchSample]) -> Bool {
        guard canDraw, !isDrawing, !samples.isEmpty else { return false }
        let result = record(.strokeBegan(strokeID: id, style: brush, transform: transform, samples: samples))
        observePressure(samples); return result
    }

    func appendSamples(strokeID: UUID, samples: [TouchSample]) {
        guard !samples.isEmpty, state?.activeStrokeID == strokeID else { return }
        record(.samplesAppended(strokeID: strokeID, samples: samples)); observePressure(samples)
    }

    func reviseSamples(strokeID: UUID, samples: [TouchSample]) {
        guard state?.stroke(id: strokeID) != nil, !samples.isEmpty else { return }
        if record(.samplesRevised(strokeID: strokeID, samples: samples)) { observePressure(samples) }
    }

    func endActive(_ reason: StrokeEndReason) {
        guard let id = state?.activeStrokeID else { return }
        record(.strokeEnded(strokeID: id, reason: reason)); pressure = nil
    }

    func setBrush(_ style: BrushStyle) {
        guard canDraw, !isDrawing, style != brush else { return }
        if record(.brushChanged(style: style)), PaletteMixing.supports(state?.metadata.background?.pigmentModel) {
            pigmentLoadFraction = style.pigmentLoadID == nil ? 0 : 1
        }
    }

    func updatePigmentLoad(documentID: UUID, loadID: UUID?, fraction: Double) {
        guard state?.metadata.id == documentID, brush.pigmentLoadID == loadID else { return }
        let fraction = min(1, max(0, fraction))
        if fraction != pigmentLoadFraction { pigmentLoadFraction = fraction }
    }

    func setFingerInput(_ enabled: Bool) {
        guard canDraw, !isDrawing, enabled != fingerInputEnabled else { return }
        record(.fingerInputChanged(enabled: enabled))
    }

    func undo() {
        guard canUndo, let id = state?.visibleStrokeIDs.last else { return }
        record(.undone(strokeID: id))
    }

    func redo() {
        guard canRedo, let id = state?.redoStrokeIDs.last else { return }
        record(.redone(strokeID: id))
    }

    @discardableResult
    private func record(_ payload: EventPayload) -> Bool {
        guard let id = state?.metadata.id, let sequence = state?.lastSequence else { return false }
        let event = DrawingEvent(documentID: id, sequence: sequence + 1, payload: payload)
        do {
            try state?.apply(event)
            pending.append(event); revision += 1
            didApplyEvent?(event)
            researchEventObserver?(event)
            if saveError == nil { startWriter() }
            return true
        } catch { saveError = error.localizedDescription; return false }
    }

    private func observePressure(_ samples: [TouchSample]) {
        for sample in samples where sample.input == .pencil {
            hasSeenPencil = true
            if let value = sample.normalizedForce, sample.phase != .ended && sample.phase != .cancelled {
                pressure = value
                if let range = observedPressureRange { observedPressureRange = min(range.lowerBound, value)...max(range.upperBound, value) }
                else { observedPressureRange = value...value }
            }
        }
    }

    private func startWriter() {
        guard writer == nil, !pending.isEmpty, let store else { return }
        isSaving = true
        writer = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let batch = self.pending
                do {
                    try await store.append(batch)
                    self.pending.removeFirst(batch.count)
                    self.lastSavedAt = Date()
                } catch {
                    self.saveError = error.localizedDescription
                    break
                }
            }
            self.isSaving = false; self.writer = nil
        }
    }

    func flush() async throws {
        if let error = saveError { throw DrawingError.persistence(error) }
        startWriter()
        if let writer { await writer.value }
        if let error = saveError { throw DrawingError.persistence(error) }
        guard pending.isEmpty else { throw DrawingError.persistence("uncommitted drawing events") }
    }

    func retrySave() {
        guard startupError == nil else { started = false; Task { await start() }; return }
        saveError = nil; startWriter()
    }

    func saveForBackground() {
        interruptCanvas?(.backgrounded); endActive(.backgrounded)
        let application = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        token = application.beginBackgroundTask(withName: "Save drawing") { [weak self] in
            Task { @MainActor in
                self?.notice = "后台保存时间已结束；重新打开后请确认保存状态。"
                if token != .invalid { application.endBackgroundTask(token); token = .invalid }
            }
        }
        Task { @MainActor in
            do { try await flush() } catch { saveError = error.localizedDescription }
            if token != .invalid { application.endBackgroundTask(token); token = .invalid }
        }
    }

    func exportDrawing() async {
        guard canDraw, let store, let id = state?.metadata.id else { return }
        interruptCanvas?(.export); endActive(.export); isBusy = true
        defer { isBusy = false }
        do {
            try await flush()
            let document = try await store.load(id: id)
            let files = try await ExportService.create(document: document, root: dataDirectory.appendingPathComponent("Exports", isDirectory: true))
            shareFiles = files
        } catch { notice = "导出未完成：\(error.localizedDescription)" }
    }
}
