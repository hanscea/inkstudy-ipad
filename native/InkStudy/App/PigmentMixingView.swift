import SwiftUI
import InkStudyCore

@MainActor
final class PigmentMixingCoordinator: ObservableObject {
    let studio: StudioModel
    let research: ResearchController
    let task: ResearchTask
    @Published private(set) var referenceID: UUID?
    @Published private(set) var busy = false
    @Published var error: String?
    var activity: ResearchActivity? { research.current?.task.id == task.id ? research.current : nil }
    var reference: ResearchDrawingReference? { activity?.drawings.first { $0.id == referenceID } }
    var target: String { reference?.background?.subject ?? activity?.drafts["mixTarget"] ?? "orange" }
    var first: String { standardPaint ? StandardPalette.pair(for: target)![0] : activity?.drafts[pairKey("first")] ?? "red" }
    var second: String { standardPaint ? StandardPalette.pair(for: target)![1] : activity?.drafts[pairKey("second")] ?? "yellow" }
    var rehearsal: Bool { research.state?.configuration.purpose == .rehearsal }
    var modernPaint: Bool { PigmentSurface.usesSpectralPalette(reference?.background) }
    var palettePaint: Bool { PaletteMixing.supports(reference?.background?.pigmentModel) }
    var standardPaint: Bool { reference?.background?.pigmentModel == StandardPalette.mixingVersion }
    func color(_ id: String) -> InkColor { PigmentSurface.palette(for: reference?.background).first { $0.id == id }! }
    func colorName(_ id: String) -> String {
        if standardPaint { return StandardPalette.primaryNames[id] ?? ColorExercises.names[id]! }
        return modernPaint && id == "red" ? "冷红" : ColorExercises.names[id]!
    }
    func targetColor(_ id: String) -> InkColor {
        (standardPaint ? InkColor.palette : InkColor.legacyPalette).first { $0.id == id }!
    }
    var usedColors: Set<String> {
        Set(studio.state?.visibleStrokes.filter { !palettePaint || $0.style.pigmentLoadID != nil }.map { $0.style.color.id } ?? [])
    }
    var pairWasUsed: Bool { usedColors.isSuperset(of: [first, second]) }
    var recorded: Bool {
        guard let index = activity?.drawings.firstIndex(where: { $0.id == referenceID }) else { return false }
        return activity?.responses.contains { $0.metrics["drawingOrdinal"] == Double(index + 1) } == true
    }
    init(research: ResearchController, task: ResearchTask) {
        self.research = research; self.task = task; studio = StudioModel(directory: research.directory)
    }
    private func pairKey(_ position: String) -> String { "mix-\(position)-\(referenceID?.uuidString ?? "new")" }

    func prepare(target next: String? = nil, retry: Bool = false) async {
        guard !busy, !research.locked, !studio.isDrawing, research.state?.activeHelp == nil,
              let configuration = research.state?.configuration else { return }
        let target = next ?? activity?.drafts["mixTarget"] ?? "orange"
        guard StandardPalette.pair(for: target) != nil else { return }
        if !retry, reference != nil, self.target == target { return }
        busy = true; error = nil; syncLock()
        do {
            let finger = studio.fingerInputEnabled
            let reference: ResearchDrawingReference
            if !retry, let existing = activity?.drawings.last(where: { $0.trialID == "mix-" + target }) { reference = existing }
            else {
                reference = .init(trialID: "mix-" + target, background: .init(kind: "pigment", subject: target, pigmentModel: StandardPalette.mixingVersion))
                guard await research.perform(.drawingLinked(reference)) else { busy = false; syncLock(); return }
            }
            referenceID = reference.id
            research.draft("mixTarget", target)
            let context = DrawingContext(sessionID: configuration.id, task: task, trialID: reference.trialID, purpose: configuration.purpose)
            try await studio.activateResearchDocument(id: reference.id, context: context, background: reference.background,
                neutral: false, initialBrush: .init(color: color(first), size: 96),
                fingerInput: rehearsal && finger ? true : nil)
            research.canvas = studio
        } catch { self.error = error.localizedDescription }
        busy = false; syncLock()
        if reference?.valid == true, !recorded { await finish() }
    }

