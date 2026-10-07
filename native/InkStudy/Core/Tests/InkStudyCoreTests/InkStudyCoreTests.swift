import XCTest
@testable import InkStudyCore

final class InkStudyCoreTests: XCTestCase {
    private func metadata() -> DocumentMetadata { .init(title: "Test drawing") }
    private let transform = CanvasTransform(viewWidth: 600, viewHeight: 425, paperWidth: 1200, paperHeight: 850)

    private func event(_ metadata: DocumentMetadata, _ sequence: Int, _ payload: EventPayload) -> DrawingEvent {
        .init(documentID: metadata.id, sequence: sequence, payload: payload)
    }

    private func start(_ metadata: DocumentMetadata, _ sequence: Int, id: UUID, sample: TouchSample? = nil) -> DrawingEvent {
        event(metadata, sequence, .strokeBegan(strokeID: id, style: .init(), transform: transform,
              samples: [sample ?? .init(uptime: 10, x: 100, y: 150, force: 0, maximumPossibleForce: 4, phase: .began)]))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("InkStudyTests-\(UUID().uuidString)").appendingPathComponent("drawings.sqlite")
    }

    func testSixColorsAndExpandedBrushRange() {
        XCTAssertEqual(InkColor.palette.count, 6)
        XCTAssertEqual(Set(InkColor.palette.map(\.hex)).count, 6)
        XCTAssertEqual(BrushStyle(size: -5).size, 4)
        XCTAssertEqual(BrushStyle(size: 200).size, 96)
        XCTAssertEqual(BrushStyle.presets, [6, 24, 52, 96])
    }

    func testPressureContrastPreservesRawZeroAndMissingValues() {
        let zero = TouchSample(uptime: 0, x: 0, y: 0, force: 0, maximumPossibleForce: 4)
        XCTAssertEqual(zero.normalizedForce, 0)
        let light = PressureMapping.diameter(style: .init(size: 60), normalizedForce: 0.08)
        let heavy = PressureMapping.diameter(style: .init(size: 60), normalizedForce: 0.65)
        XCTAssertGreaterThan(heavy / light, 3)
        let finger = TouchSample(uptime: 0, x: 0, y: 0, force: 1, maximumPossibleForce: 1, input: .finger)
        XCTAssertNil(finger.normalizedForce)
        XCTAssertNil(TouchSample(uptime: 0, x: 0, y: 0, force: 0, maximumPossibleForce: 0).normalizedForce)
        XCTAssertNil(TouchSample(uptime: 0, x: 0, y: 0).normalizedForce)
        XCTAssertGreaterThan(PressureMapping.diameter(style: .init(), normalizedForce: nil), 0)
    }

    func testUndoRedoAndBranchKeepAllOriginalStrokes() throws {
        let m = metadata(), a = UUID(), b = UUID(), c = UUID()
        let events = [start(m, 1, id: a), event(m, 2, .strokeEnded(strokeID: a, reason: .lifted)),
                      start(m, 3, id: b), event(m, 4, .strokeEnded(strokeID: b, reason: .lifted)),
                      event(m, 5, .undone(strokeID: b)), event(m, 6, .redone(strokeID: b)),
                      event(m, 7, .undone(strokeID: b)), start(m, 8, id: c),
                      event(m, 9, .strokeEnded(strokeID: c, reason: .lifted))]
        let state = try DrawingState(metadata: m, events: events)
        XCTAssertEqual(state.visibleStrokeIDs, [a, c]); XCTAssertEqual(state.strokes.map(\.id), [a, b, c])
        XCTAssertTrue(state.redoStrokeIDs.isEmpty); XCTAssertEqual(state.sampleCount, 3)
        let export = try RawDrawingExport(document: .init(metadata: m, events: events))
        XCTAssertEqual(export.strokes.count, 3); XCTAssertEqual(export.events.count, 9)
        XCTAssertTrue(String(decoding: export.csvData(), as: UTF8.self).contains("\"false\""))
    }

    func testEstimatedUpdatesRetainOriginalCaptureInJournal() throws {
        let m = metadata(), id = UUID()
        let original = TouchSample(uptime: 10.123456789, x: 123.456789, y: 42, force: 0.23456789,
                                   maximumPossibleForce: 4, estimationIndex: 27, estimatedProperties: 1, propertiesExpectingUpdates: 1)
        var revised = original; revised.force = 1.123456789; revised.source = .estimatedUpdate
        revised.estimatedProperties = 0; revised.propertiesExpectingUpdates = 0
        let events = [start(m, 1, id: id, sample: original), event(m, 2, .strokeEnded(strokeID: id, reason: .lifted)),
                      event(m, 3, .samplesRevised(strokeID: id, samples: [revised]))]
        let export = try RawDrawingExport(document: .init(metadata: m, events: events))
        let decoded = try DrawingJSON.decoder().decode(RawDrawingExport.self, from: export.jsonData())
        XCTAssertEqual(decoded.strokes[0].samples[0].force, revised.force)
        XCTAssertEqual(decoded.strokes[0].samples[0].uptime, original.uptime)
        guard case .strokeBegan(_, _, _, let initial) = decoded.events[0].payload else { return XCTFail("missing start") }
        XCTAssertEqual(initial[0].force, original.force)
        XCTAssertEqual(initial[0].propertiesExpectingUpdates, 1)
    }

