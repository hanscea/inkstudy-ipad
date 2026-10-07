import SwiftUI
import InkStudyCore

struct ResearchHome: View {
    @ObservedObject var research: ResearchController
    @ObservedObject var studio: StudioModel
    @ObservedObject var generation: GenerationModel
    @State private var showSetup = false
    @State private var showFree = false
    @State private var practiceModule: String?
    @State private var showGeneration = false

    var body: some View {
        NavigationStack {
            Group {
                if research.record != nil { ResearchRunner(research: research) }
                else { home }
            }
            .background(LinearGradient(colors: [StudioTheme.paper, Color(red: 0.88, green: 0.93, blue: 0.89)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
            .foregroundStyle(StudioTheme.ink).tint(StudioTheme.accent)
        }
        .task { await research.start() }
        .sheet(isPresented: $showSetup) { ResearchSetup(research: research) }
        .sheet(isPresented: $showGeneration) { GenerationView(model: generation, research: research, studio: studio) }
        .sheet(isPresented: Binding(get: { practiceModule != nil }, set: { if !$0 { practiceModule = nil } })) {
            PracticePicker(module: practiceModule ?? "色彩", research: research)
        }
        .fullScreenCover(isPresented: $showFree) {
            NavigationStack {
                StudioView(model: studio).task { await studio.start() }
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回首页") {
                        Task {
                            studio.interruptCanvas?(.navigation); studio.endActive(.navigation)
                            do { try await studio.flush(); showFree = false } catch { studio.notice = error.localizedDescription }
                        }
                    } } }
            }
        }
        .sheet(isPresented: Binding(get: { research.exportURL != nil }, set: { if !$0 { research.exportURL = nil } })) {
            if let url = research.exportURL { ShareSheet(urls: [url]) }
        }
        .sheet(item: $research.artworkRecord) { ResearchArtworkGallery(record: $0, directory: research.directory) }
        .alert("研究记录", isPresented: Binding(get: { research.notice != nil }, set: { if !$0 { research.notice = nil } })) {
            Button("知道了", role: .cancel) { research.notice = nil }
        } message: { Text(research.notice ?? "") }
        .tint(StudioTheme.accent)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("INK STUDY / 绘画与探索").font(.system(size: 12, design: .monospaced)).tracking(2)
                        Spacer()
                        Text("0911V4").font(.caption.monospaced()).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.7), in: Capsule()).accessibilityIdentifier("releaseLabel")
                    }
                    Text("从颜色，到线条，再到自己的故事。")
                        .font(.custom("SongtiSC-Regular", size: 34))
                    Text("模块练习不限时，过程自动保存在这台 iPad。研究采集请从下方的访次入口进入。")
                        .font(.subheadline).foregroundStyle(StudioTheme.muted)
                }.padding(.top, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 18) {
                    module("01", "色彩", "调出间色 · 摆放色环 · 线稿上色", "paintpalette", Color(red: 0.86, green: 0.68, blue: 0.35))
                    module("02", "线条", "力度变化 · 走出路径 · 情境表达", "scribble.variable", Color(red: 0.43, green: 0.64, blue: 0.60))
                    module("03", "综合创作", "把颜色与线条放进自己的画面", "pencil.and.outline", Color(red: 0.64, green: 0.72, blue: 0.80))
                }
                HStack(spacing: 18) {
                    Button { showSetup = true } label: { Label("新建研究访次", systemImage: "list.bullet.clipboard") }
                        .buttonStyle(.borderedProminent).foregroundStyle(.white).accessibilityIdentifier("newResearchVisit")
                    Button { showFree = true } label: { Label("原来的自由画纸", systemImage: "square.stack.3d.up") }.buttonStyle(.bordered)
                }.controlSize(.large)
                Button { showGeneration = true } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28, weight: .light))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("万相草图体验").font(.headline)
                            Text("独立体验入口，原画与 AI 生成图分别保存。研究参与者须先完成全部测量。").font(.caption)
                        }
                        Spacer(); Image(systemName: "arrow.right")
                    }.padding(20).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityIdentifier("wanxExperience")
                if let error = research.saveError { ResearchSaveError(message: error) { Task { await research.retry() } } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("访次与练习记录").font(.headline)
                    if research.records.isEmpty { Text("还没有研究记录。原有自由画纸在上方入口中。 ").foregroundStyle(StudioTheme.muted) }
                    ForEach(research.records) { record in
                        let state = try? record.replay()
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(record.configuration.participantCode) · \(record.configuration.visit.rawValue) · \(record.configuration.visit.label)").font(.headline)
                                Text("\(record.configuration.purpose == .rehearsal ? "演练" : "预实验") / \(record.configuration.group.rawValue) 组 · \(state?.endReason == .completed ? "已完成" : state?.endReason != nil ? "已停止" : "可继续")")
                                    .font(.caption).foregroundStyle(StudioTheme.muted)
                            }
                            Spacer()
                            Button(state?.endReason == nil ? "继续" : "查看") { Task { await research.open(record.id) } }.buttonStyle(.bordered)
                            if state?.allDrawingIDs.isEmpty == false {
                                Button("作品预览") { Task { await research.preview(record) } }.buttonStyle(.bordered)
                            }
                            Button("导出 ZIP") { Task { await research.export(record) } }.buttonStyle(.bordered)
                        }.padding(18).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Text(ResearchProtocol.formalUnavailable).font(.caption).foregroundStyle(StudioTheme.muted)
            }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
    }

    private func module(_ number: String, _ title: String, _ detail: String, _ symbol: String, _ color: Color) -> some View {
        Button { practiceModule = title } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text(number).font(.system(size: 15, design: .monospaced)); Spacer(); Image(systemName: symbol).font(.system(size: 34, weight: .light)) }
                Spacer(minLength: 15)
                Text(title).font(.custom("SongtiSC-Regular", size: 31))
                Text(detail).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                Label("开始模块练习", systemImage: "arrow.right").font(.subheadline.weight(.semibold))
            }.padding(24).frame(minHeight: 245, alignment: .leading)
                .foregroundStyle(StudioTheme.ink).background(color.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityIdentifier("module-\(number)")
    }
}

