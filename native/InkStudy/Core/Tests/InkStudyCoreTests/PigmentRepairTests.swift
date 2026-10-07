import XCTest
@testable import InkStudyCore

final class PigmentRepairTests: XCTestCase {
    private let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
    private func metadata(modern: Bool = true) -> DocumentMetadata {
        .init(title: "Synthetic pigment regression", background: .init(kind: "pigment", subject: "orange",
            pigmentModel: modern ? SpectralMixing.version : nil))
    }
    private func points(_ count: Int, y: Double = 425) -> [TouchSample] {
        (0..<count).map { i in
            TouchSample(uptime: Double(i) / 240, x: 180 + Double(i) * 2.1, y: y + sin(Double(i) * 0.025) * 25,
                force: 1.4, maximumPossibleForce: 4, estimationIndex: Int64(i), propertiesExpectingUpdates: 1)
        }
    }

    func testCompiledTableExactlyMatchesReviewedResource() throws {
        let data = Data(SpectralLookupTable.bytes)
        XCTAssertEqual(data.count, 65 * 65 * 3)
        XCTAssertEqual(RawDrawingExport.sha256(data), "380fc707c1c83fd00baaa53ce50bfce1d365166b76697528520c7b1f9f298458")
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pigment-spectral-v2", withExtension: "rgb"))
        XCTAssertEqual(data, try Data(contentsOf: url))
    }

