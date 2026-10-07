import SwiftUI
import InkStudyCore

struct ResearchRunner: View {
    @ObservedObject var research: ResearchController
    @State private var showStop = false
    @State private var showHelp = false
    @StateObject private var narrator = NarrationController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
        let wide = geometry.size.width > geometry.size.height && geometry.size.width >= 900
        VStack(spacing: wide ? 8 : 14) {
            header
            if let error = research.saveError { ResearchSaveError(message: error) { Task { await research.retry() } } }
            if let state = research.state {
                if let end = state.endReason { ending(end) }
                else if state.isPaused {
                    Spacer()
                    Text("已暂停，记录已保留").font(.custom("SongtiSC-Regular", size: 32))
                    Text("准备好后再继续，不限时。").foregroundStyle(StudioTheme.muted)
                    Button("恢复访次") { Task { await research.perform(.resumed) } }.buttonStyle(.borderedProminent).foregroundStyle(.white).controlSize(.large)
                    Spacer()
                } else if let activity = state.current {
                    let paintedMix = activity.task.kind == .mix && state.configuration.protocolVersion == ResearchProtocol.version
                    let sidebar = wide && (paintedMix || (activity.task.kind.isDrawing && activity.task.kind != .mix))
                    if !sidebar {
                        ResearchTaskHeading(research: research, compact: false) { showHelp = true }
                    }
                    Group {
                        if paintedMix {
                            PigmentMixingView(research: research, task: activity.task, sidebar: sidebar) { showHelp = true }.id(activity.task.id)
                        } else if activity.task.kind.isDrawing && activity.task.kind != .mix {
                            ResearchDrawingView(research: research, task: activity.task, sidebar: sidebar) { showHelp = true }.id(activity.task.id)
                        }
                        else { ResearchActivityView(research: research, activity: activity).id(activity.task.id).disabled(research.locked || state.activeHelp != nil) }
                    }
                    if !sidebar { ResearchTaskSupport(research: research, compact: false) }
                }
            }
            if let error = narrator.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(wide ? 12 : 22)
        }
            .environmentObject(narrator)
            .onAppear {
                let controller = research, speech = narrator
                controller.stopHintAudio = { [weak speech] in speech?.stop() }
                speech.onPlayback = { [weak controller] key, kind in
                    guard key.hasPrefix("hint-"), let id = UUID(uuidString: String(key.dropFirst(5))) else { return }
                    controller?.hintDelivered(id, kind: kind)
                }
            }
            .onChange(of: research.current?.task.id) { _, _ in narrator.stop() }
            .onChange(of: research.state?.isPaused) { _, paused in if paused == true { narrator.stop() } }
            .onChange(of: research.state?.activeHelp?.id) { _, _ in narrator.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { narrator.stop() } }
            .onDisappear { narrator.stop() }
            .task(id: research.current?.task.id) {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    await research.automaticHint()
                }
            }
            .sheet(isPresented: $showHelp) { OperatorHelpSheet(research: research) }
            .confirmationDialog("停止这个访次？已保存的数据不会删除。", isPresented: $showStop, titleVisibility: .visible) {
                Button("登记为提前停止", role: .destructive) { Task { await research.perform(.stopped(.stopped)) } }
                Button("登记设备故障停止") { Task { await research.perform(.stopped(.technicalError)) } }
                Button("继续当前访次", role: .cancel) { }
            }
    }

    private var header: some View {
        HStack {
            Button("返回首页") { Task { _ = await research.leave() } }.disabled(research.isBusy || research.saveError != nil)
            Spacer()
            if let state = research.state {
                Text("\(state.configuration.participantCode) / \(state.configuration.visit.rawValue) / \(state.configuration.group.rawValue) 组")
                    .font(.system(size: 12, design: .monospaced))
                Text("\(min(state.currentIndex + 1, state.activities.count))/\(state.activities.count)").font(.caption.monospacedDigit())
                if state.endReason == nil {
                    if !state.isPaused { Button("休息") { Task { await research.perform(.paused) } }.disabled(research.isBusy) }
                    Button("停止", role: .destructive) { showStop = true }.disabled(research.isBusy)
                }
            }
        }
    }

    private func ending(_ reason: ResearchEndReason) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: reason == .completed ? "checkmark.circle" : "pause.circle").font(.system(size: 58, weight: .light))
            Text(reason == .completed ? "本次记录已完成" : "本次已停止，记录已保留").font(.custom("SongtiSC-Regular", size: 32))
            Text("ZIP 包含访次事件、回答、协助记录、全部画纸与原始触控数据。").font(.subheadline)
            if let record = research.record {
                LatestArtworkPreview(record: record, directory: research.directory) { research.artworkRecord = record }
                Button("查看作品预览") { research.artworkRecord = record }.buttonStyle(.bordered)
                Button("导出本次研究 ZIP") { Task { await research.export(record) } }.buttonStyle(.borderedProminent).foregroundStyle(.white).controlSize(.large)
            }
            Text(research.saveLabel).font(.caption)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct ResearchTaskHeading: View {
    @ObservedObject var research: ResearchController
    let compact: Bool
    let showHelp: () -> Void
    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 20))
        layout {
            if let activity = research.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.task.label).font(.custom("SongtiSC-Regular", size: compact ? 23 : 28))
                    Text(activity.task.phase == .training ? "练习 · 不限时 · 可以再试" : "独立记录 · 不限时")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if research.state?.activeHelp != nil {
                Button("结束专员协助") { Task { await research.perform(.helpFinished) } }.buttonStyle(.borderedProminent).foregroundStyle(.white)
            } else { Button("专员操作协助", action: showHelp).buttonStyle(.bordered).disabled(research.locked) }
        }
    }
}

