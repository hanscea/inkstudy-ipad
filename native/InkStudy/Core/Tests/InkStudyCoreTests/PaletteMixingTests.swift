import XCTest
@testable import InkStudyCore

final class PaletteMixingTests: XCTestCase {
    private let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
    private func metadata() -> DocumentMetadata {
        .init(title: "Synthetic finite palette", background: .init(kind: "pigment", subject: "orange", pigmentModel: PaletteMixing.version))
    }
    private func brush(_ color: Int, id: UUID? = UUID()) -> BrushStyle {
        .init(color: InkColor.pigmentPalette[color], size: 96, pigmentLoadID: id)
    }
    private func line(y: Double = 410, count: Int = 80) -> [TouchSample] {
        (0..<count).map { .init(uptime: Double($0) / 240, x: 510 + Double($0) * 3, y: y,
            force: 1.4, maximumPossibleForce: 4, estimationIndex: Int64($0), propertiesExpectingUpdates: 1) }
    }
    private func circles(_ count: Int) -> [TouchSample] {
        (0...count * 100).map { i in
            let a = Double(i) * 2 * .pi / 100
            return .init(uptime: Double(i) / 240, x: 588 + cos(a) * 72, y: 425 + sin(a) * 30,
                force: 1.4, maximumPossibleForce: 4)
        }
    }
    private func prepared() -> PigmentSurface {
        var surface = PigmentSurface(metadata: metadata())
        surface.begin(style: brush(0), samples: line())
        surface.begin(style: brush(1), samples: line(y: 440))
        return surface
    }
    private func assertMass(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<3 { XCTAssertEqual(actual[c], expected[c], accuracy: 0.12, file: file, line: line) }
    }

    func testOneLoadIsFiniteAndPenLiftsNeverRefillIt() {
        let red = brush(0)
        var surface = PigmentSurface(metadata: metadata())
        surface.begin(style: red, samples: line(count: 11))
        XCTAssertEqual(surface.remainingLoadFraction(for: red), 0.78, accuracy: 0.001)
        surface.begin(style: red, samples: line())
        XCTAssertEqual(surface.remainingLoadFraction(for: red), 0)
        let before = surface.pigmentMass
        for _ in 0..<10 { surface.begin(style: red, samples: circles(1)) }
        assertMass(surface.pigmentMass, before)
        assertMass(surface.pigmentMass, SIMD3(2400, 0, 0))
        surface.begin(style: brush(0), samples: line())
        assertMass(surface.pigmentMass, SIMD3(4800, 0, 0))
    }

    func testStirringConservesEveryPigmentAndHasNoSelectedColorBias() {
        var redSelected = prepared(), yellowSelected = redSelected
        let before = redSelected.pigmentMass
        redSelected.begin(style: brush(0, id: nil), samples: circles(20))
        yellowSelected.begin(style: brush(1, id: nil), samples: circles(20))
        XCTAssertEqual(redSelected.rgba, yellowSelected.rgba)
        assertMass(redSelected.pigmentMass, before)
        assertMass(before, SIMD3(2400, 2400, 0))
    }

    func testMixingIsGradualAndOnlyTouchedPaintChanges() throws {
        var surface = prepared()
        let before = surface.metrics["pigmentRatioVariance"]!
        let pixels = surface.rgba
        surface.begin(style: brush(2, id: nil), samples: circles(1))
        let first = surface.metrics["pigmentRatioVariance"]!
        let firstPixels = surface.rgba
        surface.begin(style: brush(2, id: nil), samples: circles(9))
        let later = surface.metrics["pigmentRatioVariance"]!
        print("PALETTE_MIX_PROGRESS before=\(before) first=\(first) tenCircles=\(later)")
        XCTAssertGreaterThan(first, 0.002, "One pass must not instantly homogenize the palette")
        XCTAssertLessThan(first, before)
        XCTAssertLessThan(later, first * 0.9)
        XCTAssertNotEqual(firstPixels, surface.rgba)
        XCTAssertEqual(Array(pixels.prefix(600 * 100 * 4)), Array(surface.rgba.prefix(600 * 100 * 4)))
        XCTAssertTrue(surface.pigmentMass.x.isFinite)
    }

    func testConservedDoseRatiosYieldOrderIndependentColorEndpoint() {
        func mixture(_ order: [Int]) -> PigmentSurface {
            var result = PigmentSurface(metadata: metadata())
            for color in order { result.begin(style: brush(color), samples: line()) }
            result.begin(style: brush(2, id: nil), samples: circles(3))
            return result
        }
        for order in [[0, 1], [0, 1, 1], [0, 0, 1]] {
            let a = mixture(order), b = mixture(order.reversed())
            assertMass(a.pigmentMass, b.pigmentMass)
            let actual = SpectralMixing.color(SIMD3<Float>(a.pigmentMass))
            let other = SpectralMixing.color(SIMD3<Float>(b.pigmentMass))
            for c in 0..<3 { XCTAssertEqual(actual[c], other[c], accuracy: 0.002) }
        }
        let one = SpectralMixing.color(SIMD3<Float>(mixture([0, 1]).pigmentMass))
        let two = SpectralMixing.color(SIMD3<Float>(mixture([0, 1, 1]).pigmentMass))
        XCTAssertGreaterThan(two.y, one.y)
    }

