import SwiftUI
import InkStudyCore

@MainActor
final class ResearchDrawingCoordinator: ObservableObject {
    let studio: StudioModel
    let task: ResearchTask
    let research: ResearchController
    @Published private(set) var referenceID: UUID?
    @Published private(set) var trialIndex = 0
    @Published private(set) var busy = false
    @Published var error: String?
    private var captureTask: Task<Void, Never>?
    var controlled: Bool { [.pressure, .path].contains(task.kind) }
    var monochrome: Bool { [.device, .pressure, .path, .emotion].contains(task.kind) }
    var trials: [ResearchLineTrial] { controlled ? LineExercises.trials(task: task) : [] }
    var trial: ResearchLineTrial? { trials.indices.contains(trialIndex) ? trials[trialIndex] : nil }
    var trialID: String { trial?.id ?? task.id + "-open" }
    var activity: ResearchActivity? { research.current?.task.id == task.id ? research.current : nil }
    var reference: ResearchDrawingReference? { activity?.drawings.first { $0.id == referenceID } }
    var training: Bool { task.phase == .training }
    var rehearsal: Bool { research.state?.configuration.purpose == .rehearsal }
    var needsOutline: Bool { task.kind == .coloring && training && activity?.drafts["outline"] == nil }

    init(research: ResearchController, task: ResearchTask) {
        self.research = research; self.task = task; studio = StudioModel(directory: research.directory)
    }

    func start() async {
        if controlled {
            if research.usesMultimodalHints, let last = activity?.drawings.last,
               let index = trials.firstIndex(where: { $0.id == last.trialID }) {
                trialIndex = index
            } else {
                trialIndex = trials.firstIndex { activity?.selectedTrials[$0.id] == nil } ?? max(0, trials.count - 1)
            }
        }
        studio.researchEventObserver = { [weak self] event in
            guard let self, self.controlled else { return }
            if case .strokeEnded = event.payload { self.scheduleCapture() }
        }
        await prepare()
    }

    func chooseOutline(_ subject: String) async {
        research.draft("outline", subject); await prepare()
    }

    func prepare(retry: Bool = false) async {
        guard !busy, !research.locked, !needsOutline, let configuration = research.state?.configuration else { return }
        busy = true; error = nil; syncLock()
        defer { busy = false; syncLock() }
        do {
            let fingerPreview = studio.fingerInputEnabled
            let background: DrawingBackground? = trial?.background ?? (task.kind == .coloring
                ? .init(kind: "outline", subject: training ? activity?.drafts["outline"] ?? "cat" : "form-" + task.form) : nil)
            let reference: ResearchDrawingReference
            if !retry, let existing = activity?.drawings.last(where: { $0.trialID == trialID }) { reference = existing }
            else {
                reference = .init(trialID: trialID, background: background)
                guard await research.perform(.drawingLinked(reference)) else { return }
            }
            referenceID = reference.id
            let context = DrawingContext(sessionID: configuration.id, task: task, trialID: reference.trialID, purpose: configuration.purpose)
            try await studio.activateResearchDocument(id: reference.id, context: context, background: reference.background,
                neutral: !training && [.pressure, .path].contains(task.kind),
                initialBrush: monochrome ? .init(color: .researchLine, size: controlled ? 80 : 28) : nil,
                fingerInput: rehearsal && fingerPreview ? true : nil)
            research.canvas = studio
        } catch { self.error = error.localizedDescription }
        if controlled, reference?.finished != true, studio.state?.strokes.first?.endReason != nil { scheduleCapture() }
    }

    func nextTrial() async {
        guard !busy, !research.locked, reference?.valid == true, trialIndex + 1 < trials.count else { return }
        trialIndex += 1; await prepare()
    }

    func syncLock() {
        studio.interactionLocked = busy || research.locked || research.state?.activeHelp != nil || reference?.finished == true || error != nil
    }

