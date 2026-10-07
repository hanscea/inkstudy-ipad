import SwiftUI
import InkStudyCore

struct HintPreviewHome: View {
    @ObservedObject var research: ResearchController
    @State private var group: ResearchGroup = .adaptive
    @State private var showConnection = false
    @State private var sample = false
    @State private var starting = false
    @State private var bootstrapped = false
    var body: some View {
        NavigationStack {
            Group {
                if starting { ProgressView("准备测试画纸…") }
                else if research.record != nil { ResearchRunner(research: research) }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack {
                                Text("混色与力度提示测试").font(.custom("SongtiSC-Regular", size: 32))
                                Spacer(); Text("0917H1").font(.caption.monospaced())
                            }
                            Text("独立测试 App。原来的“绘画记录”和研究数据保持不变。这里仅用于成人操作或虚构示例。")
                                .foregroundStyle(StudioTheme.muted)
                            HintConnectionSummary(client: research.hintClient) { showConnection = true }
                            Picker("提示组别", selection: $group) {
                                Text("B · 固定动作提示").tag(ResearchGroup.fixed)
                                Text("C · 自适应动作提示").tag(ResearchGroup.adaptive)
                            }.pickerStyle(.segmented).accessibilityIdentifier("hintGroup")
                            Toggle("载入虚构示例笔迹", isOn: $sample).accessibilityIdentifier("hintSyntheticDemo")
                            Text("两组都显示动画并朗读；每项最多三次，间隔至少十五秒。先画一笔，再点“看示范 · 听提示”。")
                            HStack(spacing: 24) {
                                module(.mix, title: "混色", subtitle: "看颜料怎样混在一起", symbol: "paintpalette.fill")
                                module(.pressure, title: "力度", subtitle: "试试轻一点或稳一点", symbol: "pencil.tip.crop.circle")
                            }
                            if !research.records.isEmpty {
                                Text("测试记录").font(.headline)
                                ForEach(research.records.prefix(12)) { record in
                                    HStack {
                                        Text("\(record.configuration.group.rawValue) · \(record.configuration.practiceKind?.label ?? "测试") · \(record.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        Spacer()
                                        Button("查看") { Task { await research.open(record.id) } }
                                        Button("导出") { Task { await research.export(record) } }
                                    }.padding(12).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }.padding(30).frame(maxWidth: 1050).frame(maxWidth: .infinity)
                    }
                }
            }.background(LinearGradient(colors: [StudioTheme.paper, Color(red: 0.87, green: 0.94, blue: 0.90)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
                .foregroundStyle(StudioTheme.ink).tint(StudioTheme.accent)
        }
        .sheet(isPresented: $showConnection) { HintConnectionView(client: research.hintClient) }
        .sheet(isPresented: Binding(get: { research.exportURL != nil }, set: { if !$0 { research.exportURL = nil } })) {
            if let url = research.exportURL { ShareSheet(urls: [url]) }
        }
        .alert("提示测试", isPresented: Binding(get: { research.notice != nil }, set: { if !$0 { research.notice = nil } })) {
            Button("知道了", role: .cancel) { research.notice = nil }
        } message: { Text(research.notice ?? "") }
        .task {
            guard !bootstrapped else { return }; bootstrapped = true
            await research.start()
            #if HINTS_PREVIEW
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--hint-bootstrap") {
                let file = research.directory.deletingLastPathComponent().appendingPathComponent("HintPreviewBootstrap.json")
                struct Bootstrap: Decodable { let endpoint: String; let code: String }
                if let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Bootstrap.self, from: data) {
                    research.hintClient.endpoint = config.endpoint
                    research.hintClient.adultRehearsalConsent = true
                    await research.hintClient.pair(code: config.code)
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if args.contains("--hint-demo-fixed") { group = .fixed }
            if args.contains("--hint-demo-mix") { await start(.mix, sample: true) }
            if args.contains("--hint-demo-pressure") { await start(.pressure, sample: true) }
            #endif
        }
    }
    private func module(_ kind: ResearchTaskKind, title: String, subtitle: String, symbol: String) -> some View {
        Button { Task { await start(kind, sample: sample) } } label: {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol).font(.system(size: 38, weight: .light))
                Text(title).font(.custom("SongtiSC-Regular", size: 30))
                Text(subtitle).font(.headline)
                Label("开始练习", systemImage: "arrow.right")
            }.padding(28).frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityIdentifier("hintModule-" + kind.rawValue)
    }
    private func start(_ kind: ResearchTaskKind, sample: Bool) async {
        starting = true
        defer { starting = false }
        await research.create(.init(participantCode: "HINT-DEMO-" + String(UUID().uuidString.prefix(8)), purpose: .rehearsal,
            group: group, visit: .practice, practiceKind: kind, hintProtocolVersion: MultimodalFeedback.version))
        if sample {
            do { try await HintPreviewDemo.seed(research: research, kind: kind) }
            catch { research.notice = "示例准备失败，仍可手动画一笔。" }
        }
    }
}

private struct HintConnectionSummary: View {
    @ObservedObject var client: HintClient
    let configure: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(client.status).font(.headline).accessibilityIdentifier("hintConnectionStatus")
                Text(client.adultRehearsalConsent ? "成人演练：只发送任务和操作摘要" : "未允许云端调用，使用本地提示").font(.caption)
            }
            Spacer(); Button("连接设置", action: configure).buttonStyle(.bordered)
        }.padding(20).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            .task {
                if !client.endpoint.isEmpty { await client.check() }
            }
    }
}

