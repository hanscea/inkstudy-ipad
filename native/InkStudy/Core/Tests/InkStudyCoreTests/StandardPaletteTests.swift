import XCTest
@testable import InkStudyCore

final class StandardPaletteTests: XCTestCase {
    func testSixRGBValuesAndThreeTargetPairsAreExact() {
        XCTAssertEqual(InkColor.palette.map(\.hex), ["#FF0000", "#FFA500", "#FFFF00", "#00FF00", "#0000FF", "#800080"])
        XCTAssertEqual(StandardPalette.primaries.map(\.hex), ["#FF0000", "#FFFF00", "#0000FF"])
        for (target, pair) in zip(StandardPalette.targetIDs, [["red", "yellow"], ["yellow", "blue"], ["red", "blue"]]) {
            XCTAssertEqual(StandardPalette.pair(for: target), pair)
            XCTAssertEqual(ColorExercises.mix(pair[0], pair[1]), target)
        }
        XCTAssertNil(StandardPalette.pair(for: "red"))
        XCTAssertNil(StandardPalette.pair(for: "unknown"))
    }

    func testPrimaryAndEqualPairEndpointsMatchAllSixSpecifiedRGBValues() {
        let weights: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(0, 0, 1), SIMD3(1, 0, 1)]
        let expected: [SIMD3<Float>] = [SIMD3(255, 0, 0), SIMD3(255, 165, 0), SIMD3(255, 255, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(128, 0, 128)]
        for (weight, rgb) in zip(weights, expected) {
            XCTAssertEqual(StandardPalette.color(weight), rgb)
            XCTAssertEqual(StandardPalette.color(weight * 2400), rgb)
        }
        XCTAssertEqual(StandardPalette.color(.zero), SIMD3(repeating: 255))
    }

    func testRatioInterpolationIsContinuousAndStaysWithinSRGB() {
        for r in 0...32 {
            for y in 0...32 {
                let weights = SIMD3(Float(r), Float(y), Float(32 - min(32, r + y)))
                let rgb = StandardPalette.color(weights)
                for c in 0..<3 { XCTAssertTrue((0...255).contains(rgb[c])) }
                if weights != .zero {
                    let nearby = StandardPalette.color(weights + SIMD3(0.0001, 0, 0))
                    for c in 0..<3 { XCTAssertEqual(rgb[c], nearby[c], accuracy: 0.06) }
                }
            }
        }
        XCTAssertLessThan(StandardPalette.color(SIMD3(2, 1, 0)).y, StandardPalette.color(SIMD3(1, 1, 0)).y)
        XCTAssertGreaterThan(StandardPalette.color(SIMD3(1, 2, 0)).y, StandardPalette.color(SIMD3(1, 1, 0)).y)
    }

