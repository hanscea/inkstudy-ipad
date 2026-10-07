import SwiftUI
import InkStudyCore

struct MultimodalHintCard: View {
    @ObservedObject var research: ResearchController
    @EnvironmentObject private var narrator: NarrationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let support: ResearchSupport
    var compact = true
    private var key: String { "hint-" + support.id.uuidString }
    var body: some View {
        if let detail = support.multimodal {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("试试这一步", systemImage: "hand.draw").font(.headline)
                    Spacer()
                    Button {
                        narrator.stop(); research.hintDelivered(support.id, kind: .dismissed); research.hideHint()
                    } label: { Image(systemName: "xmark.circle.fill").font(.title2).frame(width: 44, height: 44) }
                        .accessibilityLabel("收起提示").accessibilityIdentifier("dismissHint")
                }
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))
                layout {
                    HintDemonstration(strategy: detail.strategy, target: detail.evidence.target, animate: !reduceMotion)
                        .frame(width: compact ? nil : 160, height: 92).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(detail.strategy.text).font(.custom("PingFangSC-Semibold", size: 23)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("hintInstruction")
                        Button { Task { await speak() } } label: {
                            Label(narrator.currentKey == key ? "停止声音" : "再听一次", systemImage: narrator.currentKey == key ? "stop.fill" : "speaker.wave.2.fill")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).foregroundStyle(.white).accessibilityIdentifier("replayHint")
                    }
                }
                Text(detail.source == "deepseek" ? "DeepSeek 已响应" : detail.source == "fixed" ? "固定提示" : "本地备用提示")
                    .font(.caption).foregroundStyle(StudioTheme.muted).accessibilityIdentifier("hintSource")
            }.padding(16)
                .background(Color(red: 1, green: 0.97, blue: 0.87), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(StudioTheme.accent.opacity(0.7), lineWidth: 2))
                .task(id: support.id) {
                    research.hintDelivered(support.id, kind: .displayed)
                    await speak()
                }
                .onDisappear { if narrator.currentKey == key { narrator.stop() } }
        }
    }
    private func speak() async {
        guard !research.locked, research.state?.activeHelp == nil, research.canvas?.isDrawing != true else { return }
        await narrator.toggle(text: support.text ?? "", key: key) { voice in
            await research.perform(.narrationRequested(text: support.text ?? "", kind: .feedback, feedbackID: support.id, voiceID: voice))
        }
    }
}

struct HintDemonstration: View {
    let strategy: HintStrategy
    let target: String
    var animate = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animate)) { context in
            let t = animate ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 : 0.5
            Canvas { graphics, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                if strategy.rawValue.hasPrefix("mix_") {
                    let pair = StandardPalette.pair(for: target) ?? ["red", "yellow"]
                    for (i, id) in pair.enumerated() {
                        let color = InkColor.palette.first { $0.id == id }!
                        graphics.fill(Path(ellipseIn: CGRect(x: middle.x - 65 + Double(i) * 54, y: middle.y - 28, width: 70, height: 56)), with: .color(Color(uiColor: InkRenderer.color(color.hex)).opacity(0.78)))
                    }
                    var ring = Path(); ring.addEllipse(in: CGRect(x: middle.x - 40, y: middle.y - 30, width: 80, height: 60))
                    graphics.stroke(ring, with: .color(StudioTheme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    if strategy == .mixStir {
                        let point = CGPoint(x: middle.x + cos(t * .pi * 2) * 40, y: middle.y + sin(t * .pi * 2) * 30)
                        graphics.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(StudioTheme.ink))
                    }
                    if let id = strategy.colorID, let color = InkColor.palette.first(where: { $0.id == id }) {
                        let tip = CGPoint(x: middle.x, y: 9 + t * 30)
                        graphics.fill(Path(ellipseIn: CGRect(x: tip.x - 9, y: tip.y - 9, width: 18, height: 18)), with: .color(Color(uiColor: InkRenderer.color(color.hex))))
                    }
                    if strategy == .mixCompare, let color = InkColor.palette.first(where: { $0.id == target }) {
                        graphics.fill(Path(ellipseIn: CGRect(x: size.width - 33, y: 4, width: 26, height: 26)), with: .color(Color(uiColor: InkRenderer.color(color.hex))))
                        graphics.draw(Text("目标").font(.caption), at: CGPoint(x: size.width - 20, y: 42))
                    }
                } else {
                    let start = 20.0, width = max(40, size.width - 40)
                    var guide = Path(); guide.move(to: CGPoint(x: start, y: middle.y)); guide.addLine(to: CGPoint(x: start + width, y: middle.y))
                    graphics.stroke(guide, with: .color(StudioTheme.accent.opacity(0.16)), style: StrokeStyle(lineWidth: 20, lineCap: .round))
                    let profile = PressureProfile(rawValue: target)
                    for index in 0..<40 {
                        let p = Double(index) / 40
                        guard p <= t else { continue }
                        let force = profile?.force(at: p) ?? (strategy == .pressureLighter ? 0.15 : strategy == .pressureFirmer ? 0.4 : 0.3)
                        let radius = 2 + force * 15
                        graphics.fill(Path(ellipseIn: CGRect(x: start + p * width - radius, y: middle.y - radius, width: radius * 2, height: radius * 2)), with: .color(StudioTheme.ink))
                    }
                    graphics.draw(Text(strategy == .pressureLighter ? "轻一点" : strategy == .pressureFirmer ? "稍加一点力" : "慢慢画").font(.headline), at: CGPoint(x: middle.x, y: size.height - 10))
                }
            }
        }
    }
}

struct HintCanvasGuide: View {
    @ObservedObject var research: ResearchController
    @ObservedObject var studio: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let detail = research.visibleHint?.multimodal, detail.evidence.drawingID == studio.state?.metadata.id,
           !studio.isDrawing, !research.locked, research.state?.activeHelp == nil {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width * detail.evidence.focusX, y: geometry.size.height * detail.evidence.focusY)
                Circle().stroke(StudioTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .frame(width: 112, height: 112).position(center)
                if detail.strategy == .mixStir {
                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                        let angle = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate * .pi / 1.5
                        Image(systemName: "hand.point.up.left.fill").font(.system(size: 27)).foregroundStyle(StudioTheme.accent)
                            .position(x: center.x + cos(angle) * 43, y: center.y + sin(angle) * 43)
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