    func selectBrush(_ color: String) {
        guard !busy, !research.locked, research.state?.activeHelp == nil, !studio.isDrawing,
              reference?.finished != true, [first, second].contains(color) else { return }
        studio.setBrush(.init(color: self.color(color), size: 96, pigmentLoadID: palettePaint ? UUID() : nil))
    }
    func stirOnly() {
        guard palettePaint, !busy, !research.locked, research.state?.activeHelp == nil, !studio.isDrawing,
              reference?.finished != true else { return }
        studio.setBrush(.init(color: studio.brush.color, size: 96))
    }
    func syncLock() {
        studio.interactionLocked = busy || research.locked || research.state?.activeHelp != nil || reference?.finished == true || error != nil
    }
    func finish() async {
        guard !busy, !research.locked, let reference, !recorded else { return }
        busy = true; error = nil; syncLock()
        defer { busy = false; syncLock() }
        do {
            var metrics = reference.metrics
            if !reference.finished {
                let document = try await studio.storedDocument(), drawing = try document.replay()
                let strokes = drawing.visibleStrokes
                let used = Set(strokes.filter { !palettePaint || $0.style.pigmentLoadID != nil }.map { $0.style.color.id })
                guard used.isSuperset(of: [first, second]) else { error = "请先蘸取两种颜色，在调色区域试画。"; return }
                metrics = await Task.detached(priority: .userInitiated) { PigmentSurface(state: drawing).metrics }.value
                metrics["visibleStrokeCount"] = Double(strokes.count)
                metrics["originalStrokeCount"] = Double(drawing.strokes.count)
                metrics["sampleCount"] = strokes.reduce(0) { $0 + (LineExercises.metrics(stroke: $1, trial: nil)["sampleCount"] ?? 0) }
                metrics["pencilSampleCount"] = strokes.reduce(0) { $0 + (LineExercises.metrics(stroke: $1, trial: nil)["pencilSampleCount"] ?? 0) }
                metrics["rehearsal"] = rehearsal ? 1 : 0
                let valid = LineExercises.valid(metrics: metrics, rehearsal: rehearsal)
                guard await research.perform(.drawingFinished(id: reference.id, strokeID: nil, valid: valid, metrics: metrics,
                    reason: valid ? nil : "insufficient_input_samples")), valid else { return }
            } else if reference.valid != true { return }
            metrics["drawingOrdinal"] = Double((activity?.drawings.firstIndex { $0.id == reference.id } ?? 0) + 1)
            _ = await research.perform(.answered(questionID: target, value: first + "+" + second, metrics: metrics))
        } catch { self.error = error.localizedDescription }
    }
}

struct PigmentMixingView: View {
    @ObservedObject var research: ResearchController
    @StateObject private var capture: PigmentMixingCoordinator
    let sidebar: Bool
    let showHelp: () -> Void
    init(research: ResearchController, task: ResearchTask, sidebar: Bool, showHelp: @escaping () -> Void) {
        self.research = research; self.sidebar = sidebar; self.showHelp = showHelp
        _capture = StateObject(wrappedValue: PigmentMixingCoordinator(research: research, task: task))
    }
    var body: some View {
        PigmentMixingContent(capture: capture, research: research, studio: capture.studio, sidebar: sidebar, showHelp: showHelp)
            .task { await capture.prepare() }
            .onChange(of: research.locked) { _, locked in
                capture.syncLock()
                if !locked, capture.referenceID == nil { Task { await capture.prepare() } }
            }
            .onChange(of: research.state?.activeHelp?.id) { _, _ in capture.syncLock() }
    }
}