    func testBoundaryTransfersCannotLosePaintAndOffCanvasMotionConsumesNothing() {
        let red = brush(0)
        var surface = PigmentSurface(metadata: metadata())
        surface.begin(style: red, samples: [.init(uptime: 0, x: -500, y: -500)])
        XCTAssertEqual(surface.remainingLoadFraction(for: red), 1)
        for i in 0..<50 { surface.begin(style: red, samples: [.init(uptime: Double(i), x: 0, y: 0)]) }
        assertMass(surface.pigmentMass, SIMD3(2400, 0, 0))
        for i in 0..<200 { surface.begin(style: red, samples: [.init(uptime: Double(i), x: 0, y: 0)]) }
        assertMass(surface.pigmentMass, SIMD3(2400, 0, 0))
    }

    func testBatchedSamplesAndReloadIdentitySurviveJSONReplay() throws {
        let red = brush(0), samples = line()
        var whole = PigmentSurface(metadata: metadata()), batched = whole
        whole.begin(style: red, samples: samples)
        batched.begin(style: red, samples: [samples[0]])
        for sample in samples.dropFirst() { batched.append([sample]) }
        XCTAssertEqual(whole.rgba, batched.rgba)
        XCTAssertEqual(whole.remainingLoadFraction(for: red), batched.remainingLoadFraction(for: red))
        let encoded = try DrawingJSON.encoder().encode(red)
        XCTAssertEqual(try DrawingJSON.decoder().decode(BrushStyle.self, from: encoded), red)
        let legacy = try DrawingJSON.encoder().encode(brush(0, id: nil))
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("pigmentLoadID"))
        XCTAssertEqual(metadata().schemaVersion, 2)
    }

    func testIncrementalCorrectionsUndoRedoAndRestartRestorePixelsAndLoad() throws {
        var state = try DrawingState(metadata: metadata()), events: [DrawingEvent] = []
        var renderer = IncrementalPigmentRenderer()
        renderer.update(state)
        func apply(_ payload: EventPayload) throws {
            let event = DrawingEvent(documentID: state.metadata.id, sequence: state.lastSequence + 1, payload: payload)
            try state.apply(event); events.append(event); renderer.update(state, changes: [event])
            let cold = PigmentSurface(state: state)
            XCTAssertEqual(renderer.surface?.rgba, cold.rgba)
            XCTAssertEqual(renderer.surface?.remainingLoadFraction(for: state.brush), cold.remainingLoadFraction(for: state.brush))
        }
        let red = brush(0), yellow = brush(1), first = UUID(), second = UUID(), third = UUID()
        try apply(.brushChanged(style: red))
        try apply(.strokeBegan(strokeID: first, style: red, transform: transform, samples: line(count: 10)))
        try apply(.strokeEnded(strokeID: first, reason: .cancelled))
        try apply(.strokeBegan(strokeID: second, style: red, transform: transform, samples: line(count: 70)))
        try apply(.strokeEnded(strokeID: second, reason: .lifted))
        try apply(.brushChanged(style: yellow))
        try apply(.strokeBegan(strokeID: third, style: yellow, transform: transform, samples: line(y: 440, count: 160)))
        try apply(.strokeEnded(strokeID: third, reason: .lifted))
        var revision = state.strokes[2].samples[154]
        revision.source = .estimatedUpdate; revision.force = 2.1; revision.x += 1
        try apply(.samplesRevised(strokeID: third, samples: [revision]))
        XCTAssertLessThanOrEqual(renderer.statistics.replayedSamples, 64)
        try apply(.undone(strokeID: third))
        try apply(.undone(strokeID: second))
        try apply(.redone(strokeID: second))
        try apply(.redone(strokeID: third))
        let data = try DrawingJSON.encoder().encode(events)
        let replayed = try DrawingState(metadata: state.metadata, events: DrawingJSON.decoder().decode([DrawingEvent].self, from: data))
        XCTAssertEqual(PigmentSurface(state: replayed).rgba, renderer.surface?.rgba)
        let raw = try RawDrawingExport(document: .init(metadata: state.metadata, events: events))
        XCTAssertEqual(raw.pigmentMixing, PaletteMixing.formula)
        XCTAssertTrue(String(decoding: raw.csvData(), as: UTF8.self).contains("pigment_load_id"))
        XCTAssertTrue(String(decoding: raw.csvData(), as: UTF8.self).contains(red.pigmentLoadID!.uuidString))
    }

    func testLoadIDCannotChangePigmentOrBeUsedInLegacyModel() throws {
        let red = brush(0), yellow = brush(1, id: red.pigmentLoadID)
        var state = try DrawingState(metadata: metadata())
        try state.apply(.init(documentID: state.metadata.id, sequence: 1, payload: .brushChanged(style: red)))
        XCTAssertThrowsError(try state.apply(.init(documentID: state.metadata.id, sequence: 2, payload: .brushChanged(style: yellow))))
        var old = try DrawingState(metadata: .init(title: "Legacy", background: .init(kind: "pigment", subject: "orange", pigmentModel: SpectralMixing.version)))
        XCTAssertThrowsError(try old.apply(.init(documentID: old.metadata.id, sequence: 1, payload: .brushChanged(style: red))))
    }
}
