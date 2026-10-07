import XCTest
@testable import InkStudyCore

final class ResearchCoreTests: XCTestCase {
    private func config(_ visit: ResearchVisit = .practice, group: ResearchGroup = .fixed,
                        purpose: ResearchPurpose = .rehearsal, kind: ResearchTaskKind = .mix,
                        order: Int = 0, wind: Bool = true) -> ResearchConfiguration {
        .init(participantCode: "TEST_01", purpose: purpose, group: group, visit: visit, formOrder: order,
              windFirst: wind, allocationReference: "ALLOC-1", practiceKind: visit == .practice ? kind : nil)
    }
    private func append(_ action: ResearchAction, to record: inout ResearchRecord, at: Date = Date()) throws {
        let state = try record.replay()
        record.events.append(.init(sequence: record.events.count + 1, taskID: try XCTUnwrap(state.current?.task.id), at: at, action: action))
        _ = try record.replay()
    }
    private func complete(_ configuration: ResearchConfiguration) throws -> ResearchRecord {
        var record = ResearchRecord(configuration: configuration)
        while let activity = try record.replay().current {
            try completeCurrent(&record, activity: activity)
        }
        return record
    }
    private func completeCurrent(_ record: inout ResearchRecord, activity: ResearchActivity) throws {
        switch activity.task.kind {
        case .knowledge:
            for question in ColorExercises.questions(form: activity.task.form) { try append(.answered(questionID: question.id, value: question.options[0].id, metrics: [:]), to: &record) }
        case .mix:
            for color in ["orange", "green", "violet"] { try append(.answered(questionID: color, value: "red+red", metrics: [:]), to: &record) }
        case .wheel: try append(.answered(questionID: "wheel", value: InkColor.palette.map(\.id).joined(separator: ","), metrics: [:]), to: &record)
        case .pressure, .path:
            for trial in LineExercises.trials(task: activity.task) {
                let reference = ResearchDrawingReference(trialID: trial.id, background: trial.background)
                try append(.drawingLinked(reference), to: &record)
                try append(.drawingFinished(id: reference.id, strokeID: UUID(), valid: true, metrics: ["testFixture": 1], reason: nil), to: &record)
            }
        case .coloring, .device, .emotion, .creation:
            let reference = ResearchDrawingReference(trialID: "test-open", background: nil)
            try append(.drawingLinked(reference), to: &record)
            try append(.drawingFinished(id: reference.id, strokeID: nil, valid: true, metrics: ["testFixture": 1], reason: nil), to: &record)
        case .familiarization:
            for key in ["assent", "familiarized"] { try append(.draft(key: key, value: "yes"), to: &record) }
        case .interview:
            for key in ["meaning", "choices", "change"] { try append(.draft(key: key, value: "未作答"), to: &record) }
        case .experience:
            for key in ["enjoyment", "difficulty", "again"] { try append(.draft(key: key, value: "未作答"), to: &record) }
        case .paper:
            for key in ["teacherCode", "paperArtifactCode", "implementationNotes", "paperCompleted"] { try append(.draft(key: key, value: "yes"), to: &record) }
        case .transition, .rest: break
        }
        try append(.taskCompleted, to: &record)
    }

    func testAllVisitsAndThreeArmsHaveCompleteUntimedTaskGraphs() throws {
        for group in [ResearchGroup.paper, .fixed, .adaptive] {
            for visit in ResearchVisit.allCases.filter({ $0 != .practice }) {
                let c = config(visit, group: [.V1a, .V1b].contains(visit) ? .unassigned : group)
                let record = try complete(c)
                XCTAssertEqual(try record.replay().endReason, .completed)
                XCTAssertFalse(ResearchProtocol.tasks(for: c).isEmpty)
                if group == .paper, [.V2, .V3, .V4, .V5].contains(visit) {
                    XCTAssertEqual(ResearchProtocol.tasks(for: c).filter { $0.phase == .training }.map(\.kind), [.paper])
                }
            }
        }
    }