    func testSpectralTableMatchesUpstreamMixturesAndPreservesPaletteEndpoints() {
        let pairs: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 1, 0), SIMD3(247, 109, 51)),
            (SIMD3(0, 1, 1), SIMD3(107, 174, 61)),
            (SIMD3(1, 0, 1), SIMD3(100, 73, 131))
        ]
        for (weights, expected) in pairs {
            let actual = SpectralMixing.color(weights)
            for c in 0..<3 { XCTAssertEqual(actual[c], expected[c], accuracy: 1) }
        }
        XCTAssertEqual(SpectralMixing.color(SIMD3(1, 0, 0)), SIMD3(229, 49, 102))
        XCTAssertEqual(SpectralMixing.color(SIMD3(0, 1, 0)), SIMD3(252, 210, 0))
        XCTAssertEqual(SpectralMixing.color(SIMD3(0, 0, 1)), SIMD3(51, 117, 218))
        var previous = SpectralMixing.color(SIMD3(1, 0, 0))
        for i in 1...1000 {
            let t = Float(i) / 1000, color = SpectralMixing.color(SIMD3(1 - t, t, 0))
            for c in 0..<3 { XCTAssertLessThan(abs(color[c] - previous[c]), 2) }
            previous = color
        }
    }

    func testWetPaintCarriesColorPastOverlapAndIsBatchIndependent() {
        let red = BrushStyle(color: InkColor.pigmentPalette[0], size: 96)
        let yellow = BrushStyle(color: InkColor.pigmentPalette[1], size: 96)
        let vertical = (0...40).map { TouchSample(uptime: Double($0), x: 450, y: 260 + Double($0) * 8, input: .finger) }
        let horizontal = (0...80).map { TouchSample(uptime: Double($0), x: 150 + Double($0) * 9.3, y: 425, input: .finger) }
        var whole = PigmentSurface(metadata: metadata()), batched = whole, yellowOnly = whole
        whole.begin(style: red, samples: vertical)
        batched.begin(style: red, samples: vertical)
        whole.begin(style: yellow, samples: horizontal)
        batched.begin(style: yellow, samples: Array(horizontal.prefix(1)))
        for sample in horizontal.dropFirst() { batched.append([sample]) }
        yellowOnly.begin(style: yellow, samples: horizontal)
        XCTAssertEqual(whole.rgba, batched.rgba)
        let beyondRed = (212 * 600 + 278) * 4
        let difference = (0..<3).reduce(0) { $0 + abs(Int(whole.rgba[beyondRed + $1]) - Int(yellowOnly.rgba[beyondRed + $1])) }
        XCTAssertGreaterThan(difference, 10, "Picked-up paint should travel beyond the original red stripe")
        XCTAssertGreaterThan(whole.metrics["mixedPixels"] ?? 0, 1000)
    }

    func testLegacyArtworkKeepsItsOwnPaletteFormulaAndRendering() throws {
        let old = metadata(modern: false)
        XCTAssertEqual(PigmentSurface(metadata: old).modelVersion, "ryb-pigment-v1")
        XCTAssertEqual(PigmentSurface.palette(for: old.background), InkColor.legacyPalette)
        var a = PigmentSurface(metadata: old), b = PigmentSurface()
        let brush = BrushStyle(color: InkColor.legacyPalette[0], size: 96)
        a.begin(style: brush, samples: points(40)); b.begin(style: brush, samples: points(40))
        XCTAssertEqual(a.rgba, b.rgba)
        let oldRaw = try RawDrawingExport(document: .init(metadata: old, events: []))
        let newRaw = try RawDrawingExport(document: .init(metadata: metadata(), events: []))
        XCTAssertEqual(oldRaw.pressureMapping, PigmentSurface.pressureFormula)
        XCTAssertTrue(newRaw.pressureMapping.contains("spectral-wet-v2"))
        let decoded = try DrawingJSON.decoder().decode(DocumentMetadata.self, from: DrawingJSON.encoder().encode(old))
        XCTAssertNil(decoded.background?.pigmentModel)
        var modern = try DrawingState(metadata: metadata())
        XCTAssertThrowsError(try modern.apply(.init(documentID: modern.metadata.id, sequence: 1,
            payload: .brushChanged(style: brush))), "New pigment RGB values must be truthful in the raw journal")
    }

    func testLateCorrectionsUseBoundedCacheAndExactlyMatchColdReplay() throws {
        for modern in [false, true] {
            var state = try DrawingState(metadata: metadata(modern: modern))
            var renderer = IncrementalPigmentRenderer()
            renderer.update(state)
            let palette = PigmentSurface.palette(for: state.metadata.background)
            func event(_ payload: EventPayload) -> DrawingEvent {
                .init(documentID: state.metadata.id, sequence: state.lastSequence + 1, payload: payload)
            }
            var ids: [UUID] = []
            for color in ["red", "yellow"] {
                let id = UUID(); ids.append(id)
                let begin = event(.strokeBegan(strokeID: id, style: .init(color: palette.first { $0.id == color }!, size: 96),
                    transform: transform, samples: points(360)))
                try state.apply(begin); renderer.update(state, changes: [begin])
                let end = event(.strokeEnded(strokeID: id, reason: .lifted))
                try state.apply(end); renderer.update(state, changes: [end])
            }
            var revised = state.strokes[1].samples[354]
            revised.source = .estimatedUpdate; revised.force = 2.2; revised.x += 1.2
            revised.propertiesExpectingUpdates = 0
            let correction = event(.samplesRevised(strokeID: ids[1], samples: [revised]))
            try state.apply(correction); renderer.update(state, changes: [correction])
            XCTAssertFalse(renderer.statistics.fullReplay)
            XCTAssertLessThanOrEqual(renderer.statistics.replayedSamples, 64)
            XCTAssertEqual(renderer.surface?.rgba, PigmentSurface(state: state).rgba)
            XCTAssertLessThanOrEqual(renderer.statistics.checkpointCount, 8)

            // A correction to an older stroke must invalidate every dependent cache.
            var old = state.strokes[0].samples[2]
            old.source = .estimatedUpdate; old.force = 0.3; old.y += 8
            let oldCorrection = event(.samplesRevised(strokeID: ids[0], samples: [old]))
            try state.apply(oldCorrection); renderer.update(state, changes: [oldCorrection])
            XCTAssertEqual(renderer.surface?.rgba, PigmentSurface(state: state).rgba)
            for payload in [EventPayload.undone(strokeID: ids[1]), .redone(strokeID: ids[1])] {
                let change = event(payload)
                try state.apply(change); renderer.update(state, changes: [change])
                XCTAssertEqual(renderer.surface?.rgba, PigmentSurface(state: state).rgba)
            }
        }
    }

    func testControlEventsAndNonvisualEstimateUpdatesDoNotRedraw() throws {
        var state = try DrawingState(metadata: metadata())
        var renderer = IncrementalPigmentRenderer()
        renderer.update(state)
        let id = UUID(), samples = points(12)
        let begin = DrawingEvent(documentID: state.metadata.id, sequence: 1,
            payload: .strokeBegan(strokeID: id, style: .init(color: InkColor.pigmentPalette[0], size: 96), transform: transform, samples: samples))
        try state.apply(begin); renderer.update(state, changes: [begin])
        var changed = samples[4]; changed.source = .estimatedUpdate; changed.altitude = 0.8
        let revision = DrawingEvent(documentID: state.metadata.id, sequence: 2, payload: .samplesRevised(strokeID: id, samples: [changed]))
        try state.apply(revision)
        XCTAssertFalse(renderer.update(state, changes: [revision]))
        let end = DrawingEvent(documentID: state.metadata.id, sequence: 3, payload: .strokeEnded(strokeID: id, reason: .lifted))
        try state.apply(end); XCTAssertFalse(renderer.update(state, changes: [end]))
        XCTAssertEqual(renderer.lastSequence, 3)
        XCTAssertEqual(state.strokes[0].samples[4].altitude, 0.8)
    }
}
