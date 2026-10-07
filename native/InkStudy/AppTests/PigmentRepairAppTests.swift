import XCTest
import UIKit
import InkStudyCore
@testable import InkStudy

@MainActor
final class PigmentRepairAppTests: XCTestCase {
    private let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)

    func testProductionAppContainsItsOwnModelResources() throws {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("InkStudyCore_InkStudyCore.bundle")
        let pigment = try Data(contentsOf: bundle.appendingPathComponent("pigment-spectral-v2.rgb"))
        XCTAssertEqual(RawDrawingExport.sha256(pigment), "380fc707c1c83fd00baaa53ce50bfce1d365166b76697528520c7b1f9f298458")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("state-model.json"))))
        let license = try String(contentsOf: bundle.appendingPathComponent("SPECTRAL_LICENSE.txt"), encoding: .utf8)
        XCTAssertTrue(license.contains("Permission is hereby granted"))
    }

    private func setup() async throws -> (PigmentMixingCoordinator, DrawingCanvasView) {
        let id = UUID().uuidString
        let research = ResearchController(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PigmentRepair-" + id),
            preferences: UserDefaults(suiteName: id)!)
        await research.create(.init(participantCode: "SYNTHETIC_PAINT", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix))
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.prepare()
        let view = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        view.model = capture.studio; view.synchronize(); view.layoutIfNeeded()
        capture.studio.didApplyEvent = { [weak view] in view?.applyDrawingChange($0) }
        await view.flushPigmentRendering()
        return (capture, view)
    }

    func testPencilCorrectionStormIsCoalescedAndJournalIsUntouched() async throws {
        let (capture, view) = try await setup()
        defer { view.stopRendering() }
        let studio = capture.studio
        let points = (0..<600).map { i in
            TouchSample(uptime: Double(i) / 240, x: 600 + cos(Double(i) * 0.024) * 220,
                y: 425 + sin(Double(i) * 0.024) * 170, force: 1.3, maximumPossibleForce: 4,
                estimationIndex: Int64(i), propertiesExpectingUpdates: 1)
        }
        for color in ["red", "yellow"] {
            capture.selectBrush(color)
            XCTAssertTrue(studio.beginStroke(id: UUID(), transform: transform, samples: points))
            studio.endActive(.lifted)
            await view.flushPigmentRendering()
        }
        let before = try await studio.storedDocument()
        let stroke = try XCTUnwrap(studio.state?.strokes.last)
        let requestsBefore = try XCTUnwrap(view.pigmentStatistics).requests
        let start = ContinuousClock.now
        for i in 0..<240 {
            var sample = stroke.samples[580 + i % 15]
            sample.source = .estimatedUpdate; sample.force = 0.4 + Double(i % 14) * 0.17
            sample.propertiesExpectingUpdates = 0
            studio.reviseSamples(strokeID: stroke.id, samples: [sample])
        }
        let elapsed = start.duration(to: .now).components
        let callbackMs = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        XCTAssertEqual(view.pigmentStatistics?.requests, requestsBefore, "Pencil callbacks must not synchronously start raster work")
        await view.flushPigmentRendering()
        XCTAssertLessThanOrEqual(try XCTUnwrap(view.pigmentStatistics).requests - requestsBefore, 2)
        let after = try await studio.storedDocument()
        XCTAssertEqual(Array(after.events.prefix(before.events.count)), before.events)
        XCTAssertEqual(after.events.count - before.events.count, 240)
        XCTAssertEqual(try after.replay().sampleCount, 1200)
        let canvas = snapshot(view)
        let output = InkRenderer.artwork(try after.replay(), scale: 1)
        XCTAssertEqual(try centerPixel(canvas), try centerPixel(output))
        let details: [String: Any] = ["input": "240 synthetic Pencil estimate events; not physical handwriting",
            "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "callbackTotalMs": callbackMs, "callbackMeanMs": callbackMs / 240,
            "lastBackgroundFrameMs": view.pigmentStatistics?.lastMilliseconds ?? -1,
            "displayRequestsFor240Corrections": (view.pigmentStatistics?.requests ?? 0) - requestsBefore,
            "eventsPreserved": 240, "samplesPreserved": 1200]
        let data = try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
        print("PIGMENT_REPAIR_BENCHMARK " + String(decoding: data, as: UTF8.self))
        let report = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        report.name = "0911V1-pigment-frame-benchmark"; report.lifetime = .keepAlways; add(report)
        let artwork = XCTAttachment(image: canvas); artwork.name = "0911V1-live-cached-paint"; artwork.lifetime = .keepAlways; add(artwork)
    }

    func testLaunchRestoresUnfinishedSpectralPaintingWithoutChangingSavedData() async throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PigmentResume-" + id)
        let preferences = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { preferences.removePersistentDomain(forName: id) }
        let original = ResearchController(directory: directory, preferences: preferences)
        await original.create(.init(participantCode: "SYNTHETIC_RESUME", purpose: .rehearsal,
            group: .fixed, visit: .practice, practiceKind: .mix))
        let capture = PigmentMixingCoordinator(research: original, task: try XCTUnwrap(original.current?.task))
        await capture.prepare()
        for color in ["red", "yellow"] {
            capture.selectBrush(color)
            let samples = (0..<80).map { TouchSample(uptime: Double($0) / 240, x: 150 + Double($0) * 10,
                y: 425, force: 1.4, maximumPossibleForce: 4) }
            XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: transform, samples: samples))
            capture.studio.endActive(.lifted)
        }
        let before = try await capture.studio.storedDocument()
        try await original.flush()
        let originalRecord = try XCTUnwrap(original.record)

        let restored = ResearchController(directory: directory, preferences: preferences)
        await restored.start()
        XCTAssertEqual(restored.record?.id, originalRecord.id)
        let resumed = PigmentMixingCoordinator(research: restored, task: try XCTUnwrap(restored.current?.task))
        await resumed.prepare()
        let view = DrawingCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        defer { view.stopRendering() }
        view.model = resumed.studio; view.synchronize(); view.layoutIfNeeded()
        await view.flushPigmentRendering()
        let after = try await resumed.studio.storedDocument()
        XCTAssertEqual(after.metadata.id, before.metadata.id)
        XCTAssertEqual(after.events, before.events)
        XCTAssertEqual(restored.record?.events, originalRecord.events)
        XCTAssertGreaterThan(try XCTUnwrap(view.pigmentStatistics).presentedFrames, 0)
        XCTAssertEqual(try centerPixel(snapshot(view)), try centerPixel(InkRenderer.artwork(try before.replay(), scale: 1)))
    }

    func testDocumentSwitchDropsStaleFramesAndNewPaintExportRecordsModel() async throws {
        let (capture, view) = try await setup()
        defer { view.stopRendering() }
        for color in ["red", "yellow"] {
            capture.selectBrush(color)
            let samples = (0..<80).map { TouchSample(uptime: Double($0), x: 150 + Double($0) * 10, y: 425, force: 1.4, maximumPossibleForce: 4) }
            XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: transform, samples: samples))
            capture.studio.endActive(.lifted)
        }
        let old = try await capture.studio.storedDocument()
        let files = try await ExportService.create(document: old, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let manifestURL = try XCTUnwrap(files.urls.first { $0.lastPathComponent == "manifest.json" })
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["pigmentRendererVersion"] as? String, StandardPalette.mixingVersion)
        XCTAssertEqual(old.metadata.background?.pigmentModel, StandardPalette.mixingVersion)
        XCTAssertEqual(old.events.compactMap { event -> String? in
            if case let .strokeBegan(_, style, _, _) = event.payload { return style.color.hex }; return nil
        }, ["#FF0000", "#FFFF00"])
        await capture.prepare(retry: true)
        view.synchronize(); view.layoutIfNeeded()
        await view.flushPigmentRendering()
        XCTAssertEqual(try centerPixel(snapshot(view)), [255, 255, 255, 255])
        XCTAssertEqual(capture.studio.visibleCount, 0)
        let retained = try await capture.studio.storedDocument(old.metadata.id)
        XCTAssertEqual(retained.events, old.events)
    }

    func testStreamingMixingPerformanceOnCurrentDevice() async throws {
        let (capture, view) = try await setup()
        defer { view.stopRendering() }
        let studio = capture.studio
        func sample(_ i: Int) -> TouchSample {
            .init(uptime: Double(i) / 240, x: 600 + cos(Double(i) * 0.025) * 220,
                y: 425 + sin(Double(i) * 0.025) * 160, force: 1.2, maximumPossibleForce: 4,
                estimationIndex: Int64(i), propertiesExpectingUpdates: 1)
        }
        capture.selectBrush("red")
        XCTAssertTrue(studio.beginStroke(id: UUID(), transform: transform, samples: (0..<720).map(sample)))
        studio.endActive(.lifted)
        await view.flushPigmentRendering()
        capture.selectBrush("yellow")
        let id = UUID()
        let yellowSamples = (0...720).map(sample)
        XCTAssertTrue(studio.beginStroke(id: id, transform: transform, samples: [yellowSamples[0]]))
        let requestsBefore = view.pigmentStatistics?.requests ?? 0
        var callbackTimes: [Double] = []
        for frame in 0..<180 {
            let start = ContinuousClock.now
            let first = frame * 4 + 1
            studio.appendSamples(strokeID: id, samples: Array(yellowSamples[first..<first + 4]))
            var correction = yellowSamples[max(0, first - 3)]
            correction.source = .estimatedUpdate; correction.force = 0.8 + Double(frame % 9) * 0.2
            correction.propertiesExpectingUpdates = 0
            studio.reviseSamples(strokeID: id, samples: [correction])
            let elapsed = start.duration(to: .now).components
            callbackTimes.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            try await Task.sleep(for: .milliseconds(16))
        }
        studio.endActive(.lifted)
        await view.flushPigmentRendering()
        let stats = try XCTUnwrap(view.pigmentStatistics)
        let drawing = try await studio.storedDocument()
        XCTAssertEqual(try drawing.replay().sampleCount, 1441)
        let revisions = drawing.events.filter { if case .samplesRevised = $0.payload { return true }; return false }
        XCTAssertEqual(revisions.count, 180)
        XCTAssertGreaterThan(stats.requests - requestsBefore, 5, "The actual display link must run while input continues")
        XCTAssertLessThanOrEqual(stats.requests - requestsBefore, 183)
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * 0.95))] }
        let report: [String: Any] = ["input": "synthetic 4-sample batches and delayed corrections at approximately 60 Hz",
            "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "callbackP95Ms": p95(callbackTimes), "backgroundFrameP95Ms": p95(stats.backgroundDurations),
            "displayRequests": stats.requests - requestsBefore, "correctionsPreserved": revisions.count,
            "samplesPreserved": 1441, "fullReplays": stats.fullReplays]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("PIGMENT_STREAM_BENCHMARK " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "0911V1-stream-benchmark"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWetPaintVisualFixtureForAllThreePairs() throws {
        let pairs = [("red", "yellow"), ("yellow", "blue"), ("blue", "red")]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            for (row, pair) in pairs.enumerated() {
                var surface = PigmentSurface(modelVersion: SpectralMixing.version)
                let first = BrushStyle(color: InkColor.pigmentPalette.first { $0.id == pair.0 }!, size: 96)
                let second = BrushStyle(color: InkColor.pigmentPalette.first { $0.id == pair.1 }!, size: 96)
                for y in stride(from: 180.0, through: 650.0, by: 60) {
                    surface.begin(style: first, samples: (0...55).map { TouchSample(uptime: Double($0), x: 390 + Double($0) * 5, y: y, input: .finger) })
                }
                surface.begin(style: second, samples: (0...110).map { TouchSample(uptime: Double($0), x: 160 + Double($0) * 8, y: 420 + sin(Double($0) * 0.11) * 90, input: .finger) })
                PigmentRenderer.image(surface).draw(in: CGRect(x: row * 400, y: 95, width: 400, height: 400 * 850 / 1200))
                let title = "\(ColorExercises.names[pair.0]!) + \(ColorExercises.names[pair.1]!)"
                (title as NSString).draw(at: CGPoint(x: row * 400 + 130, y: 50), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 25), .foregroundColor: UIColor.darkGray])
            }
        }
        let attachment = XCTAttachment(image: image); attachment.name = "0911V1-three-pigment-pairs"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
    }
    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: -810, y: -425)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixel
    }
}
