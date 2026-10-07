import SwiftUI
import InkStudyCore

enum StudioTheme {
    static let ink = Color(red: 0.12, green: 0.23, blue: 0.23)
    static let muted = Color(red: 0.40, green: 0.47, blue: 0.44)
    static let accent = Color(red: 0.16, green: 0.39, blue: 0.34)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let line = Color(red: 0.83, green: 0.86, blue: 0.80)
}

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var showLibrary = false
    @State private var preview: ArtworkPreview?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            VStack(spacing: 20) {
                header(wide: wide)
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        tools(compact: false).frame(width: 226)
                        paper
                    }
                } else {
                    paper
                    tools(compact: true)
                }
                footer
            }
            .padding(wide ? 28 : 20)
            .background {
                LinearGradient(colors: [StudioTheme.paper, Color(red: 0.89, green: 0.93, blue: 0.89)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
        }
        .foregroundStyle(StudioTheme.ink)
        .tint(StudioTheme.accent)
        .sheet(isPresented: $showLibrary) { librarySheet }
        .fullScreenCover(item: $preview) { ArtworkPreviewScreen(artwork: $0) }
        .sheet(item: $model.shareFiles) { files in ExportPreview(files: files) }
        .alert("绘画记录", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private func header(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("INK STUDY  /  原生原型").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(StudioTheme.muted)
                Text("绘画记录").font(.custom("SongtiSC-Regular", size: wide ? 34 : 29))
            }
            Spacer(minLength: 8)
            Button {
                Task {
                    do { preview = try await ArtworkLoader.preview(model.storedDocument()) }
                    catch { model.notice = error.localizedDescription }
                }
            } label: { Label("预览", systemImage: "photo") }
                .buttonStyle(QuietButtonStyle()).disabled(!model.canDraw || model.isDrawing)
                .accessibilityIdentifier("studioArtworkPreview")
            Button { showLibrary = true } label: { Label("我的画纸", systemImage: "square.stack.3d.up") }
                .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("libraryButton")
                .disabled(!model.canDraw || model.isDrawing)
            Button { Task { await model.newDocument() } } label: { Label("新画纸", systemImage: "plus") }
                .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("newDrawingButton")
                .disabled(!model.canDraw || model.isDrawing)
            Button { Task { await model.exportDrawing() } } label: {
                Label(model.isBusy ? "处理中" : "导出", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 18).frame(height: 48)
                    .foregroundStyle(.white).background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).accessibilityIdentifier("exportButton")
            .disabled(!model.canDraw || model.isDrawing)
        }
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自由画纸").font(.system(size: 14, weight: .semibold))
                Text("·").foregroundStyle(StudioTheme.muted)
                Text(model.state?.metadata.title ?? "正在打开").font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
                Spacer()
                Text("不限时").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.55), in: Capsule())
            }
            GeometryReader { geometry in
                let ratio = 1200.0 / 850.0
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    NativeCanvas(model: model)
                    if model.originalCount == 0 && !model.isDrawing {
                        VStack(spacing: 14) {
                            Image(systemName: "pencil.tip.crop.circle").font(.system(size: 38, weight: .ultraLight))
                            Text(model.fingerInputEnabled ? "可以用手指试画" : "选一种颜色，开始画吧")
                                .font(.custom("SongtiSC-Regular", size: 25))
                            Text(model.fingerInputEnabled ? "手指预览没有真实压感" : "轻画细一点，重画粗一点")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(StudioTheme.muted.opacity(0.65)).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    if model.isLoading { ProgressView("正在恢复画纸").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioTheme.line, lineWidth: 1))
                .shadow(color: StudioTheme.ink.opacity(0.07), radius: 18, x: 0, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                Text("当前 \(model.visibleCount) 笔").accessibilityIdentifier("visibleStrokeCount")
                Text("·")
                Text("原始 \(model.originalCount) 笔").accessibilityIdentifier("originalStrokeCount")
                Spacer()
                Text("\(model.sampleCount) 个采样点").monospacedDigit().accessibilityIdentifier("sampleCount")
            }
            .font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
        }
    }

    @ViewBuilder private func tools(compact: Bool) -> some View {
        if compact {
            HStack(alignment: .top, spacing: 24) {
                palette.frame(width: 200)
                brushControls
                historyControls.frame(width: 156)
            }
            .padding(18).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
        } else {
            VStack(alignment: .leading, spacing: 25) {
                palette
                Divider().overlay(StudioTheme.line)
                brushControls
                historyControls
                Divider().overlay(StudioTheme.line)
                inputControls
            }
            .padding(20).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("颜色", detail: "六色起点")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 12) {
                ForEach(model.palette) { color in
                    let selected = model.brush.color == color
                    Button { model.setBrush(.init(color: color, size: model.brush.size)) } label: {
                        Circle().fill(Color(uiColor: InkRenderer.color(color.hex))).frame(width: 44, height: 44)
                            .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(color.id == "yellow" ? StudioTheme.ink : .white) } }
                            .padding(4).overlay(Circle().stroke(selected ? StudioTheme.ink : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).accessibilityLabel(colorName(color.id))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("color-\(color.id)").disabled(!model.canDraw || model.isDrawing)
                }
            }
        }
    }

    private var brushControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("笔刷宽度", detail: "\(Int(model.brush.size))")
            HStack(spacing: 6) {
                ForEach(BrushStyle.presets, id: \.self) { size in
                    Button { model.setBrush(.init(color: model.brush.color, size: size)) } label: {
                        VStack(spacing: 5) {
                            Circle().fill(StudioTheme.ink).frame(width: min(22, 3 + size / 5), height: min(22, 3 + size / 5)).frame(height: 24)
                            Text("\(Int(size))").font(.system(size: 10, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(model.brush.size == size ? StudioTheme.line.opacity(0.8) : .white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).accessibilityLabel("笔刷 \(Int(size))")
                    .accessibilityIdentifier("brush-\(Int(size))")
                }
            }
            Slider(value: Binding(get: { model.brush.size }, set: { model.setBrush(.init(color: model.brush.color, size: $0.rounded())) }), in: BrushStyle.sizeRange, step: 1)
                .accessibilityLabel("笔刷宽度").accessibilityIdentifier("brushSlider")
            BrushPreview(style: model.brush).frame(height: 24).accessibilityHidden(true)
            HStack { Text("轻"); Spacer(); Text("压感效果示意"); Spacer(); Text("重") }
                .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
        }
        .disabled(!model.canDraw || model.isDrawing)
    }

    private var historyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).frame(maxWidth: .infinity).frame(height: 44) }
                    .buttonStyle(HistoryButtonStyle()).disabled(!model.canUndo).accessibilityLabel("撤销").accessibilityIdentifier("undoButton")
                Button { model.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly).frame(maxWidth: .infinity).frame(height: 44) }
                    .buttonStyle(HistoryButtonStyle()).disabled(!model.canRedo).accessibilityLabel("重做").accessibilityIdentifier("redoButton")
            }
            Text("撤销的笔迹仍保留在原始记录里。")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("手指预览", isOn: Binding(get: { model.fingerInputEnabled }, set: { model.setFingerInput($0) }))
                .font(.system(size: 13, weight: .medium)).accessibilityIdentifier("fingerInputToggle")
                .disabled(!model.canDraw || model.isDrawing)
            Text("默认只接收 Pencil。无压感的笔和手指可以试画，但不能用于压力测量。")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.saveError ?? model.startupError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂时停止绘画，避免继续产生未保存数据。").font(.system(size: 13, weight: .semibold))
                        Text(error).font(.system(size: 11)).textSelection(.enabled)
                    }
                    Spacer()
                    Button("重试保存") { model.retrySave() }.accessibilityIdentifier("retrySaveButton")
                }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { savingStatus; Spacer(); pressureStatus; compactInputToggle }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { savingStatus; Spacer(); compactInputToggle }
                    pressureStatus
                }
            }
        }
    }

    private var savingStatus: some View {
        Label(model.saveLabel, systemImage: model.saveError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(model.saveError == nil ? StudioTheme.accent : .red)
            .accessibilityIdentifier("saveStatus")
    }

    private var pressureStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.tip")
            Text(model.pressureLabel)
            if let pressure = model.pressure { Text("\(Int((pressure * 100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing) }
        }.font(.system(size: 12)).foregroundStyle(StudioTheme.muted).accessibilityIdentifier("pressureStatus")
    }

    private var compactInputToggle: some View {
        Toggle("手指预览", isOn: Binding(get: { model.fingerInputEnabled }, set: { model.setFingerInput($0) }))
            .font(.system(size: 12)).fixedSize().scaleEffect(0.9, anchor: .trailing)
            .accessibilityIdentifier("footerFingerInputToggle").disabled(!model.canDraw || model.isDrawing)
    }

    private var librarySheet: some View {
        NavigationStack {
            List(model.library) { drawing in
                Button {
                    showLibrary = false
                    Task { await model.openDocument(drawing.id) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.richtext").font(.system(size: 25)).foregroundStyle(StudioTheme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(drawing.title).font(.headline)
                            Text(String(drawing.id.uuidString.prefix(8))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if drawing.id == model.state?.metadata.id { Text("当前").font(.caption).foregroundStyle(StudioTheme.accent) }
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("document-\(drawing.id.uuidString)")
            }
            .navigationTitle("我的画纸")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { showLibrary = false } } }
            .safeAreaInset(edge: .bottom) { Text("新画纸不会清除旧作品。所有画纸都保存在这台设备上。")
                    .font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.bar) }
        }.presentationDetents([.large])
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(detail).font(.system(size: 11)).foregroundStyle(StudioTheme.muted) }
    }

    private func colorName(_ id: String) -> String {
        ["red": "红色", "orange": "橙色", "yellow": "黄色", "green": "绿色", "blue": "蓝色", "violet": "紫色"][id] ?? id
    }
}

