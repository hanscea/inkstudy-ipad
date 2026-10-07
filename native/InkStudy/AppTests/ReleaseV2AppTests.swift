import XCTest
import UIKit
import InkStudyCore
@testable import InkStudy

@MainActor
final class ReleaseV2AppTests: XCTestCase {
    private let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
    private func research(_ kind: ResearchTaskKind) async -> ResearchController {
        let id = UUID().uuidString
        let research = ResearchController(directory: FileManager.default.temporaryDirectory.appendingPathComponent("V2-" + id), preferences: UserDefaults(suiteName: id)!)
        await research.create(.init(participantCode: "V2_SYNTHETIC", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: kind))
        return research
    }
    private func draw(_ studio: StudioModel, color: String, y: Double = 425) {
        studio.setBrush(.init(color: PigmentSurface.palette(for: studio.state?.metadata.background).first { $0.id == color }!, size: 96,
            pigmentLoadID: PaletteMixing.supports(studio.state?.metadata.background?.pigmentModel) ? UUID() : nil))
        let points = (0..<30).map { TouchSample(uptime: Double($0) / 100, x: 200 + Double($0) * 15, y: y, force: 1.4, maximumPossibleForce: 4) }
        XCTAssertTrue(studio.beginStroke(id: UUID(), transform: transform, samples: points))
        studio.endActive(.lifted)
    }

    func testPigmentMixingSavesThreeAttemptsWithoutAccuracyGateAndKeepsOriginalPapers() async throws {
        let research = await research(.mix)
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.prepare()
        var original: StoredDocument?
        for target in ["orange", "green", "violet"] {
            await capture.prepare(target: target)
            draw(capture.studio, color: capture.first); draw(capture.studio, color: capture.second)
            XCTAssertTrue(capture.pairWasUsed)
            await capture.finish()
            XCTAssertTrue(capture.recorded, capture.error ?? research.notice ?? "not recorded")
            XCTAssertEqual(capture.reference?.valid, true)
            XCTAssertGreaterThan(capture.reference?.metrics["mixedPixels"] ?? 0, 0)
            if original == nil { original = try await capture.studio.storedDocument() }
        }
        XCTAssertEqual(research.current?.responses.count, 3)
        XCTAssertEqual(research.current?.responses.filter { $0.correct == true }.count, 3)
        XCTAssertEqual(research.current?.attemptCount, 3)
        let source = try XCTUnwrap(original)
        let retained = try await capture.studio.storedDocument(source.metadata.id)
        XCTAssertEqual(source.events, retained.events)
        await research.finishTask()
        XCTAssertEqual(research.state?.endReason, .completed)
        let record = try XCTUnwrap(research.record)
        let works = try await ArtworkLoader.load(record: record, directory: research.directory)
        XCTAssertEqual(works.count, 3)
        let archive = try await ResearchExport.create(record: record, directory: research.directory)
        let attachment = XCTAttachment(contentsOfFile: archive); attachment.name = "pigment-synthetic.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPigmentUndoRedoAndNativeRenderingMatchReplay() async throws {
        let research = await research(.mix)
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.prepare()
        let view = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        view.model = capture.studio; view.synchronize(); view.layoutIfNeeded()
        capture.studio.didApplyEvent = { event in view.applyDrawingChange(event) }
        draw(capture.studio, color: "red")
        let red = PigmentSurface(state: try XCTUnwrap(capture.studio.state)).rgba
        draw(capture.studio, color: "yellow")
        let mixed = PigmentSurface(state: try XCTUnwrap(capture.studio.state)).rgba
        XCTAssertNotEqual(red, mixed)
        capture.studio.undo(); XCTAssertEqual(PigmentSurface(state: try XCTUnwrap(capture.studio.state)).rgba, red)
        capture.studio.redo(); XCTAssertEqual(PigmentSurface(state: try XCTUnwrap(capture.studio.state)).rgba, mixed)
        await view.flushPigmentRendering()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let canvas = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
        let exported = InkRenderer.artwork(try XCTUnwrap(capture.studio.state), scale: 1)
        let a = try pixels(canvas), b = try pixels(exported)
        let pixel = (425 * 1200 + 400) * 4
        for channel in 0..<3 { XCTAssertEqual(Int(a[pixel + channel]), Int(b[pixel + channel]), accuracy: 2) }
        let original = try await capture.studio.storedDocument()
        await capture.prepare(retry: true)
        XCTAssertEqual(capture.studio.visibleCount, 0)
        let reloaded = try await capture.studio.storedDocument(original.metadata.id)
        XCTAssertEqual(original.events, reloaded.events)
    }