    func testRejectsOutOfSequenceAndInvalidUndoWithoutMutation() throws {
        let m = metadata(), id = UUID()
        var state = try DrawingState(metadata: m)
        XCTAssertThrowsError(try state.apply(start(m, 2, id: id)))
        XCTAssertEqual(state.lastSequence, 0)
        try state.apply(start(m, 1, id: id))
        XCTAssertThrowsError(try state.apply(event(m, 2, .undone(strokeID: id))))
        XCTAssertEqual(state.visibleStrokeIDs, [id]); XCTAssertEqual(state.lastSequence, 1)
    }

    func testRejectsDuplicateSamplesWithoutLosingPriorSamples() throws {
        let m = metadata(), id = UUID(), sample = TouchSample(uptime: 1, x: 3, y: 4)
        var state = try DrawingState(metadata: m, events: [start(m, 1, id: id, sample: sample)])
        XCTAssertThrowsError(try state.apply(event(m, 2, .samplesAppended(strokeID: id, samples: [sample]))))
        XCTAssertEqual(state.sampleCount, 1)
    }

    func testUnfinishedStrokeCanRecoverAndRemainUndoable() throws {
        let m = metadata(), id = UUID()
        var state = try DrawingState(metadata: m, events: [start(m, 1, id: id)])
        XCTAssertEqual(state.activeStrokeID, id)
        try state.apply(event(m, 2, .strokeEnded(strokeID: id, reason: .recovered)))
        XCTAssertNil(state.activeStrokeID); XCTAssertTrue(state.canUndo)
        XCTAssertEqual(state.strokes[0].endReason, .recovered)
        XCTAssertEqual(state.sampleCount, 1)
    }

    func testSQLiteDurableReopenAndIdempotentRetry() async throws {
        let url = temporaryURL(), m = metadata(), id = UUID()
        let store = try JournalStore(url: url)
        try await store.create(m)
        let events = [start(m, 1, id: id), event(m, 2, .samplesAppended(strokeID: id, samples: [
            .init(uptime: 10.01, x: 110, y: 151, force: 2, maximumPossibleForce: 4, source: .coalesced)
        ]))]
        try await store.append(events)
        try await store.append(events)
        let reopened = try JournalStore(url: url)
        let document = try await reopened.load(id: m.id)
        XCTAssertEqual(document.events, events)
        try await reopened.append(document.events)
        let state = try document.replay()
        XCTAssertEqual(state.sampleCount, 2); XCTAssertEqual(state.activeStrokeID, id)
        let integrity = try await reopened.integrityCheck(); XCTAssertEqual(integrity, "ok")
    }

    func testSQLiteBatchRollsBackOnSequenceGap() async throws {
        let store = try JournalStore(url: temporaryURL()), m = metadata(), id = UUID()
        try await store.create(m)
        do {
            try await store.append([start(m, 1, id: id), event(m, 3, .strokeEnded(strokeID: id, reason: .lifted))])
            XCTFail("expected sequence error")
        } catch { }
        let document = try await store.load(id: m.id)
        XCTAssertTrue(document.events.isEmpty)
    }

    func testNewDocumentDoesNotReplacePreviousDrawing() async throws {
        let store = try JournalStore(url: temporaryURL()), first = metadata(), second = metadata(), id = UUID()
        try await store.create(first); try await store.append([start(first, 1, id: id)])
        try await store.create(second)
        let list = try await store.list(); XCTAssertEqual(Set(list.map(\.id)), Set([first.id, second.id]))
        let old = try await store.load(id: first.id); XCTAssertEqual(old.events.count, 1)
    }

    func testSHA256AndCSVPrecision() throws {
        XCTAssertEqual(RawDrawingExport.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let m = metadata(), id = UUID(), raw = 0.123456789012345
        let export = try RawDrawingExport(document: .init(metadata: m, events: [start(m, 1, id: id,
            sample: .init(uptime: 1, x: 2, y: 3, force: raw, maximumPossibleForce: 4))]))
        XCTAssertTrue(String(decoding: export.csvData(), as: UTF8.self).contains(String(raw)))
    }
}
