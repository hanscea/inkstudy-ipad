import SwiftUI
import InkStudyCore

struct ResearchActivityView: View {
    @ObservedObject var research: ResearchController
    let activity: ResearchActivity
    var body: some View {
        Group {
            switch activity.task.kind {
            case .mix: MixingActivity(research: research)
            case .wheel: WheelActivity(research: research)
            case .knowledge: KnowledgeActivity(research: research, activity: activity)
            default: instructions
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.researchColors, research.state?.configuration.colorPaletteVersion == StandardPalette.version ? InkColor.palette : InkColor.legacyPalette)
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { research.current?.drafts[key] ?? "" }, set: { research.draft(key, $0) })
    }
    private func checkBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { research.current?.drafts[key] == "yes" }, set: { research.draft(key, $0 ? "yes" : "no") })
    }
    private var instructions: some View {
        Form {
            switch activity.task.kind {
            case .familiarization:
                Section("开始前") {
                    Text("我们会画一些颜色和线条。你可以慢慢来，也可以休息或说不想画。")
                    Toggle("儿童愿意参加本次活动", isOn: checkBinding("assent"))
                    Text("在不包含任务答案的空白纸上熟悉握笔、颜色和撤销按钮。")
                    Toggle("已完成设备熟悉", isOn: checkBinding("familiarized"))
                }
            case .interview:
                Section("记录儿童原话；未回答时填写“未作答”") {
                    TextField("这张画在画什么？", text: textBinding("meaning"), axis: .vertical).lineLimit(3...6)
                    TextField("你为什么选择这些颜色或线条？", text: textBinding("choices"), axis: .vertical).lineLimit(3...6)
                    TextField("如果再画一次，你想保留或改变什么？", text: textBinding("change"), axis: .vertical).lineLimit(3...6)
                }
            case .experience:
                Section("请让儿童自己选择，不评价回答") {
                    experience("enjoyment", "刚才的活动有趣吗？", ["有趣", "一般", "没意思", "未作答"])
                    experience("difficulty", "刚才画起来怎样？", ["容易", "有点难", "很难", "未作答"])
                    experience("again", "还想再画吗？", ["想", "不确定", "不想", "未作答"])
                }
            case .paper:
                Section("A 组：纸本人工教学") {
                    Text(paperInstructions)
                    Text("本页用于实施记录，不向 A 组呈现数字提示或万相生成。")
                    TextField("实施教师代号", text: textBinding("teacherCode"))
                    TextField("纸本作品编号", text: textBinding("paperArtifactCode"))
                    TextField("实施说明与偏离记录（如无，填写无）", text: textBinding("implementationNotes"), axis: .vertical).lineLimit(3...6)
                    Toggle("已完成本访次的纸本核心活动", isOn: checkBinding("paperCompleted"))
                }
            case .transition:
                Section("接下来，独立完成") {
                    Text("训练部分结束。接下来不提供学习提示，也不显示作答对错。请照读任务说明，让儿童独立完成。")
                    Text("没有倒计时；需要休息时可以暂停。")
                }
            case .rest:
                Section("可以休息一会儿") {
                    Text("放下笔，让手放松一下。准备好后再继续，没有倒计时。")
                    TextField("休息或调整记录（选填）", text: textBinding("restNote"), axis: .vertical)
                }
            default: EmptyView()
            }
        }.scrollContentBackground(.hidden)
    }
    private var paperInstructions: String {
        if activity.task.subject == "色彩" { return "本次完成原色混合、六色色环与线稿上色。保留纸本作品并写上参与者代号和访次。" }
        if research.state?.configuration.visit == .V4 {
            return research.state?.configuration.protocolVersion == ResearchProtocol.version
                ? "本次进行轻、中、较重，以及从细到粗、从粗到细、细到粗再到细的线条练习。使用舒服的力度，保留纸本作品并标注代号与访次。"
                : "本次只进行轻、中、较重线条练习，与数字组 V4 的核心活动一致。使用舒服的力度，不要求使劲压笔。保留纸本作品并标注代号与访次。"
        }
        return "本次进行直线、波浪和圆形路径，以及平静、开心、紧张的情境线条练习，与数字组 V5 的核心活动一致。画法不设唯一答案；保留纸本作品并标注代号与访次。"
    }
    private func experience(_ key: String, _ prompt: String, _ choices: [String]) -> some View {
        Picker(prompt, selection: textBinding(key)) {
            Text("请选择").tag("")
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
    }
}

