import XCTest
@testable import InkStudyCore

final class MultimodalFeedbackTests: XCTestCase {
    private func evidence(_ task: String = "mix", metrics: [String: Double] = ["redPaintUnits": 1, "yellowPaintUnits": 1, "mixedAreaFraction": 0.1, "pigmentRatioVariance": 0.3]) -> HintEvidence {
        .init(drawingID: UUID(), drawingSequence: 3, task: task, target: task == "mix" ? "orange" : "light", strokeCount: 2, metrics: metrics)
    }
    func testVersionOptInCannotChangePilotOrOldPractice() throws {
        let legacy = ResearchConfiguration(participantCode: "TEST", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix)
        XCTAssertFalse(MultimodalFeedback.enabled(legacy))
        let decoded = try DrawingJSON.decoder().decode(ResearchConfiguration.self, from: DrawingJSON.encoder().encode(legacy))
        XCTAssertNil(decoded.hintProtocolVersion)
        let invalid = ResearchConfiguration(participantCode: "TEST", purpose: .pilot, group: .adaptive, visit: .V2, hintProtocolVersion: MultimodalFeedback.version)
        XCTAssertThrowsError(try ResearchProtocol.validate(invalid))
    }
    func testPaintAndPressureDecisionsUseCurrentMeasurements() {
        XCTAssertEqual(MultimodalFeedback.candidates(evidence()).first, .mixStir)
        XCTAssertEqual(MultimodalFeedback.candidates(evidence(metrics: ["redPaintUnits": 1])).first, .mixAddYellow)
        XCTAssertEqual(MultimodalFeedback.candidates(evidence("pressure", metrics: ["pencilSampleCount": 30, "signedPressureError": 0.4])).first, .pressureLighter)
        XCTAssertEqual(MultimodalFeedback.candidates(evidence("pressure", metrics: ["pencilSampleCount": 30, "signedPressureError": -0.2])).first, .pressureFirmer)
        XCTAssertEqual(MultimodalFeedback.candidates(evidence("pressure", metrics: ["signedPressureError": 0.4])).first, .pressurePencil)
        XCTAssertEqual(MultimodalFeedback.candidates(evidence("pressure", metrics: ["pencilSampleCount": 30, "dynamicPressureTarget": 1, "signedPressureError": 0.4])).first, .pressureFollow)
    }
    func testFixedHintsDoNotDependOnEvidence() {
        XCTAssertEqual((1...3).map { MultimodalFeedback.fixed(task: "mix", level: $0) }, [.mixObserve, .mixStir, .mixCompare])
        XCTAssertEqual((1...3).map { MultimodalFeedback.fixed(task: "pressure", level: $0) }, [.pressureObserve, .pressureFollow, .pressureSteady])
    }
    func testFirstAttemptLimitAndCooldownStillApply() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), e = evidence()
        XCTAssertEqual(MultimodalFeedback.blockReason(phase: .training, group: .adaptive, evidence: nil, history: [], at: now), "first_independent_attempt_required")
        let hint = MultimodalFeedback.support(evidence: e, group: .adaptive, level: 1, strategy: .mixStir, source: "local_fallback", trigger: "test", at: now)
        XCTAssertEqual(MultimodalFeedback.blockReason(phase: .training, group: .adaptive, evidence: e, history: [hint], at: now.addingTimeInterval(14)), "cooldown_active")
        XCTAssertNil(MultimodalFeedback.blockReason(phase: .training, group: .adaptive, evidence: e, history: [hint], at: now.addingTimeInterval(15)))
        XCTAssertEqual(MultimodalFeedback.blockReason(phase: .training, group: .adaptive, evidence: e, history: [hint, hint, hint], at: now.addingTimeInterval(20)), "prompt_limit_reached")
        XCTAssertEqual(MultimodalFeedback.blockReason(phase: .assessment, group: .adaptive, evidence: e, history: [], at: now), "feedback_disabled_outside_training")
    }
    func testLivePaintAttemptCanReceiveHintBeforeFinalSaveAndReplaysExactly() throws {
        let config = ResearchConfiguration(participantCode: "TEST", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix, hintProtocolVersion: MultimodalFeedback.version)
        var record = ResearchRecord(configuration: config)
        let e = evidence(), taskID = ResearchProtocol.tasks(for: config)[0].id
        func append(_ action: ResearchAction) throws {
            record.events.append(.init(sequence: record.events.count + 1, taskID: taskID, action: action)); _ = try record.replay()
        }
        try append(.drawingLinked(.init(id: e.drawingID, trialID: "mix-orange", background: .init(kind: "pigment", subject: "orange", pigmentModel: StandardPalette.mixingVersion))))
        try append(.hintObserved(e))
        let hint = MultimodalFeedback.support(evidence: e, group: .fixed, level: 1, strategy: .mixObserve, source: "fixed", trigger: "test")
        try append(.feedback(hint)); try append(.hintDelivered(feedbackID: hint.id, kind: .displayed))
        let state = try DrawingJSON.decoder().decode(ResearchRecord.self, from: DrawingJSON.encoder().encode(record)).replay()
        XCTAssertEqual(state.current?.feedback.count, 1); XCTAssertEqual(state.current?.attemptCount, 0)
        XCTAssertEqual(state.current?.drawings.first?.finished, false)
        var bad = state
        XCTAssertThrowsError(try bad.apply(.init(sequence: record.events.count + 1, taskID: taskID, action: .hintObserved(evidence()))))
    }
    func testEvidenceExcludesFreeTextAndInvalidNumbers() {
        XCTAssertFalse(evidence(metrics: ["unexpected": 1]).valid)
        XCTAssertFalse(evidence(metrics: ["redPaintUnits": .infinity]).valid)
        let e = evidence()
        let json = String(data: try! JSONEncoder().encode(e.summary), encoding: .utf8)!
        XCTAssertFalse(json.contains("drawingID")); XCTAssertFalse(json.contains("focusX")); XCTAssertFalse(json.contains("participant"))
    }
}
