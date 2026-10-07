import XCTest
import UIKit
import SwiftUI
import InkStudyCore
@testable import InkStudy

@MainActor
final class PaletteMixingAppTests: XCTestCase {
    private let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
    private func setup(legacy: Bool = false) async throws -> (PigmentMixingCoordinator, DrawingCanvasView, UserDefaults, String) {
        let id = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: id))
        let research = ResearchController(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PaletteV3-" + id), preferences: preferences)
        await research.create(.init(participantCode: "SYNTHETIC_PALETTE", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix))
        if legacy {
            let reference = ResearchDrawingReference(trialID: "mix-orange", background: .init(kind: "pigment", subject: "orange", pigmentModel: SpectralMixing.version))
            let linked = await research.perform(.drawingLinked(reference))
            XCTAssertTrue(linked)
        }
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.prepare()
        let view = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        view.model = capture.studio; view.synchronize(); view.layoutIfNeeded()
        capture.studio.didApplyEvent = { [weak view] in view?.applyDrawingChange($0) }
        await view.flushPigmentRendering()
        return (capture, view, preferences, id)
    }
    private func line(_ count: Int = 80, y: Double = 425) -> [TouchSample] {
        (0..<count).map { .init(uptime: Double($0) / 240, x: 510 + Double($0) * 3, y: y, force: 1.4, maximumPossibleForce: 4) }
    }
    private func draw(_ studio: StudioModel, _ samples: [TouchSample], reason: StrokeEndReason = .lifted) {
        XCTAssertTrue(studio.beginStroke(id: UUID(), transform: transform, samples: samples))
        studio.endActive(reason)
    }

    func testColorTapsReloadButLiftingCancellationAndStirringDoNot() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        let studio = capture.studio
        XCTAssertTrue(capture.palettePaint)
        XCTAssertNil(studio.brush.pigmentLoadID)
        capture.selectBrush("red")
        let first = studio.brush.pigmentLoadID
        XCTAssertNotNil(first); XCTAssertEqual(studio.pigmentLoadFraction, 1)
        draw(studio, line(11), reason: .cancelled)
        await view.flushPigmentRendering()
        XCTAssertEqual(studio.pigmentLoadFraction, 0.78, accuracy: 0.001)
        draw(studio, line(1))
        await view.flushPigmentRendering()
        XCTAssertEqual(studio.brush.pigmentLoadID, first)
        XCTAssertEqual(studio.pigmentLoadFraction, 0.76, accuracy: 0.001)
        capture.selectBrush("red")
        XCTAssertNotEqual(studio.brush.pigmentLoadID, first)
        XCTAssertEqual(studio.pigmentLoadFraction, 1)
        draw(studio, line())
        await view.flushPigmentRendering()
        XCTAssertEqual(studio.pigmentLoadFraction, 0)
        let before = PigmentSurface(state: try XCTUnwrap(studio.state)).pigmentMass
        draw(studio, line())
        capture.stirOnly()
        draw(studio, line())
        let after = PigmentSurface(state: try XCTUnwrap(studio.state)).pigmentMass
        XCTAssertEqual(after.x, before.x, accuracy: 0.1)
        XCTAssertNil(studio.brush.pigmentLoadID)
        XCTAssertFalse(capture.pairWasUsed)
        XCTAssertEqual(studio.pigmentLoadFraction, 0)
    }

    func testEveryTargetAutomaticallyProvidesCorrectSwitchablePrimaries() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        for target in ["green", "violet", "orange", "violet", "green", "orange"] {
            await capture.prepare(target: target)
            XCTAssertTrue(capture.standardPaint)
            XCTAssertEqual([capture.first, capture.second], StandardPalette.pair(for: target))
            XCTAssertEqual(capture.targetColor(target), InkColor.palette.first { $0.id == target })
            for color in [capture.first, capture.second, capture.first, capture.second] {
                capture.selectBrush(color)
                XCTAssertEqual(capture.studio.brush.color, StandardPalette.primaries.first { $0.id == color })
                XCTAssertEqual(capture.studio.pigmentLoadFraction, 1)
                draw(capture.studio, line(3))
                XCTAssertNil(capture.studio.saveError)
            }
            XCTAssertTrue(capture.pairWasUsed)
        }
    }

    func testLoadedBlankPaperKeepsSelectionAcrossTargetSwitchAndRestart() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        await capture.prepare(target: "green")
        capture.selectBrush("blue")
        let brush = capture.studio.brush, id = capture.referenceID
        let before = try await capture.studio.storedDocument()
        await capture.prepare(target: "green")
        XCTAssertEqual(capture.studio.brush, brush)
        await capture.prepare(target: "orange")
        await capture.prepare(target: "green")
        XCTAssertEqual(capture.referenceID, id)
        XCTAssertEqual(capture.studio.brush, brush)
        let after = try await capture.studio.storedDocument()
        XCTAssertEqual(after.events, before.events)
        try await capture.research.flush()
        let research = ResearchController(directory: capture.research.directory, preferences: preferences)
        await research.start()
        let resumed = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await resumed.prepare()
        XCTAssertEqual(resumed.studio.brush, brush)
        XCTAssertEqual([resumed.first, resumed.second], ["yellow", "blue"])
    }

    func testSwitchingCannotChangeAnActiveStrokeButWorksImmediatelyAfterLift() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        capture.selectBrush("red")
        let brush = capture.studio.brush, paper = capture.referenceID
        XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: transform, samples: line(4)))
        capture.selectBrush("yellow")
        await capture.prepare(target: "green")
        XCTAssertEqual(capture.studio.brush, brush)
        XCTAssertEqual(capture.referenceID, paper)
        capture.studio.endActive(.lifted)
        capture.selectBrush("yellow")
        XCTAssertEqual(capture.studio.brush.color.id, "yellow")
        await capture.prepare(target: "green")
        XCTAssertNotEqual(capture.referenceID, paper)
        let selected = capture.studio.brush
        capture.selectBrush("red")
        await capture.prepare(target: "unknown")
        XCTAssertEqual(capture.target, "green")
        XCTAssertEqual(capture.studio.brush, selected)
    }

    func testExistingV3PaperKeepsColorPairAndPixelsUntilNewPaper() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        let reference = ResearchDrawingReference(trialID: "mix-green", background: .init(kind: "pigment", subject: "green", pigmentModel: PaletteMixing.version))
        let linked = await capture.research.perform(.drawingLinked(reference))
        XCTAssertTrue(linked)
        await capture.prepare(target: "green")
        XCTAssertFalse(capture.standardPaint)
        XCTAssertEqual([capture.first, capture.second], ["red", "yellow"])
        capture.selectBrush("red"); draw(capture.studio, line())
        capture.selectBrush("yellow"); draw(capture.studio, line())
        let before = try await capture.studio.storedDocument()
        let pixels = PigmentSurface(state: try before.replay()).rgba
        await capture.prepare(retry: true)
        XCTAssertTrue(capture.standardPaint)
        XCTAssertEqual([capture.first, capture.second], ["yellow", "blue"])
        let retained = try await capture.studio.storedDocument(reference.id)
        XCTAssertEqual(retained.metadata, before.metadata)
        XCTAssertEqual(retained.events, before.events)
        XCTAssertEqual(PigmentSurface(state: try retained.replay()).rgba, pixels)
    }

    func testRestartUndoAndExportPreserveLoadIdentityAndExactArtwork() async throws {
        let (capture, view, preferences, suite) = try await setup()
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        capture.selectBrush("red"); draw(capture.studio, line())
        capture.selectBrush("yellow"); draw(capture.studio, line(20, y: 440))
        await view.flushPigmentRendering()
        let remaining = capture.studio.pigmentLoadFraction
        let before = try await capture.studio.storedDocument()
        try await capture.research.flush()
        let restored = ResearchController(directory: capture.research.directory, preferences: preferences)
        await restored.start()
        let resumed = PigmentMixingCoordinator(research: restored, task: try XCTUnwrap(restored.current?.task))
        await resumed.prepare()
        let restoredView = DrawingCanvasView(frame: view.frame)
        defer { restoredView.stopRendering() }
        restoredView.model = resumed.studio; restoredView.synchronize(); restoredView.layoutIfNeeded()
        resumed.studio.didApplyEvent = { [weak restoredView] in restoredView?.applyDrawingChange($0) }
        await restoredView.flushPigmentRendering()
        XCTAssertEqual(resumed.studio.pigmentLoadFraction, remaining)
        XCTAssertEqual(resumed.studio.brush.pigmentLoadID, capture.studio.brush.pigmentLoadID)
        let after = try await resumed.studio.storedDocument()
        XCTAssertEqual(before.events, after.events)
        XCTAssertEqual(PigmentSurface(state: try before.replay()).rgba, PigmentSurface(state: try after.replay()).rgba)
        resumed.studio.undo(); await restoredView.flushPigmentRendering()
        XCTAssertEqual(resumed.studio.pigmentLoadFraction, 1)
        resumed.studio.redo(); await restoredView.flushPigmentRendering()
        XCTAssertEqual(resumed.studio.pigmentLoadFraction, remaining)
        let files = try await ExportService.create(document: after, root: FileManager.default.temporaryDirectory.appendingPathComponent("PaletteV3Exports"))
        let raw = try DrawingJSON.decoder().decode(RawDrawingExport.self, from: Data(contentsOf: files.directory.appendingPathComponent("raw.json")))
        XCTAssertEqual(raw.metadata.schemaVersion, 2)
        XCTAssertEqual(raw.pigmentMixing, StandardPalette.formula)
        XCTAssertEqual(raw.strokes, try after.replay().strokes)
        let expected = InkRenderer.artwork(try after.replay()).pngData()
        XCTAssertEqual(try Data(contentsOf: files.directory.appendingPathComponent("artwork.png")), expected)
        print("PALETTE_EXPORT_DIRECTORY \(files.directory.path)")
        let attachment = XCTAttachment(contentsOfFile: files.directory.appendingPathComponent("artwork.png"))
        attachment.name = "0911V3-exported-palette"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testOldSpectralPaperIsUnchangedAndRetryCreatesSeparatePalettePaper() async throws {
        let (capture, view, preferences, suite) = try await setup(legacy: true)
        defer { view.stopRendering(); preferences.removePersistentDomain(forName: suite) }
        XCTAssertFalse(capture.palettePaint)
        capture.selectBrush("red"); draw(capture.studio, line())
        capture.selectBrush("yellow"); draw(capture.studio, line())
        let old = try await capture.studio.storedDocument()
        XCTAssertEqual(old.metadata.schemaVersion, 1)
        XCTAssertTrue(try old.replay().strokes.allSatisfy { $0.style.pigmentLoadID == nil })
        let image = PigmentSurface(state: try old.replay()).rgba
        await capture.prepare(retry: true)
        view.synchronize(); view.layoutIfNeeded(); await view.flushPigmentRendering()
        XCTAssertTrue(capture.palettePaint)
        XCTAssertNotEqual(capture.referenceID, old.metadata.id)
        let retained = try await capture.studio.storedDocument(old.metadata.id)
        XCTAssertEqual(retained.metadata, old.metadata)
        XCTAssertEqual(retained.events, old.events)
        XCTAssertEqual(PigmentSurface(state: try retained.replay()).rgba, image)
    }

    func testAllPigmentPairsShowProgressiveMixingVisualFixture() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let titles = ["加完两种颜料", "搅拌 1 圈", "搅拌 4 圈", "搅拌 12 圈"]
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 23, weight: .medium), .foregroundColor: UIColor.darkGray]
        let image: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 990), format: format).image { context in
            UIColor(white: 0.97, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 990))
            for (row, pair) in [[0, 1], [1, 2], [2, 0]].enumerated() {
                var surface = PigmentSurface(modelVersion: StandardPalette.mixingVersion)
                for (i, color) in pair.enumerated() {
                    let brush = BrushStyle(color: StandardPalette.primaries[color], size: 96, pigmentLoadID: UUID())
                    surface.begin(style: brush, samples: line(y: 410 + Double(i) * 30))
                }
                for column in 0..<4 {
                    if column > 0 {
                        let turns = [0, 1, 3, 8][column]
                        let samples = (0...turns * 100).map { i in
                            let angle = Double(i) * 2 * .pi / 100
                            return TouchSample(uptime: Double(i) / 240, x: 588 + cos(angle) * 72, y: 425 + sin(angle) * 30,
                                force: 1.4, maximumPossibleForce: 4)
                        }
                        surface.begin(style: .init(color: StandardPalette.primaries[0], size: 96), samples: samples)
                    }
                    if let cg = PigmentRenderer.cgImage(surface)?.cropping(to: CGRect(x: 235, y: 175, width: 125, height: 80)) {
                        let rectangle = CGRect(x: CGFloat(column * 400 + 20), y: CGFloat(row * 330 + 60), width: 360, height: 230.4)
                        UIImage(cgImage: cg).draw(in: rectangle)
                    }
                    let titlePoint = CGPoint(x: CGFloat(column * 400 + 95), y: CGFloat(row * 330 + 24))
                    (titles[column] as NSString).draw(at: titlePoint, withAttributes: attributes)
                }
            }
        }
        let attachment = XCTAttachment(image: image); attachment.name = "0911V4-mixing-progression"; attachment.lifetime = .keepAlways; add(attachment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("0911V4-mixing-progression.png")
        try image.pngData()!.write(to: file, options: .atomic)
        print("PALETTE_VISUAL_FIXTURE \(file.path)")
    }
}