    func testNewPaletteMetadataAndOlderMissingFieldsRoundTrip() throws {
        let new = DocumentMetadata(title: "Standard", background: .init(kind: "pigment", subject: "green", pigmentModel: StandardPalette.mixingVersion))
        XCTAssertEqual(new.schemaVersion, 2)
        XCTAssertEqual(new.colorPaletteVersion, StandardPalette.version)
        XCTAssertEqual(try DrawingJSON.decoder().decode(DocumentMetadata.self, from: DrawingJSON.encoder().encode(new)), new)
        let old = DocumentMetadata(title: "Legacy", colorPaletteVersion: nil)
        let data = try DrawingJSON.encoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("colorPaletteVersion"))
        XCTAssertNil(try DrawingJSON.decoder().decode(DocumentMetadata.self, from: data).colorPaletteVersion)
        let configuration = ResearchConfiguration(participantCode: "PALETTE_TEST", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix)
        XCTAssertEqual(configuration.colorPaletteVersion, StandardPalette.version)
        let oldConfiguration = ResearchConfiguration(participantCode: "PALETTE_OLD", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix, colorPaletteVersion: nil)
        XCTAssertEqual(try DrawingJSON.decoder().decode(ResearchConfiguration.self, from: DrawingJSON.encoder().encode(oldConfiguration)), oldConfiguration)
    }

    func testVersionedPigmentValidationAndLegacyStrokeColors() throws {
        for version in [PigmentSurface.version, SpectralMixing.version, PaletteMixing.version, StandardPalette.mixingVersion] {
            let metadata = DocumentMetadata(title: "Versioned", background: .init(kind: "pigment", subject: "orange", pigmentModel: version))
            var state = try DrawingState(metadata: metadata)
            let palette = PigmentSurface.palette(for: metadata.background)
            try state.apply(.init(documentID: metadata.id, sequence: 1, payload: .brushChanged(style: .init(color: palette[0]))))
            let incorrect = version == StandardPalette.mixingVersion ? InkColor.pigmentPalette[0] : StandardPalette.primaries[0]
            XCTAssertThrowsError(try state.apply(.init(documentID: metadata.id, sequence: 2, payload: .brushChanged(style: .init(color: incorrect)))))
        }
        var old = try DrawingState(metadata: .init(title: "Old free drawing", colorPaletteVersion: nil))
        for color in InkColor.legacyPalette {
            try old.apply(.init(documentID: old.metadata.id, sequence: old.lastSequence + 1, payload: .brushChanged(style: .init(color: color))))
            XCTAssertEqual(old.brush.color.hex, color.hex)
        }
    }

    func testNewColorMappingKeepsFiniteMassAndGradualTransportIdenticalToV3() {
        let line = (0..<80).map { TouchSample(uptime: Double($0) / 240, x: 510 + Double($0) * 3, y: 410, force: 1.4, maximumPossibleForce: 4) }
        let circles = (0...400).map { i in
            let angle = Double(i) * 2 * .pi / 100
            return TouchSample(uptime: Double(i) / 240, x: 588 + cos(angle) * 72, y: 425 + sin(angle) * 30)
        }
        var old = PigmentSurface(modelVersion: PaletteMixing.version), new = PigmentSurface(modelVersion: StandardPalette.mixingVersion)
        for index in 0..<2 {
            let load = UUID()
            let points = line.map { sample in var point = sample; point.y += Double(index) * 30; return point }
            let oldBrush = BrushStyle(color: InkColor.pigmentPalette[index], size: 96, pigmentLoadID: load)
            let newBrush = BrushStyle(color: StandardPalette.primaries[index], size: 96, pigmentLoadID: load)
            old.begin(style: oldBrush, samples: points); new.begin(style: newBrush, samples: points)
            XCTAssertEqual(new.remainingLoadFraction(for: newBrush), 0)
        }
        let variance = new.metrics["pigmentRatioVariance"]!
        old.begin(style: .init(color: InkColor.pigmentPalette[0], size: 96), samples: circles)
        new.begin(style: .init(color: StandardPalette.primaries[0], size: 96), samples: circles)
        XCTAssertEqual(old.pigmentMass, new.pigmentMass)
        XCTAssertEqual(old.metrics, new.metrics)
        XCTAssertEqual(new.pigmentMass.x, 2400, accuracy: 0.12)
        XCTAssertEqual(new.pigmentMass.y, 2400, accuracy: 0.12)
        XCTAssertLessThan(new.metrics["pigmentRatioVariance"]!, variance)
        XCTAssertNotEqual(old.rgba, new.rgba)
    }

    func testNewPaletteIncrementalReplayUndoRedoAndExportAreExact() throws {
        let metadata = DocumentMetadata(title: "Standard replay", background: .init(kind: "pigment", subject: "violet", pigmentModel: StandardPalette.mixingVersion))
        var state = try DrawingState(metadata: metadata), renderer = IncrementalPigmentRenderer()
        var events: [DrawingEvent] = []
        let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
        func apply(_ payload: EventPayload) throws {
            let event = DrawingEvent(documentID: metadata.id, sequence: state.lastSequence + 1, payload: payload)
            try state.apply(event); events.append(event); renderer.update(state, changes: [event])
            let cold = PigmentSurface(state: state)
            XCTAssertEqual(renderer.surface?.rgba, cold.rgba)
            XCTAssertEqual(renderer.surface?.remainingLoadFraction(for: state.brush), cold.remainingLoadFraction(for: state.brush))
        }
        for color in [StandardPalette.primaries[0], StandardPalette.primaries[2]] {
            let id = UUID(), brush = BrushStyle(color: color, size: 96, pigmentLoadID: UUID())
            try apply(.brushChanged(style: brush))
            let points = (0..<60).map { TouchSample(uptime: Double($0) / 240, x: 500 + Double($0) * 3, y: 425, estimationIndex: Int64($0)) }
            try apply(.strokeBegan(strokeID: id, style: brush, transform: transform, samples: points))
            try apply(.strokeEnded(strokeID: id, reason: .cancelled))
            var revision = points[55]; revision.source = .estimatedUpdate; revision.force = 1.3
            try apply(.samplesRevised(strokeID: id, samples: [revision]))
            try apply(.undone(strokeID: id)); try apply(.redone(strokeID: id))
        }
        let document = StoredDocument(metadata: metadata, events: events)
        let restored = StoredDocument(metadata: metadata, events: try DrawingJSON.decoder().decode([DrawingEvent].self, from: DrawingJSON.encoder().encode(events)))
        XCTAssertEqual(PigmentSurface(state: try restored.replay()).rgba, renderer.surface?.rgba)
        let raw = try RawDrawingExport(document: document)
        XCTAssertEqual(raw.pigmentMixing, StandardPalette.formula)
        XCTAssertEqual(raw.strokes, state.strokes)
        XCTAssertTrue(String(decoding: raw.csvData(), as: UTF8.self).contains("#0000FF"))
    }
}