    func testOutlineIsAboveNewStrokesInCanvasAndExport() async throws {
        let research = await research(.coloring)
        let capture = ResearchDrawingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.chooseOutline("cat")
        let studio = capture.studio
        let view = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        view.model = studio; view.synchronize(); view.layoutIfNeeded()
        studio.didApplyEvent = { event in view.applyDrawingChange(event) }
        let metadata = try XCTUnwrap(studio.state?.metadata)
        let outline = try pixels(InkRenderer.background(metadata))
        for y in stride(from: 150.0, through: 650.0, by: 50) { draw(studio, color: "yellow", y: y) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let native = try pixels(UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) })
        let exported = try pixels(InkRenderer.artwork(try XCTUnwrap(studio.state), scale: 1))
        let linePixels = stride(from: 0, to: outline.count, by: 4).filter { outline[$0] < 60 && outline[$0 + 1] < 75 && outline[$0 + 2] < 65 }
        XCTAssertGreaterThan(linePixels.count, 1000)
        XCTAssertEqual(linePixels.filter { exported[$0 + 1] >= 100 }.count, 0, "Export must retain all opaque outline pixels")
        XCTAssertEqual(linePixels.filter { native[$0 + 1] >= 120 }.count, 0, "New canvas strokes must stay behind the outline")
    }

    func testGuideSilhouetteNarrowsAndWidensWithPressureProfile() throws {
        let ramp = DocumentMetadata(title: "ramp", background: .init(kind: "guide", subject: "pressure", target: 0.15, pressureProfile: .lightToFirm))
        let bytes = try pixels(InkRenderer.background(ramp))
        func thickness(_ x: Int) -> Int { (350..<500).filter { bytes[($0 * 1200 + x) * 4] < 250 }.count }
        XCTAssertGreaterThan(Double(thickness(1000)), Double(thickness(200)) * 1.6)
        let image = InkRenderer.background(ramp)
        let attachment = XCTAttachment(image: image); attachment.name = "0910V2-variable-width-guide"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testArtworkPreviewDoesNotMutateCreationOrGenerateExport() async throws {
        let research = await research(.creation)
        let capture = ResearchDrawingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.start(); draw(capture.studio, color: "red")
        await capture.finish()
        let document = try await capture.studio.storedDocument(), record = try XCTUnwrap(research.record)
        let preview = try ArtworkLoader.preview(document)
        XCTAssertEqual(preview.visibleStrokes, 1)
        let works = try await ArtworkLoader.load(record: record, directory: research.directory)
        XCTAssertEqual(works.count, 1)
        let reloaded = try await capture.studio.storedDocument()
        XCTAssertEqual(document.events, reloaded.events); XCTAssertEqual(research.record, record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: research.directory.appendingPathComponent("Exports").path))
    }

    func testNarrationStopsAndDoesNotSpeakAfterPendingSaveOrRefusal() async {
        let output = StubSpeechOutput()
        let controller = NarrationController(output: output)
        var logged = 0
        await controller.toggle(text: "提示内容", key: "hint") { _ in logged += 1; return true }
        XCTAssertEqual(output.spoken, ["提示内容"]); XCTAssertEqual(logged, 1)
        await controller.toggle(text: "提示内容", key: "hint") { _ in XCTFail("Stop should not log a new request"); return true }
        XCTAssertNil(controller.currentKey)
        await controller.toggle(text: "拒绝请求", key: "blocked") { _ in false }
        XCTAssertEqual(output.spoken.count, 1)
        await controller.toggle(text: "过期请求", key: "pending") { _ in controller.stop(); return true }
        XCTAssertEqual(output.spoken.count, 1)
        output.voiceID = nil
        await controller.toggle(text: "无可用语音", key: "missing") { _ in XCTFail("Missing voice cannot log playback"); return true }
        XCTAssertNotNil(controller.error)
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }
}

@MainActor
private final class StubSpeechOutput: SpeechOutput {
    var voiceID: String? = "synthetic-test-voice"
    var onFinish: (() -> Void)?
    var spoken: [String] = []
    func speak(_ text: String) throws { spoken.append(text) }
    func stop() {}
}
