import XCTest
import UIKit
import SwiftUI
import InkStudyCore
@testable import InkStudy

private actor FaultInjectingRepository: DrawingRepository {
    enum FailureMode: Sendable { case none, beforeCommit, afterCommit }
    let base: JournalStore
    var failure: FailureMode = .none
    init(url: URL) throws { base = try JournalStore(url: url) }
    func setFailure(_ failure: FailureMode) { self.failure = failure }
    func create(_ metadata: DocumentMetadata) async throws { try await base.create(metadata) }
    func list() async throws -> [DocumentMetadata] { try await base.list() }
    func load(id: UUID) async throws -> StoredDocument { try await base.load(id: id) }
    func append(_ events: [DrawingEvent]) async throws {
        let mode = failure; failure = .none
        if mode == .beforeCommit { throw DrawingError.persistence("injected disk error") }
        try await base.append(events)
        if mode == .afterCommit { throw DrawingError.persistence("injected lost save acknowledgement") }
    }
}

@MainActor
final class StudioModelTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, FaultInjectingRepository) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkStudyModelTests-\(id)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "InkStudyModelTests.\(id)"))
        let repository = try FaultInjectingRepository(url: directory.appendingPathComponent("drawings.sqlite"))
        return (directory, defaults, repository)
    }

    private func draw(_ model: StudioModel, samples: Int = 25, finish: Bool = true) throws -> UUID {
        let id = UUID()
        let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
        XCTAssertTrue(model.beginStroke(id: id, transform: transform, samples: [
            .init(uptime: 10, x: 100, y: 425, force: 0, maximumPossibleForce: 4, phase: .began)
        ]))
        model.appendSamples(strokeID: id, samples: (1...samples).map { n in
            .init(uptime: 10 + Double(n) / 240, x: 100 + Double(n), y: 425,
                  force: 4 * Double(n) / Double(samples), maximumPossibleForce: 4, source: .coalesced)
        })
        if finish { model.endActive(.lifted) }
        return id
    }

    func testActualModelRestoresDrawingSettingsUndoAndRedo() async throws {
        let (directory, defaults, repository) = try fixture()
        let model = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await model.start()
        model.setFingerInput(true); model.setBrush(.init(color: InkColor.palette[5], size: 96))
        let strokeID = try draw(model, samples: 1300)
        model.undo(); try await model.flush()
        let restored = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await restored.start()
        XCTAssertEqual(restored.visibleCount, 0); XCTAssertEqual(restored.originalCount, 1)
        XCTAssertEqual(restored.sampleCount, 1301); XCTAssertEqual(restored.brush.size, 96)
        XCTAssertTrue(restored.fingerInputEnabled); XCTAssertTrue(restored.canRedo)
        restored.redo(); try await restored.flush()
        XCTAssertEqual(restored.state?.visibleStrokeIDs, [strokeID])
        let oldID = try XCTUnwrap(restored.state?.metadata.id)
        await restored.newDocument()
        XCTAssertEqual(restored.library.count, 2); XCTAssertEqual(restored.originalCount, 0)
        await restored.openDocument(oldID)
        XCTAssertEqual(restored.visibleCount, 1); XCTAssertEqual(restored.sampleCount, 1301)
    }

    func testSaveFailureStopsNewInputAndRetryKeepsExactlyOneStroke() async throws {
        for mode in [FaultInjectingRepository.FailureMode.beforeCommit, .afterCommit] {
            let (directory, defaults, repository) = try fixture()
            let model = StudioModel(directory: directory, repository: repository, preferences: defaults)
            await model.start()
            await repository.setFailure(mode)
            _ = try draw(model)
            do { try await model.flush(); XCTFail("expected save failure") } catch { }
            XCTAssertNotNil(model.saveError); XCTAssertFalse(model.canDraw); XCTAssertEqual(model.sampleCount, 26)
            let originalID = model.state?.metadata.id
            await model.newDocument(); XCTAssertEqual(model.state?.metadata.id, originalID)
            model.retrySave(); try await model.flush()
            XCTAssertNil(model.saveError); XCTAssertTrue(model.canDraw)
            let stored = try await repository.load(id: XCTUnwrap(originalID))
            XCTAssertEqual(stored.events.count, 3)
            XCTAssertEqual(try stored.replay().sampleCount, 26)
            XCTAssertEqual(try stored.replay().strokes.count, 1)
        }
    }

    func testModelRecoversPartiallyWrittenStrokeAfterRestart() async throws {
        let (directory, defaults, repository) = try fixture()
        let model = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await model.start(); _ = try draw(model, samples: 100, finish: false); try await model.flush()
        let restored = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await restored.start()
        XCTAssertEqual(restored.sampleCount, 101); XCTAssertEqual(restored.visibleCount, 1)
        XCTAssertFalse(restored.isDrawing); XCTAssertEqual(restored.state?.strokes[0].endReason, .recovered)
        XCTAssertNotNil(restored.notice)
        try await restored.flush()
    }

    func testChunkedCanvasRendersSameGeometryAsExport() async throws {
        let (directory, defaults, repository) = try fixture()
        let model = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await model.start(); model.setBrush(.init(color: InkColor.palette[0], size: 96))
        let canvas = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        canvas.model = model; canvas.synchronize(); canvas.layoutIfNeeded()
        model.didApplyEvent = { [weak canvas] event in canvas?.applyDrawingChange(event) }
        _ = try draw(model, samples: 1000)
        let state = try XCTUnwrap(model.state)
        let expected = InkRenderer.artwork(state, scale: 1)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let actual = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(canvas.bounds); canvas.layer.render(in: renderer.cgContext)
        }
        let a = try rgba(actual), b = try rgba(expected)
        var largeDifferences = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 20 { largeDifferences += 1 }
        XCTAssertLessThan(largeDifferences, 1500, "chunk seams should differ only by edge antialiasing")
        let attachment = XCTAttachment(image: actual); attachment.name = "Chunked canvas synthetic comparison"; attachment.lifetime = .keepAlways; add(attachment)
        model.undo(); XCTAssertEqual(canvas.accessibilityValue, "0笔")
        model.redo(); XCTAssertEqual(canvas.accessibilityValue, "1笔")
        try await model.flush()
    }

    func testStudioLayoutSnapshots() async throws {
        let (directory, defaults, repository) = try fixture()
        let model = StudioModel(directory: directory, repository: repository, preferences: defaults)
        await model.start()
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
            let content = StudioView(model: model).frame(width: size.width, height: size.height).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let pixels = try rgba(image)
            let foreground = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 120 && pixels[$0 + 1] < 120 && pixels[$0 + 2] < 120 }.count
            XCTAssertGreaterThan(foreground, 2000, "Layout snapshot must include controls and text, not an empty image")
            let attachment = XCTAttachment(image: image)
            attachment.name = "SwiftUI layout preview \(Int(size.width))x\(Int(size.height)) (canvas input not tested)"
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