struct ResearchTaskSupport: View {
    @ObservedObject var research: ResearchController
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 10) {
            if let activity = research.current, let state = research.state {
                if state.activeHelp != nil { Text("专员协助计时中，结束协助后继续作答。").font(.caption) }
                if activity.task.phase == .training, [.fixed, .adaptive].contains(state.configuration.group), ![.device, .paper].contains(activity.task.kind) {
                    if research.usesMultimodalHints {
                        if let support = research.visibleHint {
                            MultimodalHintCard(research: research, support: support, compact: compact)
                        } else {
                            Button { Task { await research.requestHint() } } label: {
                                Label(research.hintBusy ? "正在看看刚才的操作…" : "看示范 · 听提示 \(activity.feedback.filter(\.allowed).count)/3", systemImage: "hand.draw.fill")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                            }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                                .disabled(research.hintBusy || research.locked || state.activeHelp != nil)
                                .accessibilityIdentifier("requestVisualHint")
                            if let previous = activity.feedback.last(where: \.allowed),
                               previous.multimodal?.evidence.drawingID == research.canvas?.state?.metadata.id {
                                Button("再看刚才的提示") { research.visibleHint = previous }
                                    .buttonStyle(.bordered).disabled(research.locked || state.activeHelp != nil)
                            }
                        }
                    } else {
                    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
                    layout {
                        Button("看看提示 \(activity.feedback.filter(\.allowed).count)/3") { Task { await research.requestHint() } }
                            .buttonStyle(.bordered).disabled(research.locked || state.activeHelp != nil)
                        Text(activity.feedback.last(where: \.allowed)?.text ?? "先试一次，需要时可以查看提示。")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        if let feedback = activity.feedback.last(where: \.allowed), let text = feedback.text {
                            NarrationButton(research: research, text: text, key: feedback.id.uuidString, kind: .feedback, feedbackID: feedback.id)
                        }
                    }.padding(10).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
                layout {
                    Text(research.saveLabel).font(.caption).foregroundStyle(StudioTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    Button("完成本项，继续") { Task { await research.finishTask() } }
                        .buttonStyle(.borderedProminent).foregroundStyle(.white).controlSize(.large)
                        .disabled(research.locked || state.completionProblem != nil || state.activeHelp != nil)
                        .accessibilityIdentifier("completeResearchTask")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OperatorHelpSheet: View {
    @ObservedObject var research: ResearchController
    @Environment(\.dismiss) private var dismiss
    @State private var kind: OperatorHelpKind = .tools
    @AppStorage("InkStudy.operatorCode") private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("专员代号", text: $code).autocorrectionDisabled().textInputAutocapitalization(.characters)
                Picker("协助类别", selection: $kind) { ForEach(OperatorHelpKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text(kind.script)
                Text("B、C 组执行相同的操作协助规则。学习提示由任务界面提供；专员不补充答案或评价作品。 ").font(.footnote)
                Button("开始协助并计时") {
                    Task { if await research.perform(.helpStarted(kind: kind, operatorCode: code)) { dismiss() } }
                }.disabled(code.isEmpty || research.isBusy)
            }.navigationTitle("专员操作协助").toolbar { Button("取消") { dismiss() } }
        }
    }
}