    func scheduleCapture() {
        guard captureTask == nil, reference?.finished != true else { return }
        studio.interactionLocked = true
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Pencil estimates can arrive after lift. Wait briefly for revisions, never for child speed or accuracy.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(125))
                let samples: [TouchSample] = self.studio.state?.strokes.first?.samples ?? []
                let unresolved = samples.contains(where: { $0.propertiesExpectingUpdates != 0 })
                if !unresolved { break }
            }
            self.captureTask = nil
            if !self.research.locked, !self.busy { await self.finish() }
        }
    }

    func resume() async {
        syncLock()
        if referenceID == nil { await prepare() }
        else if controlled, reference?.finished != true, studio.state?.strokes.first?.endReason != nil { scheduleCapture() }
    }

    func finish() async {
        guard !busy, !research.locked, let reference, !reference.finished, activity != nil else { return }
        busy = true; error = nil; syncLock()
        defer { busy = false; syncLock() }
        do {
            studio.interruptCanvas?(.navigation); studio.endActive(.navigation)
            let document = try await studio.storedDocument()
            let drawing = try document.replay()
            var metrics: [String: Double]
            let valid: Bool
            let strokeID: UUID?
            let reason: String?
            if controlled {
                guard let stroke = drawing.strokes.first else { return }
                metrics = LineExercises.metrics(stroke: stroke, trial: trial)
                let unresolved = stroke.samples.contains { $0.propertiesExpectingUpdates != 0 }
                valid = stroke.endReason == .lifted && !unresolved && LineExercises.valid(metrics: metrics, rehearsal: rehearsal)
                strokeID = stroke.id
                reason = valid ? nil : unresolved ? "unresolved_pencil_estimates" : stroke.endReason != .lifted ? "interrupted_stroke" : "insufficient_input_samples"
            } else {
                let visible = drawing.strokes.filter { drawing.visibleStrokeIDs.contains($0.id) }
                let measures = visible.map { LineExercises.metrics(stroke: $0, trial: nil) }
                metrics = ["visibleStrokeCount": Double(visible.count), "originalStrokeCount": Double(drawing.strokes.count),
                    "sampleCount": measures.reduce(0) { $0 + ($1["sampleCount"] ?? 0) },
                    "pencilSampleCount": measures.reduce(0) { $0 + ($1["pencilSampleCount"] ?? 0) }]
                var forces: [Double] = []
                for stroke in visible {
                    for sample in stroke.samples where sample.input == .pencil && sample.propertiesExpectingUpdates == 0 && sample.phase != .ended && sample.phase != .cancelled {
                        if let force = sample.normalizedForce { forces.append(force) }
                    }
                }
                if let minimum = forces.min(), let maximum = forces.max() {
                    metrics["normalizedForceRange"] = maximum - minimum
                    metrics["normalizedForceMean"] = forces.reduce(0, +) / Double(forces.count)
                }
                valid = LineExercises.valid(metrics: metrics, rehearsal: rehearsal, deviceCheck: task.kind == .device)
                strokeID = nil; reason = valid ? nil : task.kind == .device ? "pencil_signal_check_failed" : "insufficient_input_samples"
            }
            metrics["rehearsal"] = rehearsal ? 1 : 0
            _ = await research.perform(.drawingFinished(id: reference.id, strokeID: strokeID, valid: valid, metrics: metrics, reason: reason))
        } catch { self.error = error.localizedDescription }
    }
}

struct ResearchDrawingView: View {
    @StateObject private var capture: ResearchDrawingCoordinator
    @ObservedObject var research: ResearchController
    let sidebar: Bool
    let showHelp: () -> Void
    init(research: ResearchController, task: ResearchTask, sidebar: Bool = false, showHelp: @escaping () -> Void = {}) {
        self.research = research; self.sidebar = sidebar; self.showHelp = showHelp
        _capture = StateObject(wrappedValue: ResearchDrawingCoordinator(research: research, task: task))
    }
    var body: some View {
        ResearchDrawingContent(capture: capture, research: research, studio: capture.studio, sidebar: sidebar, showHelp: showHelp)
            .task { await capture.start() }
            .onChange(of: research.locked) { _, locked in
                capture.syncLock()
                if !locked { Task { await capture.resume() } }
            }
            .onChange(of: research.state?.activeHelp?.id) { _, _ in capture.syncLock() }
    }
}