private struct ResearchColorsKey: EnvironmentKey {
    static let defaultValue = InkColor.palette
}
extension EnvironmentValues {
    var researchColors: [InkColor] {
        get { self[ResearchColorsKey.self] }
        set { self[ResearchColorsKey.self] = newValue }
    }
}

struct ResearchColorSwatch: View {
    @Environment(\.researchColors) private var palette
    let id: String
    var size: CGFloat = 58
    var showName = false
    var hex: String?
    var name: String?
    var body: some View {
        VStack(spacing: 8) {
            Circle().fill(Color(uiColor: InkRenderer.color(hex ?? palette.first(where: { $0.id == id })?.hex ?? "#e8e8df")))
                .frame(width: size, height: size).overlay(Circle().stroke(StudioTheme.ink.opacity(0.14), lineWidth: 1))
            if showName { Text(name ?? ColorExercises.names[id] ?? "请选择").font(.caption).lineLimit(1).fixedSize() }
        }.frame(minWidth: size).accessibilityLabel(name ?? ColorExercises.names[id] ?? "空位")
    }
}

private struct KnowledgeActivity: View {
    @ObservedObject var research: ResearchController
    let activity: ResearchActivity
    private var question: ColorQuestion? {
        ColorExercises.questions(form: activity.task.form).first { q in !activity.responses.contains { $0.questionID == q.id } }
    }
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            if let question {
                Text("色卡 \(activity.responses.count + 1) / 14").font(.caption.monospacedDigit()).foregroundStyle(StudioTheme.muted)
                Text(question.prompt).font(.title2).multilineTextAlignment(.center)
                NarrationButton(research: research, text: question.prompt, key: question.id)
                if !question.stimulus.isEmpty {
                    HStack(spacing: 18) { ForEach(Array(question.stimulus.enumerated()), id: \.offset) { item in ResearchColorSwatch(id: item.element, size: 70) } }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(question.options) { option in
                        Button { Task { await research.perform(.answered(questionID: question.id, value: option.id, metrics: [:])) } } label: {
                            HStack(spacing: 10) { ForEach(Array(option.colors.enumerated()), id: \.offset) { item in ResearchColorSwatch(id: item.element) } }
                                .frame(maxWidth: .infinity).frame(height: 110).background(.white, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).accessibilityIdentifier("answer-\(option.id)")
                    }
                }.frame(maxWidth: 850)
                Text("选好后会记录这次选择，然后进入下一张。 ").font(.caption).foregroundStyle(StudioTheme.muted)
            } else { Text("色卡选择已记录").font(.custom("SongtiSC-Regular", size: 30)) }
            Spacer()
        }.padding(24)
    }
}

