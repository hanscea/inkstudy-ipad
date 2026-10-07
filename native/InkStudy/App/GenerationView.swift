import SwiftUI
import InkStudyCore

struct GenerationView: View {
    @ObservedObject var model: GenerationModel
    @ObservedObject var research: ResearchController
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("InkStudy.bridgeEndpoint") private var endpoint = "http://127.0.0.1:8787"
    @State private var participant = ""
    @State private var candidates: [DocumentMetadata] = []
    @State private var selectedSource: UUID?
    @State private var source: StoredDocument?
    @State private var preview: UIImage?
    @State private var description = ""
    @State private var style = "柔和的绘本插画"
    @State private var consent = false
    @State private var independentTest = false
    @State private var showSettings = false
    @State private var selectedJob: UUID?
    private var participants: [String] { Array(Set(research.records.filter { $0.configuration.purpose != .rehearsal }.map { $0.configuration.participantCode })).sorted() }
    private var eligible: Bool { ResearchProtocol.generationAllowed(participantCode: participant.isEmpty ? nil : participant, records: research.records) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("把草图变成另一幅画").font(.custom("SongtiSC-Regular", size: 31))
                    Text("这是一项独立的万相体验。原画不会被覆盖，生成图不计入绘画成绩或研究评分。").foregroundStyle(StudioTheme.muted)
                    Picker("体验对象", selection: $participant) {
                        Text("独立测试，不关联研究参与者").tag("")
                        ForEach(participants, id: \.self) { Text($0 + " · 测量后体验").tag($0) }
                    }.pickerStyle(.menu)
                    if !eligible {
                        Label("该参与者还未完成包括 V7 在内的全部测量，生成入口暂不开放。", systemImage: "lock.fill")
                            .padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        sourcePicker
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("描述画面内容，不填姓名或个人信息", text: $description, axis: .vertical)
                                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                            Picker("画面风格", selection: $style) {
                                ForEach(["柔和的绘本插画", "明快的平面插画", "水彩插画"], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu)
                            Toggle("我确认有权将这张原画和描述发送至研究者服务器及阿里云万相。", isOn: $consent).font(.subheadline)
                            if participant.isEmpty {
                                Toggle("这是成人或虚构内容的独立测试，不用于绕过儿童测量流程。", isOn: $independentTest).font(.subheadline)
                            } else {
                                Text("服务端还需核准完整访次导出。只上传图像与描述，不上传原始压感和研究回答。").font(.caption)
                            }
                            Text("每次生成 1 张，有 AI 生成水印。可能消耗试用额度或产生 API 费用；失败或等待不应反复新建任务。").font(.caption).foregroundStyle(StudioTheme.muted)
                            Button(model.isBusy ? "正在处理" : "以这张原画生成 1 张") {
                                Task {
                                    guard let source else { return }
                                    let prompt = "根据草图保留基本构图和主要对象，生成一幅适合儿童观看的\(style)。画面内容：\(description.trimmingCharacters(in: .whitespacesAndNewlines))。不要出现文字。"
                                    selectedJob = await model.create(document: source, endpoint: endpoint, prompt: prompt,
                                        participant: participant.isEmpty ? nil : participant, researchRecords: research.records,
                                        consent: consent && (!participant.isEmpty || independentTest))
                                }
                            }.buttonStyle(.borderedProminent).foregroundStyle(.white).controlSize(.large)
                                .disabled(model.isBusy || source == nil || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || description.count > 380 || !consent || (participant.isEmpty && !independentTest))
                        }.padding(20).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let notice = model.notice { Text(notice).foregroundStyle(.red).font(.subheadline) }
                    Divider()
                    Text("生成记录").font(.headline)
                    ForEach(model.records) { record in
                        Button { selectedJob = record.id } label: {
                            HStack(spacing: 14) {
                                if let image = UIImage(contentsOfFile: (model.generated(record) ?? model.original(record)).path) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 90, height: 65).background(.white)
                                }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(record.prompt).font(.subheadline).lineLimit(2)
                                    Text(record.statusLabel).font(.caption).foregroundStyle(StudioTheme.muted)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }.padding(14).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }.padding(26)
            }.background(StudioTheme.paper).foregroundStyle(StudioTheme.ink).tint(StudioTheme.accent)
                .navigationTitle("万相草图体验").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("连接设置") { showSettings = true } }
                }
        }
        .task(id: participant) {
            await studio.start(); model.load(); consent = false; independentTest = false
            await loadSources()
        }
        .task(id: selectedSource) { await loadPreview() }
        .sheet(isPresented: $showSettings) { GenerationSettings(client: model.client) }
        .sheet(isPresented: Binding(get: { selectedJob != nil }, set: { if !$0 { selectedJob = nil } })) {
            if let id = selectedJob { GenerationDetail(model: model, id: id) }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择原画").font(.headline)
            if candidates.isEmpty {
                Text("还没有可用原画。可以返回首页，在“原来的自由画纸”中先画一张。 ").font(.subheadline)
            } else {
                Picker("已保存画纸", selection: $selectedSource) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(candidates) { Text($0.title).tag(Optional($0.id)) }
                }.pickerStyle(.menu)
                if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 260).background(.white).overlay(Rectangle().stroke(StudioTheme.line)) }
            }
        }
    }
    private func loadSources() async {
        do {
            let store = try JournalStore(url: research.directory.appendingPathComponent("drawings.sqlite"))
            let all = try await store.list()
            if participant.isEmpty { candidates = all.filter { $0.context == nil } }
            else if eligible {
                let sessions = Set(research.records.filter { $0.configuration.participantCode == participant && $0.configuration.purpose != .rehearsal }.map(\.id))
                candidates = all.filter { $0.context.map { sessions.contains($0.sessionID) } ?? false }
            } else { candidates = [] }
            selectedSource = candidates.first?.id
            if selectedSource == nil { source = nil; preview = nil }
        } catch { model.notice = error.localizedDescription }
    }
    private func loadPreview() async {
        source = nil; preview = nil; consent = false
        guard let id = selectedSource else { return }
        do {
            let document = try await studio.storedDocument(id)
            let state = try document.replay()
            guard selectedSource == id else { return }
            preview = InkRenderer.artwork(state)
            if !state.visibleStrokeIDs.isEmpty, state.activeStrokeID == nil { source = document }
        } catch { model.notice = error.localizedDescription }
    }
}

