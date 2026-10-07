import XCTest
@testable import InkStudyCore

final class ReleaseV2Tests: XCTestCase {
    func testPigmentExportDeclaresItsOwnRenderingFormula() throws {
        let metadata = DocumentMetadata(title: "mix", background: .init(kind: "pigment", subject: "orange"))
        let raw = try RawDrawingExport(document: .init(metadata: metadata, events: []))
        XCTAssertEqual(metadata.pressureMappingVersion, PigmentSurface.pressureVersion)
        XCTAssertEqual(raw.pressureMapping, PigmentSurface.pressureFormula)
        let ordinary = DocumentMetadata(title: "line")
        XCTAssertEqual(ordinary.pressureMappingVersion, PressureMapping.version)
        XCTAssertEqual(try RawDrawingExport(document: .init(metadata: ordinary, events: [])).pressureMapping, PressureMapping.formula)
    }

    func testPrimaryPairsUseRYBRatherThanRGBAddition() {
        let orange = PigmentSurface.color(red: 1, yellow: 1, blue: 0)
        XCTAssertEqual(orange.0, 232); XCTAssertEqual(orange.1, 120); XCTAssertEqual(orange.2, 46)
        let green = PigmentSurface.color(red: 0, yellow: 1, blue: 1)
        XCTAssertEqual(green.0, 61); XCTAssertEqual(green.1, 152); XCTAssertEqual(green.2, 96)
        let violet = PigmentSurface.color(red: 1, yellow: 0, blue: 1)
        XCTAssertEqual(violet.0, 119); XCTAssertEqual(violet.1, 80); XCTAssertEqual(violet.2, 149)
        let gradual = PigmentSurface.color(red: 1, yellow: 0.5, blue: 0)
        XCTAssertGreaterThan(gradual.1, 64); XCTAssertLessThan(gradual.1, orange.1)
    }

    func testPigmentOnlyMixesAtOverlapAndIsIndependentOfEventBatching() {
        let line = (0...30).map { TouchSample(uptime: Double($0), x: 150 + Double($0) * 13.7, y: 425, input: .finger) }
        let red = BrushStyle(color: InkColor.legacyPalette[0], size: 96), yellow = BrushStyle(color: InkColor.legacyPalette[2], size: 96)
        var surface = PigmentSurface(), chunked = PigmentSurface()
        surface.begin(style: red, samples: line)
        chunked.begin(style: red, samples: Array(line.prefix(3)))
        for sample in line.dropFirst(3) { chunked.append([sample]) }
        XCTAssertEqual(surface.rgba, chunked.rgba)
        let original = surface.rgba
        surface.begin(style: yellow, samples: line.map { var point = $0; point.y = 600; return point })
        XCTAssertEqual(surface.metrics["mixedPixels"], 0)
        let pixel = (212 * 600 + 180) * 4
        XCTAssertEqual(Array(surface.rgba[pixel..<pixel + 4]), Array(original[pixel..<pixel + 4]))
        surface.begin(style: yellow, samples: line)
        XCTAssertGreaterThan(surface.metrics["mixedPixels"] ?? 0, 1000)
        XCTAssertGreaterThan(surface.rgba[pixel + 1], original[pixel + 1])
        XCTAssertGreaterThan(surface.rgba[pixel], 200)
    }

    func testPressureProfilesChangeTrainingWithoutChangingLegacyOrAssessment() throws {
        func configuration(_ version: String) -> ResearchConfiguration {
            .init(participantCode: "PROFILE_QA", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .pressure, protocolVersion: version)
        }
        let modern = ResearchProtocol.tasks(for: configuration(ResearchProtocol.version))[0]
        let trials = LineExercises.trials(task: modern)
        XCTAssertEqual(trials.count, 6); XCTAssertEqual(trials.compactMap(\.pressureProfile), PressureProfile.allCases)
        XCTAssertLessThan(trials[3].targetForce(at: 0), trials[3].targetForce(at: 1))
        XCTAssertGreaterThan(trials[4].targetForce(at: 0), trials[4].targetForce(at: 1))
        let legacy = ResearchProtocol.tasks(for: configuration(ResearchProtocol.legacyVersion))[0]
        XCTAssertTrue(LineExercises.trials(task: legacy).allSatisfy { $0.pressureProfile == nil })
        let assessment = ResearchTask(id: "assessment", kind: .pressure, phase: .assessment, form: "A", variant: "pressure-profiles-v2")
        XCTAssertTrue(LineExercises.trials(task: assessment).allSatisfy { $0.pressureProfile == nil })
        let background = try DrawingJSON.decoder().decode(DrawingBackground.self, from: Data(#"{"kind":"guide","subject":"pressure","target":0.3,"reverse":false}"#.utf8))
        XCTAssertNil(background.pressureProfile)
        let record = ResearchRecord(configuration: configuration(ResearchProtocol.legacyVersion))
        XCTAssertEqual(try DrawingJSON.decoder().decode(ResearchRecord.self, from: DrawingJSON.encoder().encode(record)).replay().activities[0].task, legacy)
    }

    func testDynamicMetricsComparePositionSpecificPressureTarget() {
        let trial = ResearchLineTrial(id: "ramp", label: "ramp", kind: "pressure", target: 0.15, reverse: false, pressureProfile: .lightToFirm)
        let samples = (0...100).map { i in
            TouchSample(uptime: Double(i), x: 100 + Double(i) * 10, y: 425, force: 4 * trial.targetForce(at: Double(i) / 100), maximumPossibleForce: 4)
        }
        let stroke = InkStroke(id: UUID(), style: .init(), transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples, endReason: .lifted)
        let metrics = LineExercises.metrics(stroke: stroke, trial: trial)
        XCTAssertEqual(metrics["pressureMAE"] ?? 1, 0, accuracy: 0.000001)
        XCTAssertEqual(metrics["dynamicPressureTarget"], 1)
    }

    func testNarrationLogsOnlyAlreadyShownFeedbackAndSurvivesReplay() throws {
        let c = ResearchConfiguration(participantCode: "VOICE_QA", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: .mix)
        var record = ResearchRecord(configuration: c)
        let taskID = ResearchProtocol.tasks(for: c)[0].id
        func append(_ action: ResearchAction) throws {
            record.events.append(.init(sequence: record.events.count + 1, taskID: taskID, action: action))
            _ = try record.replay()
        }
        try append(.narrationRequested(text: "试着叠涂两种颜色。", kind: .instruction, feedbackID: nil, voiceID: "test-voice"))
        var state = try record.replay()
        XCTAssertThrowsError(try state.apply(.init(sequence: 2, taskID: taskID, action: .narrationRequested(text: "未显示提示", kind: .feedback, feedbackID: UUID(), voiceID: "test"))))
        try append(.answered(questionID: "orange", value: "red+yellow", metrics: [:]))
        let support = ResearchFeedback.decide(group: .fixed, phase: .training, evidence: .init(task: "mix", attempts: 1), history: [])
        try append(.feedback(support))
        try append(.narrationRequested(text: try XCTUnwrap(support.text), kind: .feedback, feedbackID: support.id, voiceID: "test-voice"))
        let decoded = try DrawingJSON.decoder().decode(ResearchRecord.self, from: DrawingJSON.encoder().encode(record))
        XCTAssertEqual(try decoded.replay().current?.narrations.count, 2)
        XCTAssertEqual(try decoded.replay().current?.attemptCount, 1)
    }
}
