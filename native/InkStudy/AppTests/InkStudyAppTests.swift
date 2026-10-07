import XCTest
import UIKit
import InkStudyCore
@testable import InkStudy

@MainActor
final class InkStudyAppTests: XCTestCase {
    private func document() throws -> StoredDocument {
        let metadata = DocumentMetadata(title: "Synthetic renderer test")
        let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
        let strokeID = UUID()
        let samples = (0...500).map { n in
            TouchSample(uptime: Double(n) / 120, x: 100 + Double(n) * 2, y: 425,
                        force: 4 * (0.02 + Double(n) / 500 * 0.65), maximumPossibleForce: 4)
        }
        return StoredDocument(metadata: metadata, events: [
            DrawingEvent(documentID: metadata.id, sequence: 1,
                         payload: .strokeBegan(strokeID: strokeID, style: .init(color: InkColor.palette[0], size: 96), transform: transform, samples: samples)),
            DrawingEvent(documentID: metadata.id, sequence: 2, payload: .strokeEnded(strokeID: strokeID, reason: .lifted))
        ])
    }

    func testRendererHasStrongPressureContrastAndWhiteBackground() throws {
        let state = try document().replay()
        let image = InkRenderer.artwork(state, scale: 1)
        XCTAssertEqual(image.size, CGSize(width: 1200, height: 850))
        let attachment = XCTAttachment(image: image); attachment.name = "Synthetic pressure ramp (not Pencil data)"; attachment.lifetime = .keepAlways; add(attachment)
        let bytes = try rgba(image)
        func countInk(at x: Int) -> Int { (0..<850).filter { y in bytes[(y * 1200 + x) * 4 + 1] < 200 }.count }
        XCTAssertGreaterThan(countInk(at: 1050), countInk(at: 150) * 3)
        XCTAssertGreaterThan(countInk(at: 600), countInk(at: 150))
        XCTAssertEqual(bytes[0], 255); XCTAssertEqual(bytes[1], 255); XCTAssertEqual(bytes[2], 255)
        for x in 150...1050 { XCTAssertLessThan(bytes[(425 * 1200 + x) * 4 + 1], 200, "gap at x=\(x)") }
    }

    func testExportWritesVerifiedPNGJSONCSVAndManifest() async throws {
        let document = try document()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkStudyExportTests-\(UUID().uuidString)")
        let files = try await ExportService.create(document: document, root: directory)
        XCTAssertEqual(files.urls.count, 4)
        for url in files.urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = url.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
        }
        let data = try Data(contentsOf: files.urls[1])
        let raw = try DrawingJSON.decoder().decode(RawDrawingExport.self, from: data)
        XCTAssertEqual(raw.strokes[0].samples.count, 501); XCTAssertEqual(raw.events.count, 2)
        let png = try XCTUnwrap(UIImage(contentsOfFile: files.urls[0].path)?.cgImage)
        XCTAssertEqual(png.width, 2400); XCTAssertEqual(png.height, 1700)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files.urls[3])) as? [String: Any])
        let hashes = try XCTUnwrap(manifest["sha256"] as? [String: String])
        for url in files.urls.prefix(3) { XCTAssertEqual(hashes[url.lastPathComponent], RawDrawingExport.sha256(try Data(contentsOf: url))) }
    }

    func testSparseSamplingHasContinuousJoins() throws {
        let metadata = DocumentMetadata(title: "Synthetic sparse samples")
        let id = UUID()
        let samples = [100.0, 300.0, 500.0, 700.0, 900.0].enumerated().map { index, x in
            TouchSample(uptime: Double(index), x: x, y: 425, force: 2.4, maximumPossibleForce: 4)
        }
        let state = try DrawingState(metadata: metadata, events: [DrawingEvent(documentID: metadata.id, sequence: 1,
            payload: .strokeBegan(strokeID: id, style: .init(color: InkColor.palette[0], size: 20),
                transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples))])
        let bytes = try rgba(InkRenderer.artwork(state, scale: 1))
        for x in 100...899 { XCTAssertLessThan(bytes[(425 * 1200 + x) * 4 + 1], 200, "gap at join x=\(x)") }
    }

    func testExportRetainsHistoryAndCorrectionsButOmitsUndoneInk() async throws {
        let metadata = DocumentMetadata(title: "Synthetic history export", deviceModel: "unit test; no physical Pencil")
        let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
        let a = UUID(), b = UUID(), c = UUID()
        var original = TouchSample(uptime: 1, x: 200, y: 200, force: 0, maximumPossibleForce: 4,
                                   phase: .began, estimationIndex: 101, estimatedProperties: 1, propertiesExpectingUpdates: 1)
        var events: [DrawingEvent] = []
        func append(_ payload: EventPayload) {
            events.append(.init(documentID: metadata.id, sequence: events.count + 1, payload: payload))
        }
        for (index, id) in [a, b, c].enumerated() {
            let input: InputKind = index == 2 ? .finger : .pencil
            let y = 200.0 + Double(index) * 200
            let first = index == 0 ? original : TouchSample(uptime: Double(index + 1), x: 200, y: y,
                force: input == .pencil ? 2 : nil, maximumPossibleForce: input == .pencil ? 4 : nil, input: input, phase: .began)
            append(.strokeBegan(strokeID: id, style: .init(color: InkColor.palette[[0, 4, 3][index]], size: 30), transform: transform, samples: [first]))
            append(.samplesAppended(strokeID: id, samples: [400.0, 600.0].enumerated().map { n, x in
                .init(uptime: Double(index + 1) + Double(n + 1) / 120, x: x, y: y,
                      force: input == .pencil ? 2 : nil, maximumPossibleForce: input == .pencil ? 4 : nil, input: input, source: .coalesced)
            }))
            append(.strokeEnded(strokeID: id, reason: .lifted))
            if id == b { append(.undone(strokeID: b)); append(.redone(strokeID: b)); append(.undone(strokeID: b)) }
        }
        original.force = 0.8; original.source = .estimatedUpdate; original.estimatedProperties = 0; original.propertiesExpectingUpdates = 0
        append(.samplesRevised(strokeID: a, samples: [original]))
        let document = StoredDocument(metadata: metadata, events: events)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InkStudyHistoryExport-\(UUID().uuidString)")
        let files = try await ExportService.create(document: document, root: root)
        XCTAssertEqual(files.visibleStrokes, 2); XCTAssertEqual(files.allStrokes, 3); XCTAssertEqual(files.sampleCount, 9)
        let raw = try DrawingJSON.decoder().decode(RawDrawingExport.self, from: Data(contentsOf: files.urls[1]))
        XCTAssertEqual(raw.visibleStrokeIDs, [a, c]); XCTAssertTrue(raw.redoStrokeIDs.isEmpty)
        XCTAssertEqual(raw.strokes[0].samples[0].force, 0.8)
        guard case .strokeBegan(_, _, _, let captured) = raw.events[0].payload else { return XCTFail("missing original capture") }
        XCTAssertEqual(captured[0].force, 0)
        XCTAssertTrue(raw.strokes[2].samples.allSatisfy { $0.force == nil && $0.normalizedForce == nil })
        let bytes = try rgba(XCTUnwrap(UIImage(contentsOfFile: files.urls[0].path)))
        let bluePixels = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] < 80 && (80...130).contains(bytes[$0 + 1]) && (140...210).contains(bytes[$0 + 2])
        }.count
        XCTAssertEqual(bluePixels, 0, "Undone blue stroke must not appear in PNG")
        for url in files.urls {
            let attachment = XCTAttachment(contentsOfFile: url); attachment.name = url.lastPathComponent
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