private struct GenerationDetail: View {
    @ObservedObject var model: GenerationModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private var record: GenerationRecord? { model.records.first { $0.id == id } }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let record {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(record.statusLabel).font(.headline)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 18) { original(record); generated(record) }
                            VStack(spacing: 18) { original(record); generated(record) }
                        }
                        Text(record.prompt).font(.subheadline)
                        Text("\(record.model) · doodle · is_sketch=true · n=1 · seed=\(record.seed)").font(.caption.monospaced()).textSelection(.enabled)
                        if let taskID = record.remote?.providerTaskID { Text("云端任务：\(taskID)").font(.caption.monospaced()).textSelection(.enabled) }
                        Text("原画、笔迹和生成图各自保留。生成图只用于体验，不替代儿童作品。").font(.caption).foregroundStyle(StudioTheme.muted)
                        HStack {
                            Button("继续查询 / 取回图片") { Task { await model.refresh(id) } }.buttonStyle(.bordered).disabled(model.isBusy)
                            Button("导出原画与生成记录 ZIP") { Task { await model.export(record) } }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(model.isBusy)
                        }
                    }.padding(24)
                }
            }.background(StudioTheme.paper).tint(StudioTheme.accent)
                .navigationTitle("原画与生成图").navigationBarTitleDisplayMode(.inline).toolbar { Button("关闭") { dismiss() } }
        }
        .task {
            while !Task.isCancelled {
                if record?.needsUpdate == true { await model.refresh(id) }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { model.exportURL = nil } })) {
            if let url = model.exportURL { ShareSheet(urls: [url]) }
        }
    }
    private func original(_ record: GenerationRecord) -> some View { image(model.original(record), label: "原画") }
    private func generated(_ record: GenerationRecord) -> some View { image(model.generated(record), label: "AI 生成图") }
    private func image(_ url: URL?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            if let url, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360) }
            else { Text("图片就绪后会显示在这里").foregroundStyle(StudioTheme.muted).frame(height: 220).frame(maxWidth: .infinity) }
        }.padding(14).frame(minWidth: 240, maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct GenerationSettings: View {
    let client: GenerationClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("InkStudy.bridgeEndpoint") private var endpoint = "http://127.0.0.1:8787"
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("研究者的服务端") {
                    TextField("https://你的服务端", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("独立测试可连接同一局域网的 Mac。研究参与者图像只允许 HTTPS；不会跳过证书验证。").font(.footnote)
                    TextField("8 位配对码，不是万相 API Key", text: $code).keyboardType(.numberPad)
                    Text("在 Mac 的 Bridge 工具中生成一次性配对码。万相 API Key 只保存在 Mac 服务端，设备凭证保存在本机钥匙串。").font(.footnote)
                    Button("配对并检查连接") { Task { await pair() } }.disabled(busy)
                    Button("检查已有连接") {
                        Task {
                            busy = true; defer { busy = false }
                            do {
                                let url = try BridgeAddress.normalize(address)
                                let configured = try await client.status(endpoint: url); endpoint = url.absoluteString
                                status = configured ? "连接成功，万相服务已配置。" : "配对连接正常，但服务端尚未配置万相 Key。"
                            } catch { status = error.localizedDescription }
                        }
                    }.disabled(busy)
                    if !status.isEmpty { Text(status).font(.subheadline) }
                }
            }.navigationTitle("连接设置").toolbar { Button("关闭") { dismiss() } }.onAppear { address = endpoint }
        }
    }
    private func pair() async {
        guard code.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else { status = "只输入 8 位设备配对码，不要输入万相 API Key。"; return }
        busy = true; defer { busy = false }
        do {
            let url = try BridgeAddress.normalize(address)
            let preferences = UserDefaults.standard
            let id = preferences.string(forKey: "InkStudy.bridgeDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
            preferences.set(id.uuidString, forKey: "InkStudy.bridgeDeviceID")
            try await client.pair(endpoint: url, code: code, deviceID: id)
            endpoint = url.absoluteString; code = ""
            status = try await client.status(endpoint: url) ? "配对成功，万相服务已配置。" : "配对成功，但服务端尚未配置万相 Key。"
        } catch { status = error.localizedDescription }
    }
}
