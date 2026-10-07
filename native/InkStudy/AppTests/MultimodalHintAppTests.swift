import XCTest
import InkStudyCore
@testable import InkStudy

@MainActor
private final class StubHintSelector: HintSelecting {
    var calls = 0
    var fail = false
    var wait = false
    var continuation: CheckedContinuation<Void, Never>?
    var forcedStrategy: HintStrategy?
    func select(evidence: HintEvidence, level: Int, requestID: UUID) async throws -> RemoteHint {
        calls += 1
        if wait { await withCheckedContinuation { continuation = $0 } }
        if fail { throw HintClientError(code: "synthetic_offline") }
        return .init(requestID: requestID, strategy: forcedStrategy ?? MultimodalFeedback.candidates(evidence)[0],
            model: "deepseek-flash", latencyMilliseconds: 25, version: MultimodalFeedback.version)
    }
}

@MainActor
final class MultimodalHintAppTests: XCTestCase {
    private func environment(group: ResearchGroup = .adaptive, kind: ResearchTaskKind = .mix) async -> ResearchController {
        let id = UUID().uuidString
        let research = ResearchController(directory: FileManager.default.temporaryDirectory.appendingPathComponent("HintTests-" + id), preferences: UserDefaults(suiteName: id)!)
        await research.create(.init(participantCode: "HINT_SYNTHETIC", purpose: .rehearsal, group: group, visit: .practice,
            practiceKind: kind, hintProtocolVersion: MultimodalFeedback.version))
        return research
    }
    private func mix(_ research: ResearchController, both: Bool = true) async throws -> PigmentMixingCoordinator {
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        await capture.prepare()
        for color in both ? ["red", "yellow"] : ["red"] {
            capture.selectBrush(color)
            let points = (0..<24).map { TouchSample(uptime: Double($0) / 60, x: 200 + Double($0) * 20,
                y: color == "red" ? 360 : 480, force: 1.4, maximumPossibleForce: 4) }
            XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: points))
            capture.studio.endActive(.lifted)
        }
        try await capture.studio.flush()
        return capture
    }
    private func waitForCall(_ selector: StubHintSelector) async throws {
        for _ in 0..<100 { if selector.continuation != nil { return }; try await Task.sleep(for: .milliseconds(30)) }
        XCTFail("Hint did not reach selector")
    }
    func testFixedVisualHintWorksBeforeMixSaveWithoutCallingModel() async throws {
        let research = await environment(group: .fixed), selector = StubHintSelector(); research.hintSelector = selector
        let capture = try await mix(research)
        let original = try await capture.studio.storedDocument()
        await research.requestHint()
        XCTAssertEqual(research.visibleHint?.multimodal?.strategy, .mixObserve)
        XCTAssertEqual(research.current?.attemptCount, 0); XCTAssertEqual(selector.calls, 0)
        XCTAssertEqual(capture.reference?.finished, false)
        let after = try await capture.studio.storedDocument(); XCTAssertEqual(original.events, after.events)
        XCTAssertEqual(try research.record?.replay().current?.feedback.count, 1)
    }
    func testAdaptiveCloudHintAndVoiceDeliveryAreRecordedSeparately() async throws {
        let research = await environment(), selector = StubHintSelector(); research.hintSelector = selector
        let capture = try await mix(research)
        await research.requestHint()
        let hint = try XCTUnwrap(research.visibleHint)
        XCTAssertEqual(hint.multimodal?.strategy, .mixStir); XCTAssertEqual(hint.multimodal?.source, "deepseek")
        research.hintDelivered(hint.id, kind: .displayed); research.hintDelivered(hint.id, kind: .audioStarted)
        research.hintDelivered(hint.id, kind: .audioFinished); try await research.flush()
        let events = try XCTUnwrap(research.record).events
        XCTAssertEqual(events.filter { if case .hintDelivered = $0.action { return true }; return false }.count, 3)
        XCTAssertEqual(capture.studio.visibleCount, 2)
        let archive = try await ResearchExport.create(record: try XCTUnwrap(research.record), directory: research.directory)
        let attachment = XCTAttachment(contentsOfFile: archive); attachment.name = "hint-synthetic-audit.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCloudFailureUsesTaskRelevantHintAndPreservesFailureReason() async throws {
        let research = await environment(), selector = StubHintSelector(); selector.fail = true; research.hintSelector = selector
        let capture = try await mix(research, both: false)
        await research.requestHint()
        XCTAssertEqual(research.visibleHint?.multimodal?.strategy, .mixAddYellow)
        XCTAssertEqual(research.visibleHint?.multimodal?.source, "local_fallback")
        XCTAssertEqual(research.visibleHint?.multimodal?.fallbackReason, "synthetic_offline")
        XCTAssertEqual(capture.studio.visibleCount, 1)
    }
    func testUnapprovedResponseIsReplacedByLocalStrategy() async throws {
        let research = await environment(), selector = StubHintSelector(); selector.forcedStrategy = .pressureFirmer; research.hintSelector = selector
        let capture = try await mix(research)
        await research.requestHint()
        XCTAssertEqual(research.visibleHint?.multimodal?.strategy, .mixStir)
        XCTAssertEqual(research.visibleHint?.multimodal?.fallbackReason, "invalid_strategy")
        XCTAssertEqual(capture.studio.visibleCount, 2)
    }
    func testNoAttemptAndCooldownNeverSpendOnModel() async throws {
        let research = await environment(), selector = StubHintSelector(); research.hintSelector = selector
        let capture = PigmentMixingCoordinator(research: research, task: try XCTUnwrap(research.current?.task)); await capture.prepare()
        await research.requestHint(); XCTAssertEqual(selector.calls, 0)
        let painted = try await mix(research)
        await research.requestHint(); XCTAssertEqual(selector.calls, 1)
        await research.requestHint(); XCTAssertEqual(selector.calls, 1)
        XCTAssertEqual(painted.studio.visibleCount, 2)
    }
    func testLateCloudResponseIsDiscardedAfterPaperChanges() async throws {
        let research = await environment(), selector = StubHintSelector(); selector.wait = true; research.hintSelector = selector
        let capture = try await mix(research)
        let pending = Task { await research.requestHint() }
        try await waitForCall(selector)
        await capture.prepare(target: "green")
        selector.continuation?.resume(); await pending.value
        XCTAssertNil(research.visibleHint); XCTAssertEqual(research.current?.feedback.count, 0)
        XCTAssertEqual(capture.target, "green")
    }
    func testLateCloudResponseIsDiscardedAfterBrushChangesAndConcurrentTapIsIgnored() async throws {
        let research = await environment(), selector = StubHintSelector(); selector.wait = true; research.hintSelector = selector
        let capture = try await mix(research)
        let pending = Task { await research.requestHint() }
        try await waitForCall(selector)
        await research.requestHint(); XCTAssertEqual(selector.calls, 1)
        capture.selectBrush("red")
        selector.continuation?.resume(); await pending.value
        XCTAssertNil(research.visibleHint); XCTAssertEqual(research.current?.feedback.count, 0)
    }
    func testPressureHintUsesResolvedPencilAndCurrentTarget() async throws {
        let research = await environment(kind: .pressure), selector = StubHintSelector(); research.hintSelector = selector
        try await HintPreviewDemo.seed(research: research, kind: .pressure)
        let capture = ResearchDrawingCoordinator(research: research, task: try XCTUnwrap(research.current?.task))
        // Open the first saved trial, rather than advancing to the next blank target.
        await capture.prepare()
        await research.requestHint()
        XCTAssertEqual(research.visibleHint?.multimodal?.strategy, .pressureLighter)
        XCTAssertEqual(research.visibleHint?.multimodal?.evidence.target, "light")
        XCTAssertEqual(capture.reference?.finished, true)
    }
}
