import Foundation
import SwiftUI
import UIKit
import InkStudyCore

struct ExportFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
    let directory: URL
    let visibleStrokes: Int
    let allStrokes: Int
    let sampleCount: Int
}

@MainActor
enum ExportService {
    private struct Manifest: Encodable, Sendable {
        let format = "inkstudy-export-v1"
        let rendererVersion = "native-renderer-0911V4"
        let pigmentRendererVersion: String?
        let documentID: UUID
        let exportedAt: Date
        let artworkWidthPixels: Int
        let artworkHeightPixels: Int
        let visibleStrokeCount: Int
        let originalStrokeCount: Int
        let sampleCount: Int
        let eventCount: Int
        let sha256: [String: String]
    }

    static func create(document: StoredDocument, root: URL) async throws -> ExportFiles {
        let state = try document.replay()
        guard state.activeStrokeID == nil else { throw DrawingError.persistence("finish the stroke before exporting") }
        guard let png = InkRenderer.artwork(state).pngData() else { throw DrawingError.persistence("PNG encoding failed") }
        let exportedAt = Date()
        let raw = try RawDrawingExport(document: document, exportedAt: exportedAt)
        let directory = root.appendingPathComponent("Drawing-\(document.metadata.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let urls = try await Task.detached(priority: .userInitiated) {
            let json = try raw.jsonData(), csv = raw.csvData()
            let content = ["artwork.png": png, "raw.json": json, "samples.csv": csv]
            let manifest = Manifest(pigmentRendererVersion: document.metadata.background?.kind == "pigment" ? PigmentSurface.modelVersion(for: document.metadata.background) : nil,
                documentID: document.metadata.id, exportedAt: exportedAt,
                artworkWidthPixels: Int(document.metadata.paperWidth * 2), artworkHeightPixels: Int(document.metadata.paperHeight * 2),
                visibleStrokeCount: raw.visibleStrokeIDs.count, originalStrokeCount: raw.strokes.count,
                sampleCount: raw.strokes.reduce(0) { $0 + $1.samples.count }, eventCount: document.events.count,
                sha256: content.mapValues { RawDrawingExport.sha256($0) })
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, data) in content { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            let manifestData = try DrawingJSON.encoder(pretty: true).encode(manifest)
            try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            for (name, data) in content {
                let written = try Data(contentsOf: directory.appendingPathComponent(name))
                guard written == data else { throw DrawingError.persistence("export verification failed: \(name)") }
            }
            return ["artwork.png", "raw.json", "samples.csv", "manifest.json"].map { directory.appendingPathComponent($0) }
        }.value
        return ExportFiles(urls: urls, directory: directory, visibleStrokes: state.visibleStrokeIDs.count,
                           allStrokes: state.strokes.count, sampleCount: state.sampleCount)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