struct HintConnectionView: View {
    @ObservedObject var client: HintClient
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("连接 Mac 提示服务") {
                    TextField("http://Mac局域网地址:8788", text: $client.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("8 位一次性配对码", text: $code).keyboardType(.numberPad)
                    Button("配对并检查") { Task { await client.pair(code: code); code = "" } }.disabled(client.busy || code.count != 8)
                    Button("检查连接") { Task { await client.check() } }
                    Text(client.status)
                }
                Section("测试数据范围") {
                    Toggle("当前是成人或虚构示例，允许发送操作摘要", isOn: $client.adultRehearsalConsent)
                    Text("仅发送任务类型、目标、笔画数和混色／力度统计。密钥保留在 Mac；不发送姓名、画作、录音或原始触控。此版本不用于真实儿童云端测试。")
                }
                Section { Text("Mac 服务需保持运行，并与 iPad 位于同一可信网络。断网后自动改用本地动作提示。") }
            }.navigationTitle("DeepSeek 提示连接").toolbar { Button("关闭") { dismiss() } }
        }
    }
}

@MainActor
enum HintPreviewDemo {
    static func seed(research: ResearchController, kind: ResearchTaskKind) async throws {
        guard let task = research.current?.task else { return }
        let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
        if kind == .mix {
            let capture = PigmentMixingCoordinator(research: research, task: task)
            await capture.prepare()
            for (color, y) in [("red", 380.0), ("yellow", 445.0)] {
                capture.selectBrush(color)
                let points = (0..<35).map { TouchSample(uptime: Double($0) / 60, x: 320 + Double($0) * 10, y: y, force: 1.4, maximumPossibleForce: 4) }
                guard capture.studio.beginStroke(id: UUID(), transform: transform, samples: points) else { throw DrawingError.invalidEvent("demo_input_failed") }
                capture.studio.endActive(.lifted)
            }
            try await capture.studio.flush()
        } else {
            let capture = ResearchDrawingCoordinator(research: research, task: task)
            await capture.prepare()
            let points = (0..<35).map { TouchSample(uptime: Double($0) / 60, x: 100 + Double($0) * 28, y: 425, force: 2.8, maximumPossibleForce: 4) }
            guard capture.studio.beginStroke(id: UUID(), transform: transform, samples: points) else { throw DrawingError.invalidEvent("demo_input_failed") }
            capture.studio.endActive(.lifted)
            await capture.finish()
            try await capture.studio.flush()
        }
        try await research.flush()
    }
}