    func testFormalAndIdentifyingCodesAreBlocked() throws {
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V1a, group: .unassigned, purpose: .formal)))
        XCTAssertThrowsError(try ResearchProtocol.validate(.init(participantCode: "儿童姓名", purpose: .pilot, group: .unassigned, visit: .V1a)))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V1a, group: .fixed)))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.practice, group: .paper)))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.practice, purpose: .pilot)))
    }

    func testPilotSequenceAndAssignmentAreFrozen() throws {
        let v1a = try complete(config(.V1a, group: .unassigned, purpose: .pilot))
        XCTAssertNoThrow(try ResearchProtocol.validate(config(.V1b, group: .unassigned, purpose: .pilot), prior: [v1a]))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V2, purpose: .pilot), prior: [v1a]))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V1a, group: .unassigned, purpose: .pilot), prior: [v1a]))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V1b, group: .unassigned, purpose: .pilot, order: 1), prior: [v1a]))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V1b, group: .unassigned, purpose: .pilot, wind: false), prior: [v1a]))
        let v1b = try complete(config(.V1b, group: .unassigned, purpose: .pilot))
        let v2 = try complete(config(.V2, purpose: .pilot))
        XCTAssertThrowsError(try ResearchProtocol.validate(config(.V3, group: .adaptive, purpose: .pilot), prior: [v1a, v1b, v2]))
        XCTAssertNoThrow(try ResearchProtocol.validate(config(.V3, purpose: .pilot), prior: [v1a, v1b, v2]))
    }

    func testAllSevenVisitsRequiredBeforeParticipantGeneration() throws {
        var records = try ResearchVisit.allCases.filter { $0 != .practice && $0 != .V7 }.map {
            try complete(config($0, group: [.V1a, .V1b].contains($0) ? .unassigned : .fixed, purpose: .pilot))
        }
        XCTAssertFalse(ResearchProtocol.generationAllowed(participantCode: "TEST_01", records: records))
        XCTAssertTrue(ResearchProtocol.generationAllowed(participantCode: nil, records: records))
        records.append(try complete(config(.V7, purpose: .pilot)))
        XCTAssertTrue(ResearchProtocol.generationAllowed(participantCode: "TEST_01", records: records))
    }

    func testColorFormsMixesAndWheelSymmetry() throws {
        for (first, second, result) in ColorExercises.pairs {
            XCTAssertEqual(ColorExercises.mix(first, second), result); XCTAssertEqual(ColorExercises.mix(second, first), result)
        }
        let order = InkColor.palette.map(\.id)
        for offset in 0..<6 {
            let rotation = Array(order[offset...] + order[..<offset])
            XCTAssertEqual(ColorExercises.wheelScore(rotation), 6)
            XCTAssertEqual(ColorExercises.wheelScore(rotation.reversed()), 6)
        }
        XCTAssertEqual(ColorExercises.wheelScore(Array(repeating: "red", count: 6)), 0)
        for form in ["A", "B", "C"] {
            let questions = ColorExercises.questions(form: form)
            XCTAssertEqual(questions.count, 14); XCTAssertEqual(Set(questions.map(\.id)).count, 14)
            XCTAssertTrue(questions.allSatisfy { q in q.options.contains { $0.id == q.answer } })
            XCTAssertEqual(questions, ColorExercises.questions(form: form))
        }
    }

    func testPracticeCompletionRequiresAttemptsNotMastery() throws {
        let record = try complete(config())
        let activity = try XCTUnwrap(record.replay().activities.first)
        XCTAssertTrue(activity.responses.allSatisfy { $0.correct == false })
        XCTAssertEqual(try record.replay().endReason, .completed)
    }

    func testKnowledgeFirstAnswerCannotBeReplaced() throws {
        let c = config(.V7)
        var state = ResearchState(configuration: c)
        let task = try XCTUnwrap(state.current?.task), question = try XCTUnwrap(ColorExercises.questions(form: task.form).first)
        try state.apply(.init(sequence: 1, taskID: task.id, action: .answered(questionID: question.id, value: question.options[0].id, metrics: [:])))
        XCTAssertThrowsError(try state.apply(.init(sequence: 2, taskID: task.id, action: .answered(questionID: question.id, value: question.answer, metrics: [:]))))
        XCTAssertEqual(state.current?.responses.count, 1)
    }

    func testAssessmentFreezesFirstValidButTrainingAllowsRetry() throws {
        for training in [false, true] {
            var record = ResearchRecord(configuration: training ? config(kind: .pressure) : config(.V1a, group: .unassigned))
            while let current = try record.replay().current, current.task.kind != .pressure { try completeCurrent(&record, activity: current) }
            let task = try XCTUnwrap(record.replay().current?.task), trial = try XCTUnwrap(LineExercises.trials(task: task).first)
            let invalid = ResearchDrawingReference(trialID: trial.id, background: trial.background)
            try append(.drawingLinked(invalid), to: &record)
            try append(.drawingFinished(id: invalid.id, strokeID: UUID(), valid: false, metrics: [:], reason: "technical"), to: &record)
            let valid = ResearchDrawingReference(trialID: trial.id, background: trial.background)
            try append(.drawingLinked(valid), to: &record)
            try append(.drawingFinished(id: valid.id, strokeID: UUID(), valid: true, metrics: ["pressureMAE": 0.4], reason: nil), to: &record)
            var state = try record.replay()
            let retry = ResearchDrawingReference(trialID: trial.id, background: trial.background)
            let event = ResearchEvent(sequence: state.lastSequence + 1, taskID: task.id, action: .drawingLinked(retry))
            if training { XCTAssertNoThrow(try state.apply(event)) } else { XCTAssertThrowsError(try state.apply(event)) }
            XCTAssertEqual(state.current?.selectedTrials[trial.id], valid.id)
        }
    }

    func testPressureMetricsUseResolvedPencilOnlyAndNoAccuracyGate() throws {
        let samples = (0..<30).map { i in TouchSample(uptime: Double(i) / 100, x: Double(i * 30), y: 425, force: 0.8, maximumPossibleForce: 4) }
        let stroke = InkStroke(id: UUID(), style: .init(), transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples, endReason: .lifted)
        let task = ResearchProtocol.tasks(for: config(kind: .pressure))[0], trial = LineExercises.trials(task: task)[0]
        let metrics = LineExercises.metrics(stroke: stroke, trial: trial)
        XCTAssertEqual(metrics["normalizedForceMean"]!, 0.2, accuracy: 0.00001)
        XCTAssertTrue(LineExercises.valid(metrics: metrics, rehearsal: false))
        XCTAssertFalse(LineExercises.valid(metrics: metrics, rehearsal: false, deviceCheck: true))
        var finger = stroke
        finger.samples = samples.map { var sample = $0; sample.input = .finger; return sample }
        let fingerMetrics = LineExercises.metrics(stroke: finger, trial: trial)
        XCTAssertNil(fingerMetrics["normalizedForceMean"])
        XCTAssertFalse(LineExercises.valid(metrics: fingerMetrics, rehearsal: false))
        XCTAssertTrue(LineExercises.valid(metrics: fingerMetrics, rehearsal: true))
    }

    func testFeedbackIsolationLimitsCooldownAndRealInference() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        var evidence = LearningEvidence(task: "mix", attempts: 0)
        XCTAssertFalse(ResearchFeedback.decide(group: .adaptive, phase: .training, evidence: evidence, history: [], at: at).allowed)
        evidence.attempts = 3; evidence.errorRate = 1
        for phase in [ResearchPhase.assessment, .transfer] {
            XCTAssertFalse(ResearchFeedback.decide(group: .adaptive, phase: phase, evidence: evidence, history: [], at: at).allowed)
        }
        XCTAssertFalse(ResearchFeedback.decide(group: .paper, phase: .training, evidence: evidence, history: [], at: at).allowed)
        var history: [ResearchSupport] = []
        for i in 0..<3 {
            let support = ResearchFeedback.decide(group: .fixed, phase: .training, evidence: evidence, history: history, at: at.addingTimeInterval(Double(i * 15)))
            XCTAssertTrue(support.allowed); XCTAssertFalse(support.adaptive); XCTAssertEqual(support.text, ResearchFeedback.fixed[i])
            history.append(support)
        }
        XCTAssertFalse(ResearchFeedback.decide(group: .fixed, phase: .training, evidence: evidence, history: Array(history.prefix(1)), at: at.addingTimeInterval(14)).allowed)
        XCTAssertFalse(ResearchFeedback.decide(group: .fixed, phase: .training, evidence: evidence, history: history, at: at.addingTimeInterval(90)).allowed)
        let inference = try LearningModel.infer(evidence)
        XCTAssertFalse(inference.fieldValidated); XCTAssertEqual(inference.features.count, 12)
        XCTAssertEqual(inference.probabilities.reduce(0, +), 1, accuracy: 0.000001)
        XCTAssertEqual(inference.trainingSource, "synthetic_task_telemetry")
        let adaptive = ResearchFeedback.decide(group: .adaptive, phase: .training, evidence: evidence, history: [], at: at)
        XCTAssertTrue(adaptive.allowed); XCTAssertNotNil(adaptive.inference)
        evidence.pressureError = .infinity
        XCTAssertThrowsError(try LearningModel.infer(evidence))
        XCTAssertEqual(ResearchFeedback.decide(group: .adaptive, phase: .training, evidence: evidence, history: [], at: at).reason, "model_unavailable")
    }

    func testHelpPauseAndStopKeepDurationsAndDoNotCompleteVisit() throws {
        var record = ResearchRecord(configuration: config())
        let start = Date(timeIntervalSince1970: 5_000)
        try append(.helpStarted(kind: .tools, operatorCode: "OP_1"), to: &record, at: start)
        try append(.paused, to: &record, at: start.addingTimeInterval(10))
        var state = try record.replay()
        XCTAssertThrowsError(try state.apply(.init(sequence: 3, taskID: state.current!.task.id, action: .draft(key: "test", value: "paused"))))
        try append(.helpFinished, to: &record, at: start.addingTimeInterval(25))
        try append(.stopped(.stopped), to: &record, at: start.addingTimeInterval(30))
        state = try record.replay()
        XCTAssertEqual(state.helps[0].durationSeconds, 25); XCTAssertEqual(state.endReason, .stopped)
        XCTAssertNil(state.activities[0].finishedAt)
    }

    func testResearchStoreDurableReopenAndIdempotency() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ResearchStore(directory: url), c = config()
        let record = try await store.create(c), taskID = try XCTUnwrap(record.replay().current?.task.id), eventID = UUID()
        _ = try await store.append(id: c.id, eventID: eventID, taskID: taskID, action: .draft(key: "firstColor", value: "red"))
        let reopened = try ResearchStore(directory: url)
        let saved = try await reopened.append(id: c.id, eventID: eventID, taskID: taskID, action: .draft(key: "firstColor", value: "red"))
        XCTAssertEqual(saved.events.count, 2)
        XCTAssertEqual(try saved.replay().current?.drafts["firstColor"], "red")
        do {
            _ = try await reopened.append(id: c.id, eventID: eventID, taskID: taskID, action: .draft(key: "firstColor", value: "blue"))
            XCTFail("ID conflict must not overwrite data")
        } catch { }
        let loaded = try await reopened.load(c.id)
        XCTAssertEqual(loaded, saved)
    }

    func testLegacyMetadataAndZIPInteroperability() throws {
        let old = Data("{\"id\":\"7A0DB9BD-E0A5-43A4-90ED-6CEAB468C1AD\",\"title\":\"legacy\",\"createdAt\":1788883200000,\"paperWidth\":1200,\"paperHeight\":850,\"deviceModel\":\"iPad\",\"osVersion\":\"18.7\",\"appVersion\":\"0.1.0\",\"purpose\":\"native-prototype\",\"schemaVersion\":1,\"pressureMappingVersion\":\"width-v1\"}".utf8)
        let metadata = try DrawingJSON.decoder().decode(DocumentMetadata.self, from: old)
        XCTAssertNil(metadata.context); XCTAssertNil(metadata.background); XCTAssertNil(metadata.neutralRendering)
        XCTAssertEqual(StoredZIP.crc32(Data("123456789".utf8)), 0xcbf43926)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("data.json"), zip = directory.appendingPathComponent("export.zip")
        try Data("test-data".utf8).write(to: source)
        try StoredZIP.write([.init(name: "研究/data.json", url: source)], to: zip)
        XCTAssertThrowsError(try StoredZIP.write([.init(name: "../bad", url: source)], to: directory.appendingPathComponent("bad.zip")))
        #if os(macOS)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zip.path]; process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        #endif
    }
}