private struct ResearchDrawingContent: View {
    @ObservedObject var capture: ResearchDrawingCoordinator
    @ObservedObject var research: ResearchController
    @ObservedObject var studio: StudioModel
    let sidebar: Bool
    let showHelp: () -> Void
    @State private var preview: ArtworkPreview?

    var body: some View {
        let layout = sidebar ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            Group {
                if capture.needsOutline { outlinePicker }
                else {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * 1200 / 850)
                    NativeCanvas(model: studio).frame(width: width, height: width * 850 / 1200)
                        .overlay { HintCanvasGuide(research: research, studio: studio) }
                        .overlay(Rectangle().stroke(StudioTheme.line, lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 210)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if sidebar {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ResearchTaskHeading(research: research, compact: true, showHelp: showHelp)
                        if research.usesMultimodalHints { ResearchTaskSupport(research: research, compact: true) }
                        drawingTools
                        if !research.usesMultimodalHints { ResearchTaskSupport(research: research, compact: true) }
                    }.padding(12)
                }.frame(width: research.usesMultimodalHints ? 320 : 248).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            } else { drawingTools }
        }.fullScreenCover(item: $preview) { ArtworkPreviewScreen(artwork: $0) }
            .onChange(of: studio.isDrawing) { _, drawing in if drawing { research.hideHint() } }
    }

    private var drawingTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !capture.needsOutline {
                instructions
                if capture.reference?.finished != true { controls }
                if let error = capture.error ?? studio.saveError ?? studio.startupError {
                    ResearchSaveError(message: error) {
                        studio.retrySave()
                        Task {
                            capture.error = nil
                            if capture.referenceID == nil { await capture.prepare() }
                            else { await capture.resume() }
                        }
                    }
                }
                result
            }
        }
    }

    private var instructionText: String {
        if let trial = capture.trial {
            return "第 \(capture.trialIndex + 1)/\(capture.trials.count) 条：\(trial.label)。从圆点开始，沿引导线画一笔。" + (capture.training ? "可以观察结果再试，不用使劲压屏幕。" : "")
        }
        if capture.task.kind == .device { return "请用 Apple Pencil 画几条线，在舒服的范围内从轻到稍重。" }
        if capture.task.kind == .emotion {
            return capture.training ? scenario + examples : "请用线条画出“\(capture.task.subject ?? "此刻的感受")”。画法由你决定。"
        }
        if capture.task.kind == .creation {
            return capture.task.phase == .transfer ? "请画一幅关于“\(capture.task.subject ?? "风")”的画。颜色、线条和内容由你决定。" : "用颜色和线条画一个自己的故事，画什么由你决定。"
        }
        return capture.training ? "给你选的\(BackgroundRenderer.names[capture.activity?.drafts["outline"] ?? "cat"] ?? "线稿")上色，颜色由你决定。" : "请给这张线稿上色，颜色由你决定。"
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(instructionText)
            NarrationButton(research: research, text: instructionText, key: capture.trialID + "-instruction")
            if capture.task.kind == .device {
                Text(capture.rehearsal ? "演练允许手指试画；手指数据不会记为真实压感。" : "此处只检查设备信号，不评价画得怎样。").font(.caption)
            }
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scenario: String {
        switch capture.task.subject {
        case "平静": "想一想：午后，你坐在安静的窗边。你想用怎样的线条画出这种感觉？"
        case "开心": "想一想：你和朋友在玩喜欢的游戏。你想用怎样的线条画出这种感觉？"
        default: "想一想：轮到你上台说话了。你想用怎样的线条画出有点紧张的感觉？"
        }
    }
    private var examples: String {
        "可以试试长线或短线、靠近或分开的线、转弯或来回的线。不同画法都可以，选你自己的。"
    }

    private var outlinePicker: some View {
        VStack(spacing: 24) {
            Text("先选一张熟悉的线稿").font(.title2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 18)], spacing: 18) {
                ForEach(BackgroundRenderer.subjects, id: \.self) { subject in
                    Button { Task { await capture.chooseOutline(subject) } } label: {
                        VStack {
                            let image = InkRenderer.background(.init(title: "preview", deviceModel: "preview", osVersion: "", background: .init(kind: "outline", subject: subject)))
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
                            Text(BackgroundRenderer.names[subject] ?? subject).font(.headline)
                        }.padding().frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: 850)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            if !sidebar { HStack(spacing: 20) { palette; if !capture.controlled { brush }; input; history } }
            VStack(alignment: .leading, spacing: 10) { palette; if !capture.controlled { brush }; input; history }
        }.disabled(!studio.canDraw || studio.isDrawing)
    }
    @ViewBuilder private var palette: some View {
        if capture.monochrome { Text("线条墨色").font(.caption).foregroundStyle(StudioTheme.muted) }
        else {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 8), count: sidebar ? 3 : 6), alignment: .leading, spacing: 6) {
            ForEach(studio.palette) { color in
                Button { studio.setBrush(.init(color: color, size: studio.brush.size)) } label: {
                    ResearchColorSwatch(id: color.id, size: 32, hex: color.hex).padding(5)
                        .overlay(Circle().stroke(studio.brush.color.id == color.id ? StudioTheme.ink : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
        }
        }
    }
    private var brush: some View {
        HStack(spacing: 8) {
            Text("宽 \(Int(studio.brush.size))").font(.caption.monospacedDigit()).frame(width: 48)
            Slider(value: Binding(get: { studio.brush.size }, set: { studio.setBrush(.init(color: studio.brush.color, size: $0)) }),
                in: BrushStyle.sizeRange, step: 1).frame(minWidth: 130, maxWidth: 200).accessibilityLabel("笔刷宽度")
        }
    }
    @ViewBuilder private var input: some View {
        if capture.rehearsal {
            Toggle("手指预览", isOn: Binding(get: { studio.fingerInputEnabled }, set: { studio.setFingerInput($0) }))
                .font(.caption).fixedSize().accessibilityIdentifier("researchFingerInput")
        }
    }
    @ViewBuilder private var history: some View {
        if !capture.controlled {
            HStack {
                Button { studio.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(!studio.canUndo)
                Button { studio.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }.disabled(!studio.canRedo)
            }.buttonStyle(.bordered)
        }
    }

    private var result: some View {
        let layout = sidebar ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            if let reference = capture.reference, reference.finished {
                Text(reference.valid == true ? "本次已保存" : "本次已保存，但设备数据不足，请重新记录。 ").font(.subheadline)
                if capture.training || reference.valid != true {
                    Button(capture.controlled ? "再试一笔" : "新纸再试") { Task { await capture.prepare(retry: true) } }.buttonStyle(.bordered)
                }
                if capture.controlled, capture.trialIndex + 1 < capture.trials.count {
                    Button("下一条") { Task { await capture.nextTrial() } }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(reference.valid != true)
                }
                if capture.training, let coverage = reference.metrics["pathCoverage"], capture.task.kind == .path {
                    Text("本次路径覆盖 \(Int(coverage * 100))% ").font(.caption)
                }
                if !capture.controlled {
                    Button("作品预览") { Task { await loadPreview() } }.buttonStyle(.bordered).accessibilityIdentifier("drawingArtworkPreview")
                }
            } else if capture.controlled {
                Text(capture.busy ? "正在保存本次笔迹" : "抬笔后自动保存这一笔").font(.caption)
            } else {
                Text(studio.saveLabel).font(.caption)
                Button("保存这次绘画") { Task { await capture.finish() } }
                    .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(studio.visibleCount == 0 || studio.isDrawing || !studio.canDraw)
            }
        }.disabled(capture.busy || research.locked)
    }

    private func loadPreview() async {
        do { preview = try await ArtworkLoader.preview(studio.storedDocument(), title: capture.task.label) }
        catch { capture.error = error.localizedDescription }
    }
}