private struct PigmentMixingContent: View {
    @ObservedObject var capture: PigmentMixingCoordinator
    @ObservedObject var research: ResearchController
    @ObservedObject var studio: StudioModel
    let sidebar: Bool
    let showHelp: () -> Void
    private var instructions: String {
        capture.palettePaint
            ? "点颜色蘸一份，先涂一种，再涂另一种。颜料用完后，继续来回涂或绕圈，把颜色慢慢调匀。再点颜色才会补充颜料。"
            : "选两种原色。先涂一种，再换另一种，在同一块颜料上来回涂，看看颜色怎样变化。"
    }
    var body: some View {
        let layout = sidebar ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * 1200 / 850)
                NativeCanvas(model: studio).frame(width: width, height: width * 850 / 1200)
                    .overlay { HintCanvasGuide(research: research, studio: studio) }
                    .overlay(Rectangle().stroke(StudioTheme.line, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if studio.visibleCount == 0 {
                            Text(capture.palettePaint ? "先点颜色蘸一份，再在这里调色" : "在这里试着调色")
                                .font(.title3).foregroundStyle(StudioTheme.muted.opacity(0.6)).padding(24).allowsHitTesting(false)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 210)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if sidebar { ResearchTaskHeading(research: research, compact: true, showHelp: showHelp) }
                    if sidebar, research.usesMultimodalHints { ResearchTaskSupport(research: research, compact: true) }
                    Text(instructions).font(.subheadline)
                    if !capture.standardPaint, capture.reference != nil {
                        Text("这张纸保留旧版颜色与原色组合。点“新纸再试”使用标准六色和自动配对。").font(.caption).foregroundStyle(StudioTheme.muted)
                    }
                    NarrationButton(research: research, text: instructions, key: "mix-instruction")
                    HStack(spacing: 10) {
                        Text("想调出").font(.caption)
                        ForEach(StandardPalette.targetIDs, id: \.self) { id in
                            Button { Task { await capture.prepare(target: id) } } label: {
                                ResearchColorSwatch(id: id, size: 32, showName: true, hex: capture.targetColor(id).hex).padding(4)
                                    .background(capture.target == id ? StudioTheme.line : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("mixTarget-\(id)")
                        }
                    }.disabled(capture.busy || research.locked || studio.isDrawing || research.state?.activeHelp != nil)
                    Text("原始色彩：\(capture.colorName(capture.first)) + \(capture.colorName(capture.second))")
                        .font(.caption).accessibilityIdentifier("mixPrimaryPair")
                    if capture.reference?.finished != true {
                    if capture.palettePaint && !sidebar {
                        HStack(spacing: 24) { paintColors; loadControls.frame(maxWidth: .infinity, alignment: .leading) }
                    } else {
                        paintColors
                        if capture.palettePaint { loadControls }
                    }
                    HStack {
                        Button("撤销") { studio.undo() }.disabled(!studio.canUndo)
                        Button("重做") { studio.redo() }.disabled(!studio.canRedo)
                    }.buttonStyle(.bordered)
                    if capture.rehearsal {
                        Toggle("手指预览", isOn: Binding(get: { studio.fingerInputEnabled }, set: { studio.setFingerInput($0) }))
                            .font(.caption).disabled(!studio.canDraw || studio.isDrawing).accessibilityIdentifier("researchFingerInput")
                    }
                    }
                    if capture.recorded {
                        Text("这次混色已保存。可以换一个目标，或用新纸再试。").font(.subheadline)
                    } else if capture.reference?.finished == true && capture.reference?.valid != true {
                        Text("本次笔迹已保留，设备数据不足，请用新纸再试。").font(.caption)
                    } else {
                        Button("保存这次调色") { Task { await capture.finish() } }
                            .buttonStyle(.borderedProminent).foregroundStyle(.white)
                            .disabled(!capture.pairWasUsed || studio.isDrawing || capture.busy || research.locked || research.state?.activeHelp != nil)
                            .accessibilityIdentifier("savePigmentMix")
                    }
                    Button("新纸再试") { Task { await capture.prepare(target: capture.target, retry: true) } }
                        .buttonStyle(.bordered).disabled(capture.busy || research.locked || studio.isDrawing || research.state?.activeHelp != nil)
                    Text("已尝试 \(Set(research.current?.responses.map(\.questionID) ?? []).count)/3 种目标间色").font(.caption).foregroundStyle(StudioTheme.muted)
                    if let error = capture.error ?? studio.saveError ?? studio.startupError {
                        ResearchSaveError(message: error) { capture.error = nil; studio.retrySave(); capture.syncLock() }
                    }
                    if sidebar, !research.usesMultimodalHints { ResearchTaskSupport(research: research, compact: true) }
                }.padding(sidebar ? 12 : 6)
            }.frame(width: sidebar ? (research.usesMultimodalHints ? 320 : 248) : nil, height: sidebar ? nil : 280)
                .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        }
        .onChange(of: studio.isDrawing) { _, drawing in if drawing { research.hideHint() } }
    }
    private var paintColors: some View {
        HStack(spacing: 18) {
            ForEach([capture.first, capture.second], id: \.self) { id in
                Button { capture.selectBrush(id) } label: {
                    VStack(spacing: 3) {
                        ResearchColorSwatch(id: id, size: 48, showName: true, hex: capture.color(id).hex, name: capture.colorName(id))
                        if capture.palettePaint { Text("蘸一份").font(.caption2) }
                    }.padding(7)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(studio.brush.color.id == id && (!capture.palettePaint || studio.brush.pigmentLoadID != nil) ? StudioTheme.accent : .clear, lineWidth: 2))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(research.visibleHint?.multimodal?.strategy.colorID == id ? Color.orange : .clear, lineWidth: 4))
                }.buttonStyle(.plain).accessibilityLabel(capture.colorName(id) + (capture.palettePaint ? "，蘸一份颜料" : ""))
                    .accessibilityIdentifier("mixBrush-\(id)")
            }
        }.disabled(!studio.canDraw || studio.isDrawing)
    }
    private var loadControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(studio.pigmentLoadFraction > 0
                ? "\(capture.colorName(studio.brush.color.id))余量 \(Int((studio.pigmentLoadFraction * 100).rounded()))%"
                : studio.visibleCount == 0 ? "点颜色蘸取颜料" : "正在搅拌，不添加颜料")
                .font(.caption).accessibilityIdentifier("pigmentLoadLabel")
            ProgressView(value: studio.pigmentLoadFraction).tint(StudioTheme.accent)
                .accessibilityLabel("笔上剩余颜料")
            Button("只搅拌") { capture.stirOnly() }
                .buttonStyle(.bordered).disabled(!studio.canDraw || studio.isDrawing || studio.brush.pigmentLoadID == nil)
                .accessibilityIdentifier("mixStirOnly")
        }
    }
}
