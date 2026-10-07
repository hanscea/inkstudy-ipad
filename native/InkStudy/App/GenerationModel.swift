import SwiftUI
import UIKit
import ImageIO
import InkStudyCore

@MainActor
final class GenerationModel: ObservableObject {
    @Published private(set) var records: [GenerationRecord] = []
    @Published private(set) var isBusy = false
    @Published var notice: String?
    @Published var exportURL: URL?
    let directory: URL
    let client: GenerationClient
    init(directory: URL, client: GenerationClient = GenerationClient()) {
        self.directory = directory.appendingPathComponent("Generations"); self.client = client
    }
    func folder(_ record: GenerationRecord) -> URL { directory.appendingPathComponent(record.id.uuidString) }
    func original(_ record: GenerationRecord) -> URL { folder(record).appendingPathComponent("original/artwork.png") }
    func generated(_ record: GenerationRecord) -> URL? { record.downloadedFile.map { folder(record).appendingPathComponent($0) } }
    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            records = try folders.compactMap { folder in
                let file = folder.appendingPathComponent("generation.json")
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return try DrawingJSON.decoder().decode(GenerationRecord.self, from: Data(contentsOf: file))
            }.sorted { $0.createdAt > $1.createdAt }
        } catch { notice = "生成记录读取失败：\(error.localizedDescription)" }
    }
    private func persist(_ record: GenerationRecord) throws {
        let file = folder(record).appendingPathComponent("generation.json")
        try DrawingJSON.encoder(pretty: true).encode(record).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.insert(record, at: 0) }
    }

    func create(document: StoredDocument, endpoint: String, prompt: String, participant: String?, researchRecords: [ResearchRecord], consent: Bool) async -> UUID? {
        guard !isBusy else { return nil }; isBusy = true
        defer { isBusy = false }
        do {
            let address = try BridgeAddress.normalize(endpoint)
            guard consent, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DrawingError.invalidEvent("请填写画面描述并确认上传授权。") }
            guard ResearchProtocol.generationAllowed(participantCode: participant, records: researchRecords) else { throw DrawingError.invalidEvent("须完成该参与者包括 V7 在内的全部测量。") }
            guard participant == nil || address.scheme == "https" else { throw DrawingError.invalidEvent("研究参与者的图像只通过 HTTPS 连接上传。局域网 HTTP 仅用于独立测试。") }
            let state = try document.replay()
            guard !state.visibleStrokeIDs.isEmpty, state.activeStrokeID == nil else { throw DrawingError.invalidEvent("请先完成并保存原画。") }
            if let context = document.metadata.context {
                guard let participant, researchRecords.contains(where: { $0.id == context.sessionID && $0.configuration.participantCode == participant }) else {
                    throw DrawingError.invalidEvent("研究画纸只能以对应参与者的测量后体验模式使用。")
                }
            }
            guard try BridgeKeychain.token(for: address.absoluteString) != nil else { throw DrawingError.invalidEvent("请先完成服务端配对。") }
            let id = UUID(), destination = directory.appendingPathComponent(id.uuidString)
            let exported = try await ExportService.create(document: document, root: destination)
            let originalFolder = destination.appendingPathComponent("original")
            try FileManager.default.moveItem(at: exported.directory, to: originalFolder)
            let png = try Data(contentsOf: originalFolder.appendingPathComponent("artwork.png")), hash = RawDrawingExport.sha256(png)
            guard png.count <= 10 * 1024 * 1024 else { throw DrawingError.invalidEvent("原图超过 10 MB，暂未上传。原始导出仍保留。") }
            guard !records.contains(where: { $0.sourcePNGHash == hash && $0.remote?.status == "SUBMISSION_UNKNOWN" }) else { throw DrawingError.invalidEvent("同一原画有一项提交结果未知的任务，请先核对云端记录。") }
            let now = DrawingJSON.wallTime(Date())
            let record = GenerationRecord(id: id, endpoint: address.absoluteString, sourceDocumentID: document.metadata.id, sourcePNGHash: hash,
                prompt: prompt, seed: Int.random(in: 0...2147483647), mode: participant == nil ? "independent" : "research", participantCode: participant,
                createdAt: now, consentAt: now, model: "wanx2.1-imageedit", function: "doodle", isSketch: true, watermark: true, imageCount: 1,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0",
                receipts: [], localError: nil, downloadedFile: nil)
            try persist(record)
            await update(record)
            return id
        } catch { notice = error.localizedDescription; return nil }
    }

    func refresh(_ id: UUID) async {
        guard !isBusy, let record = records.first(where: { $0.id == id }) else { return }; isBusy = true
        defer { isBusy = false }; await update(record)
    }
    private func update(_ original: GenerationRecord) async {
        var record = original
        do {
            let remote: RemoteGeneration
            do { remote = try await client.fetch(record) }
            catch let failure as BridgeFailure where failure.code == "not_found" {
                guard record.remote == nil else { throw BridgeFailure(code: "server_record_missing", message: "服务端任务记录缺失，请核对原服务器；不会重新提交。") }
                remote = try await client.submit(record, png: Data(contentsOf: self.original(record)))
            }
            guard remote.id == record.id else { throw DrawingError.invalidEvent("服务端返回的任务编号不匹配。") }
            if remote != record.remote { record.receipts.append(remote) }
            record.localError = nil
            // Store the cloud receipt before downloading, so a restart can resume without another generation.
            try persist(record)
            if remote.status == "SUCCEEDED", record.downloadedFile == nil {
                let data = try await client.image(record)
                guard let expected = remote.resultSHA256, RawDrawingExport.sha256(data) == expected else { throw DrawingError.persistence("生成图校验失败，尚未采用。") }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...8192).contains(width), (1...8192).contains(height) else { throw DrawingError.invalidEvent("生成图格式或尺寸无效。") }
                let filename = remote.resultMimeType == "image/jpeg" ? "generated.jpg" : "generated.png"
                try data.write(to: folder(record).appendingPathComponent(filename), options: .atomic)
                record.downloadedFile = filename; try persist(record)
            }
        } catch {
            record.localError = error.localizedDescription
            do { try persist(record) } catch { notice = "本地保存失败：\(error.localizedDescription)" }
        }
    }

    func export(_ record: GenerationRecord) async {
        guard !isBusy else { return }; isBusy = true
        defer { isBusy = false }
        do {
            let root = folder(record)
            var names = ["generation.json", "original/artwork.png", "original/raw.json", "original/samples.csv", "original/manifest.json"]
            if let image = record.downloadedFile { names.append(image) }
            let entries = names.map { StoredZIP.Entry(name: $0, url: root.appendingPathComponent($0)) }
            let archive = directory.appendingPathComponent("Generation-\(record.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).zip")
            try await Task.detached { try StoredZIP.write(entries, to: archive) }.value
            exportURL = archive
        } catch { notice = "导出未完成：\(error.localizedDescription)" }
    }
}