private struct BrushPreview: View {
    let style: BrushStyle
    var body: some View {
        Canvas { context, size in
            for n in 0...120 {
                let t = Double(n) / 120
                let diameter = PressureMapping.diameter(style: style, normalizedForce: 0.04 + t * 0.65) * 0.22
                let rect = CGRect(x: 12 + t * (size.width - 24) - diameter / 2,
                                  y: size.height / 2 + sin(t * .pi * 2) * 2 - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(Color(uiColor: InkRenderer.color(style.color.hex))))
            }
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(height: 44)
            .background(.white.opacity(configuration.isPressed ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct HistoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 18)).background(.white.opacity(configuration.isPressed ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.3)
    }
}

private struct ExportPreview: View {
    let files: ExportFiles
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let image = UIImage(contentsOfFile: files.urls[0].path) {
                        Image(uiImage: image).resizable().scaledToFit().overlay(Rectangle().stroke(StudioTheme.line)).accessibilityIdentifier("exportArtworkPreview")
                    }
                    Text("作品与原始笔迹已导出").font(.title2.weight(.semibold)).accessibilityIdentifier("exportComplete")
                    Text("作品包含 \(files.visibleStrokes) 笔；原始记录保留全部 \(files.allStrokes) 笔、\(files.sampleCount) 个采样点，以及撤销和重做历史。")
                        .font(.body).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("artwork.png  ·  2400 × 1700 作品", systemImage: "photo")
                        Label("raw.json  ·  原始采样、修正与事件历史", systemImage: "curlybraces")
                        Label("samples.csv  ·  采样点表格", systemImage: "tablecells")
                        Label("manifest.json  ·  笔迹数量与 SHA-256 校验", systemImage: "checkmark.shield")
                    }.font(.subheadline)
                    Text("这份副本已保存到本机 App 文稿。点下方按钮可另存到“文件”或发送到你的设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { showShare = true } label: {
                        Label("存储到文件或分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(16)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("shareFilesButton")
                }.padding(24)
            }
            .navigationTitle("导出").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showShare) { ShareSheet(urls: files.urls) }
        }.presentationDetents([.large])
    }
}
