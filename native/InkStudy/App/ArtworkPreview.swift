import SwiftUI
import InkStudyCore

struct ArtworkPreview: Identifiable {
    let id: UUID
    let title: String
    let image: UIImage
    let visibleStrokes: Int
    let originalStrokes: Int
}

@MainActor
enum ArtworkLoader {
    static func preview(_ document: StoredDocument, title: String? = nil) throws -> ArtworkPreview {
        let state = try document.replay()
        return ArtworkPreview(id: document.metadata.id, title: title ?? document.metadata.title,
            image: InkRenderer.artwork(state, scale: 1), visibleStrokes: state.visibleStrokeIDs.count, originalStrokes: state.strokes.count)
    }
    static func load(record: ResearchRecord, directory: URL) async throws -> [ArtworkPreview] {
        let state = try record.replay()
        guard !state.allDrawingIDs.isEmpty else { return [] }
        let store = try JournalStore(url: directory.appendingPathComponent("drawings.sqlite"))
        var results: [ArtworkPreview] = []
        for activity in state.activities {
            for (index, reference) in activity.drawings.enumerated() {
                let document = try await store.load(id: reference.id)
                guard !document.events.isEmpty else { continue }
                results.append(try preview(document, title: "\(activity.task.label) · \(index + 1)"))
            }
        }
        return results
    }
}

struct ArtworkPreviewScreen: View {
    let artwork: ArtworkPreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(uiImage: artwork.image).resizable().scaledToFit()
                    .background(.white).overlay(Rectangle().stroke(StudioTheme.line, lineWidth: 1))
                    .accessibilityLabel("作品预览，\(artwork.visibleStrokes) 笔可见笔迹")
                Text("当前 \(artwork.visibleStrokes) 笔 · 原始 \(artwork.originalStrokes) 笔").font(.caption).foregroundStyle(StudioTheme.muted)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioTheme.paper)
                .navigationTitle(artwork.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }.tint(StudioTheme.accent)
    }
}

struct ResearchArtworkGallery: View {
    let record: ResearchRecord
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var works: [ArtworkPreview] = []
    @State private var selected: ArtworkPreview?
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("正在读取已保存的作品") }
                else if let error { Text("作品暂时无法读取：\(error)").padding() }
                else if works.isEmpty { Text("这次记录还没有绘画作品。") }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 20) {
                            ForEach(works) { work in
                                Button { selected = work } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Image(uiImage: work.image).resizable().scaledToFit().background(.white)
                                        Text(work.title).font(.headline)
                                        Text("\(work.visibleStrokes) 笔 · 点开查看大图").font(.caption).foregroundStyle(StudioTheme.muted)
                                    }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
                                }.buttonStyle(.plain).accessibilityIdentifier("artwork-\(work.id.uuidString)")
                            }
                        }.padding(20)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioTheme.paper)
                .navigationTitle("已保存的作品").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }.tint(StudioTheme.accent)
            .task(id: record.id) {
                do { works = try await ArtworkLoader.load(record: record, directory: directory) }
                catch { self.error = error.localizedDescription }
                loading = false
            }
            .fullScreenCover(item: $selected) { ArtworkPreviewScreen(artwork: $0) }
    }
}

struct LatestArtworkPreview: View {
    let record: ResearchRecord
    let directory: URL
    let openGallery: () -> Void
    @State private var work: ArtworkPreview?
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack {
            if let work {
                Button(action: openGallery) {
                    Image(uiImage: work.image).resizable().scaledToFit().frame(maxHeight: 390)
                        .background(.white).overlay(Rectangle().stroke(StudioTheme.line, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel("查看已完成的作品").accessibilityIdentifier("completedArtworkPreview")
            } else if loading { ProgressView("正在读取作品").font(.caption) }
            else if let error { Text("缩略图未加载：\(error)").font(.caption).foregroundStyle(StudioTheme.muted) }
        }.task(id: record.id) {
            do { work = try await ArtworkLoader.load(record: record, directory: directory).last }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