private struct PracticePicker: View {
    let module: String
    @ObservedObject var research: ResearchController
    @Environment(\.dismiss) private var dismiss
    @State private var group: ResearchGroup = .fixed
    private var kinds: [ResearchTaskKind] { module == "色彩" ? [.mix, .wheel, .coloring] : module == "线条" ? [.pressure, .path, .emotion] : [.creation] }
    var body: some View {
        NavigationStack {
            Form {
                Section("提示方式") {
                    Picker("版本", selection: $group) {
                        Text("B：固定提示").tag(ResearchGroup.fixed)
                        Text("C：本地模型选择提示").tag(ResearchGroup.adaptive)
                    }
                    Text("专员只协助设备操作；C 版使用本地学习状态模型和已审核提示，不评价画得好不好。").font(.footnote)
                }
                Section("选择活动") {
                    ForEach(kinds, id: \.self) { kind in
                        Button(kind.label) {
                            Task {
                                await research.create(.init(participantCode: "DEMO-" + String(UUID().uuidString.prefix(8)), purpose: .rehearsal,
                                    group: group, visit: .practice, practiceKind: kind))
                                if research.record != nil { dismiss() }
                            }
                        }.padding(.vertical, 8)
                    }
                }
                Text("这里只产生演练数据，不替代研究访次。不限时，可以暂停后继续。").font(.footnote)
            }.navigationTitle(module).toolbar { Button("关闭") { dismiss() } }
        }
    }
}

private struct ResearchSetup: View {
    @ObservedObject var research: ResearchController
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var purpose: ResearchPurpose = .rehearsal
    @State private var visit: ResearchVisit = .V1a
    @State private var group: ResearchGroup = .fixed
    @State private var order = 0
    @State private var windFirst = true
    @State private var allocation = ""
    private var baseline: Bool { visit == .V1a || visit == .V1b }
    var body: some View {
        NavigationStack {
            Form {
                Section("采集信息") {
                    TextField("参与者代号，不填姓名", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Picker("用途", selection: $purpose) { Text("演练").tag(ResearchPurpose.rehearsal); Text("预实验").tag(ResearchPurpose.pilot) }
                    Picker("访次", selection: $visit) {
                        ForEach(ResearchVisit.allCases.filter { $0 != .practice }, id: \.self) { Text("\($0.rawValue) · \($0.label)").tag($0) }
                    }
                    if baseline { Text("基线：U 组，分组前完成。") }
                    else {
                        Picker("分配组别", selection: $group) {
                            Text("A：纸本人工教学").tag(ResearchGroup.paper)
                            Text("B：数字固定提示").tag(ResearchGroup.fixed)
                            Text("C：数字自适应提示").tag(ResearchGroup.adaptive)
                        }
                        TextField("分配表编号", text: $allocation).autocorrectionDisabled()
                    }
                }
                Section("同一参与者须保持一致") {
                    Picker("前测 / 后测 / 延迟测题本", selection: $order) {
                        ForEach(0..<6, id: \.self) { Text(ResearchProtocol.orders[$0]).tag($0) }
                    }
                    Toggle("综合基线先画风，迁移再画雨", isOn: $windFirst)
                }
                Section {
                    Text("全程不限时。只记录实际用时；疲劳、不同意或设备异常时可以停止并保留记录。")
                    Text(ResearchProtocol.formalUnavailable).font(.footnote)
                    Button("创建并开始") {
                        Task {
                            let id = UUID()
                            await research.create(.init(id: id, participantCode: code.trimmingCharacters(in: .whitespacesAndNewlines),
                                purpose: purpose, group: baseline ? .unassigned : group, visit: visit, formOrder: order,
                                windFirst: windFirst, allocationReference: allocation,
                                protocolVersion: research.records.first(where: {
                                    $0.configuration.participantCode == code.trimmingCharacters(in: .whitespacesAndNewlines) && $0.configuration.purpose == purpose
                                })?.configuration.protocolVersion ?? ResearchProtocol.version))
                            if research.record?.id == id { dismiss() }
                        }
                    }.disabled(research.isBusy || code.isEmpty)
                }
            }.navigationTitle("新建研究访次").toolbar { Button("取消") { dismiss() } }
        }
    }
}

struct ResearchSaveError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text("保存未完成，已暂停操作").font(.headline); Text(message).font(.caption).textSelection(.enabled) }
            Spacer(); Button("重试保存", action: retry).buttonStyle(.borderedProminent).foregroundStyle(.white)
        }.padding().background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}