private struct MixingActivity: View {
    @ObservedObject var research: ResearchController
    @State private var merged = false
    private var target: String { research.current?.drafts["mixTarget"] ?? "orange" }
    private var first: String { StandardPalette.pair(for: target)?[0] ?? "red" }
    private var second: String { StandardPalette.pair(for: target)?[1] ?? "yellow" }
    private var result: String? { ColorExercises.mix(first, second) }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("选择目标间色，使用对应的两种原色练习。 ").font(.title3)
                HStack(spacing: 18) {
                    Text("想调出")
                    ForEach(["orange", "green", "violet"], id: \.self) { id in
                        Button { research.draft("mixTarget", id); merged = false } label: {
                            ResearchColorSwatch(id: id, size: 40, showName: true).padding(10)
                                .background(target == id ? .white : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 36) {
                    ResearchColorSwatch(id: first, size: 46, showName: true)
                    Text("+").font(.largeTitle)
                    ResearchColorSwatch(id: second, size: 46, showName: true)
                }
                ZStack {
                    ResearchColorSwatch(id: first, size: 108).offset(x: merged ? 0 : -62).opacity(merged ? 0 : 1)
                    ResearchColorSwatch(id: second, size: 108).offset(x: merged ? 0 : 62).opacity(merged ? 0 : 1)
                    if merged, let result { ResearchColorSwatch(id: result, size: 128, showName: true).transition(.scale.combined(with: .opacity)) }
                }.frame(height: 165)
                Button("把颜色调在一起") {
                    Task {
                        if await research.perform(.answered(questionID: target, value: first + "+" + second, metrics: [:])) {
                            withAnimation(.easeInOut(duration: 0.7)) { merged = true }
                        }
                    }
                }.buttonStyle(.borderedProminent).foregroundStyle(.white).controlSize(.large).disabled(first.isEmpty || second.isEmpty)
                if merged, let result {
                    Text(result == target ? "调出了目标颜色，还可以换一种组合试试。" : "这次调出了\(ColorExercises.names[result] ?? result)，可以再换一种组合。")
                }
                Text("已尝试 \(Set(research.current?.responses.map(\.questionID) ?? []).count)/3 种目标间色。尝试三种后可继续，不要求全部答对。")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }.padding(20)
        }
    }
}

private struct WheelActivity: View {
    @ObservedObject var research: ResearchController
    @State private var selected = "red"
    private var slots: [String] { (0..<6).map { research.current?.drafts["slot\($0)"] ?? "" } }
    var body: some View {
        VStack(spacing: 16) {
            Text("先选颜色，再点色环的位置。每种颜色用一次。 ").font(.title3)
            NarrationButton(research: research, text: "先选颜色，再点色环的位置。每种颜色用一次。", key: "wheel-instruction")
            HStack(spacing: 16) {
                ForEach(InkColor.palette) { color in
                    Button { selected = color.id } label: {
                        ResearchColorSwatch(id: color.id, size: 42, showName: true).padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == color.id ? StudioTheme.accent : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle().stroke(StudioTheme.line, style: StrokeStyle(lineWidth: 2, dash: [6, 8])).frame(width: size * 0.66, height: size * 0.66).position(center)
                    ForEach(0..<6, id: \.self) { index in
                        let angle = Double(index) * .pi / 3 - .pi / 2
                        Button {
                            if let previous = slots.firstIndex(of: selected), previous != index { research.draft("slot\(previous)", "") }
                            research.draft("slot\(index)", selected)
                        } label: {
                            ResearchColorSwatch(id: slots[index], size: min(70, size * 0.21))
                                .overlay { if slots[index].isEmpty { Text("\(index + 1)").foregroundStyle(StudioTheme.muted) } }
                        }.buttonStyle(.plain).accessibilityLabel("色环位置 \(index + 1)，\(ColorExercises.names[slots[index]] ?? "空位")")
                            .position(x: center.x + cos(angle) * size * 0.33, y: center.y + sin(angle) * size * 0.33)
                    }
                }
            }.frame(minHeight: 250)
            HStack(spacing: 24) {
                Button("清空摆放") { for index in 0..<6 { research.draft("slot\(index)", "") } }.buttonStyle(.bordered)
                Button("检查一次") { Task { await research.perform(.answered(questionID: "wheel", value: slots.joined(separator: ","), metrics: ["neighborMatches": Double(ColorExercises.wheelScore(slots))])) } }
                    .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(Set(slots).count != 6 || slots.contains(""))
                if let response = research.current?.responses.last {
                    Text(response.correct == true ? "六种颜色的相邻关系已连接。" : "已记录这次摆放，可以调整后再检查。 ").font(.subheadline)
                }
            }
        }.padding(16)
    }
}
