import XCTest
import UIKit
import Combine
import InkStudyCore
@testable import InkStudy

@MainActor
final class ResearchAppTests: XCTestCase {
    private func environment() -> (URL, UserDefaults) {
        let id = UUID().uuidString
        return (FileManager.default.temporaryDirectory.appendingPathComponent("ResearchAppTests-" + id), UserDefaults(suiteName: id)!)
    }
    private func configuration(_ kind: ResearchTaskKind = .pressure) -> ResearchConfiguration {
        .init(participantCode: "UNIT_TEST", purpose: .rehearsal, group: .fixed, visit: .practice, practiceKind: kind)
    }
    private func waitForCapture(_ capture: ResearchDrawingCoordinator) async throws {
        for _ in 0..<50 {
            if capture.reference?.finished == true, !capture.busy, !capture.research.locked { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Controlled stroke did not save automatically: \(capture.error ?? capture.research.notice ?? "unknown")")
    }

    func testControlledLiftAutomaticallySavesAndRetryPreservesOriginal() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration())
        let task = try XCTUnwrap(research.current?.task)
        let capture = ResearchDrawingCoordinator(research: research, task: task)
        let loading = capture.studio.$isLoading.sink { [weak capture] _ in capture?.syncLock() }
        defer { loading.cancel() }
        await capture.start()
        XCTAssertEqual(capture.studio.brush, .init(color: .researchLine, size: 80))
        capture.studio.setFingerInput(true)
        var renderedEvents = 0
        capture.studio.didApplyEvent = { _ in renderedEvents += 1 }
        let firstID = try XCTUnwrap(capture.referenceID), strokeID = UUID()
        let samples = (0..<30).map { TouchSample(uptime: Double($0) / 100, x: 100 + Double($0) * 30, y: 425, force: 1, maximumPossibleForce: 4) }
        XCTAssertTrue(capture.studio.beginStroke(id: strokeID, transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples))
        capture.studio.endActive(.lifted)
        try await waitForCapture(capture)
        XCTAssertGreaterThan(renderedEvents, 0)
        XCTAssertEqual(capture.reference?.valid, true)
        XCTAssertEqual(capture.reference?.selectedStrokeID, strokeID)
        XCTAssertTrue(capture.studio.interactionLocked)
        let original = try await capture.studio.storedDocument(firstID)
        XCTAssertEqual(try original.replay().strokes.first?.style, .init(color: .researchLine, size: 80))
        await capture.prepare(retry: true)
        XCTAssertNotEqual(capture.referenceID, firstID)
        XCTAssertEqual(capture.studio.brush, .init(color: .researchLine, size: 80))
        XCTAssertTrue(capture.studio.fingerInputEnabled)
        XCTAssertFalse(capture.studio.interactionLocked)
        let untouched = try await capture.studio.storedDocument(firstID)
        XCTAssertEqual(original.metadata, untouched.metadata); XCTAssertEqual(original.events, untouched.events)
        XCTAssertEqual(research.current?.selectedTrials[try XCTUnwrap(capture.trial?.id)], firstID)
    }

    func testDrawingLinkSurvivesCrashBeforeCanvasCreation() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration(.creation))
        let task = try XCTUnwrap(research.current?.task)
        let reference = ResearchDrawingReference(trialID: task.id + "-open", background: nil)
        let linked = await research.perform(.drawingLinked(reference)); XCTAssertTrue(linked)
        let restored = ResearchController(directory: directory, preferences: preferences)
        await restored.start()
        let capture = ResearchDrawingCoordinator(research: restored, task: task)
        await capture.start()
        XCTAssertEqual(capture.referenceID, reference.id)
        XCTAssertEqual(capture.studio.state?.metadata.id, reference.id)
        XCTAssertNil(capture.studio.state?.activeStrokeID)
        XCTAssertEqual(restored.current?.drawings.count, 1)
    }

    func testCompleteSixTrialPracticeExportsEveryOriginalAndRestoresCompletion() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration())
        let task = try XCTUnwrap(research.current?.task)
        let capture = ResearchDrawingCoordinator(research: research, task: task)
        await capture.start()
        var drawingIDs: [UUID] = []
        for index in 0..<6 {
            XCTAssertEqual(capture.trialIndex, index)
            drawingIDs.append(try XCTUnwrap(capture.referenceID))
            let samples = (0..<30).map { TouchSample(uptime: Double($0) / 100, x: 100 + Double($0) * 30,
                y: 425, force: 0.2 + Double($0) / 30, maximumPossibleForce: 4) }
            XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: .init(viewWidth: 1200, viewHeight: 850,
                paperWidth: 1200, paperHeight: 850), samples: samples))
            capture.studio.endActive(.lifted)
            try await waitForCapture(capture)
            XCTAssertEqual(capture.reference?.valid, true)
            XCTAssertEqual(capture.studio.state?.strokes.first?.style, .init(color: .researchLine, size: 80))
            if index < 5 { await capture.nextTrial() }
        }
        XCTAssertEqual(Set(drawingIDs).count, 6)
        XCTAssertEqual(research.current?.selectedTrials.count, 6)
        await research.finishTask()
        XCTAssertEqual(research.state?.endReason, .completed)
        let completed = try XCTUnwrap(research.record)
        let restored = ResearchController(directory: directory, preferences: preferences)
        await restored.start()
        XCTAssertNil(restored.record)
        await restored.open(completed.id)
        XCTAssertEqual(restored.state?.endReason, .completed)
        XCTAssertEqual(restored.record, completed)
        let archive = try await ResearchExport.create(record: completed, directory: directory)
        let folder = archive.deletingPathExtension()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["endReason"] as? String, "completed")
        XCTAssertEqual(manifest["missingDrawingIDs"] as? [String], [])
        for id in drawingIDs {
            let data = try Data(contentsOf: folder.appendingPathComponent("drawings/\(id.uuidString)/raw.json"))
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(raw["events"])
        }
        let attachment = XCTAttachment(contentsOfFile: archive)
        attachment.name = "research-complete-six-trials.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNextTrialStaysOnCurrentPaperWhilePaused() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration())
        let task = try XCTUnwrap(research.current?.task)
        let capture = ResearchDrawingCoordinator(research: research, task: task)
        await capture.start()
        let firstID = try XCTUnwrap(capture.referenceID)
        let samples = (0..<30).map { TouchSample(uptime: Double($0) / 100, x: 100 + Double($0) * 30,
            y: 425, force: 1, maximumPossibleForce: 4) }
        XCTAssertTrue(capture.studio.beginStroke(id: UUID(), transform: .init(viewWidth: 1200, viewHeight: 850,
            paperWidth: 1200, paperHeight: 850), samples: samples))
        capture.studio.endActive(.lifted)
        try await waitForCapture(capture)
        let paused = await research.perform(.paused); XCTAssertTrue(paused)
        await capture.nextTrial()
        XCTAssertEqual(capture.trialIndex, 0)
        XCTAssertEqual(capture.referenceID, firstID)
        let resumed = await research.perform(.resumed); XCTAssertTrue(resumed)
        await capture.nextTrial()
        XCTAssertEqual(capture.trialIndex, 1)
        XCTAssertNotEqual(capture.referenceID, firstID)
        XCTAssertTrue(capture.studio.canDraw)
    }

    func testResearchStorageFailureIsRetryableWithoutLosingDraft() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration(.mix))
        let folder = directory.appendingPathComponent("Research"), backup = directory.appendingPathComponent("RetainedResearch")
        try FileManager.default.moveItem(at: folder, to: backup)
        XCTAssertTrue(FileManager.default.createFile(atPath: folder.path, contents: Data()))
        research.draft("firstColor", "red")
        do { try await research.flush(); XCTFail("Expected disk failure") } catch { }
        XCTAssertNotNil(research.saveError)
        XCTAssertEqual(research.current?.drafts["firstColor"], "red")
        try FileManager.default.removeItem(at: folder); try FileManager.default.moveItem(at: backup, to: folder)
        await research.retry(); XCTAssertNil(research.saveError)
        let reopened = ResearchController(directory: directory, preferences: preferences)
        await reopened.start()
        XCTAssertEqual(reopened.current?.drafts["firstColor"], "red")
        XCTAssertEqual(reopened.record?.events.count, 2)
    }

    func testResearchToolDefaultsPersistWhileInteractionRemainsLocked() async throws {
        let (directory, preferences) = environment()
        let studio = StudioModel(directory: directory, preferences: preferences)
        let c = configuration(), task = ResearchProtocol.tasks(for: c)[0], id = UUID()
        let context = DrawingContext(sessionID: c.id, task: task, trialID: "locked-trial", purpose: c.purpose)
        let style = BrushStyle(color: .researchLine, size: 80)
        studio.interactionLocked = true
        try await studio.activateResearchDocument(id: id, context: context, background: nil, neutral: false,
            initialBrush: style, fingerInput: true)
        XCTAssertTrue(studio.interactionLocked)
        XCTAssertFalse(studio.canDraw)
        XCTAssertFalse(studio.isLoading)
        XCTAssertEqual(studio.brush, style)
        XCTAssertTrue(studio.fingerInputEnabled)
        let saved = try await studio.storedDocument()
        XCTAssertEqual(try saved.replay().brush, style)
        XCTAssertTrue(try saved.replay().fingerInputEnabled)
        let restored = StudioModel(directory: directory, preferences: preferences)
        restored.interactionLocked = true
        try await restored.activateResearchDocument(id: id, context: context, background: nil, neutral: false,
            initialBrush: style)
        let reloaded = try await restored.storedDocument()
        XCTAssertEqual(saved.events, reloaded.events)
        XCTAssertTrue(restored.fingerInputEnabled)
    }

    func testResearchDefaultsDoNotRewriteExistingStrokes() async throws {
        let (directory, preferences) = environment()
        let studio = StudioModel(directory: directory, preferences: preferences)
        let c = configuration(), task = ResearchProtocol.tasks(for: c)[0], id = UUID()
        let context = DrawingContext(sessionID: c.id, task: task, trialID: "legacy-trial", purpose: c.purpose)
        try await studio.activateResearchDocument(id: id, context: context, background: nil, neutral: false)
        let originalStyle = studio.brush
        XCTAssertTrue(studio.beginStroke(id: UUID(), transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850),
            samples: [.init(uptime: 1, x: 100, y: 425, force: 1, maximumPossibleForce: 4)]))
        studio.endActive(.lifted)
        let original = try await studio.storedDocument()
        studio.interactionLocked = true
        try await studio.activateResearchDocument(id: id, context: context, background: nil, neutral: false,
            initialBrush: .init(color: .researchLine, size: 80), fingerInput: true)
        let restored = try await studio.storedDocument()
        XCTAssertEqual(original.metadata, restored.metadata)
        XCTAssertEqual(original.events, restored.events)
        XCTAssertEqual(studio.brush, originalStyle)
        XCTAssertFalse(studio.fingerInputEnabled)
        XCTAssertTrue(studio.interactionLocked)
    }

    func testResearchDefaultsDoNotEnableFingerInputOutsideRehearsal() async throws {
        let (directory, preferences) = environment()
        let studio = StudioModel(directory: directory, preferences: preferences)
        let c = configuration(), task = ResearchProtocol.tasks(for: c)[0]
        try await studio.activateResearchDocument(id: UUID(), context: .init(sessionID: c.id, task: task, trialID: "pilot-trial", purpose: .pilot),
            background: nil, neutral: false, initialBrush: .init(color: .researchLine, size: 80), fingerInput: true)
        XCTAssertFalse(studio.fingerInputEnabled)
        let saved = try await studio.storedDocument()
        XCTAssertFalse(try saved.replay().fingerInputEnabled)
    }

    func testResearchDocumentsDoNotReplaceFreeStudioSelection() async throws {
        let (directory, preferences) = environment()
        let studio = StudioModel(directory: directory, preferences: preferences)
        await studio.start(); let freeID = try XCTUnwrap(studio.state?.metadata.id)
        let c = configuration(.coloring), task = ResearchProtocol.tasks(for: c)[0], researchID = UUID()
        try await studio.activateResearchDocument(id: researchID, context: .init(sessionID: c.id, task: task, trialID: "trial", purpose: c.purpose),
            background: .init(kind: "outline", subject: "cat"), neutral: false)
        let reopened = StudioModel(directory: directory, preferences: preferences)
        await reopened.start()
        XCTAssertEqual(reopened.state?.metadata.id, freeID)
        XCTAssertEqual(reopened.library.map(\.id), [freeID])
        await reopened.openDocument(researchID)
        XCTAssertEqual(reopened.state?.metadata.id, freeID)
    }

    func testOutlinesGuidesAndNeutralAssessmentRendering() throws {
        var hashes = Set<String>()
        for subject in BackgroundRenderer.subjects + ["form-A", "form-B", "form-C"] {
            let metadata = DocumentMetadata(title: "Synthetic outline QA", background: .init(kind: "outline", subject: subject))
            let image = InkRenderer.artwork(try DrawingState(metadata: metadata), scale: 1)
            hashes.insert(RawDrawingExport.sha256(try XCTUnwrap(image.pngData())))
            let attachment = XCTAttachment(image: image); attachment.name = "Outline-" + subject; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(hashes.count, 9)
        let metadata = DocumentMetadata(title: "Neutral synthetic pressure QA", neutralRendering: true), strokeID = UUID()
        let samples = (0...100).map { TouchSample(uptime: Double($0) / 100, x: 100 + Double($0) * 10, y: 425, force: 0.1 + Double($0) / 40, maximumPossibleForce: 4) }
        let event = DrawingEvent(documentID: metadata.id, sequence: 1, payload: .strokeBegan(strokeID: strokeID, style: .init(color: InkColor.palette[0], size: 96),
            transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples))
        let image = InkRenderer.artwork(try DrawingState(metadata: metadata, events: [event]), scale: 1)
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 1200 * 850 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1200, height: 850, bitsPerComponent: 8, bytesPerRow: 1200 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1200, height: 850))
        func width(_ x: Int) -> Int { (0..<850).filter { bytes[($0 * 1200 + x) * 4 + 1] < 200 }.count }
        XCTAssertEqual(width(200), width(1000)); XCTAssertGreaterThan(width(200), 0)
    }

    func testResearchExportIncludesSourceHashesAndMissingReferenceDisclosure() async throws {
        let (directory, preferences) = environment()
        let research = ResearchController(directory: directory, preferences: preferences)
        await research.create(configuration(.creation))
        let task = try XCTUnwrap(research.current?.task)
        let capture = ResearchDrawingCoordinator(research: research, task: task)
        await capture.start()
        let sourceID = try XCTUnwrap(capture.referenceID)
        let missing = ResearchDrawingReference(trialID: "missing-at-crash", background: nil)
        _ = await research.perform(.drawingLinked(missing))
        _ = await research.perform(.stopped(.technicalError))
        let record = try XCTUnwrap(research.record)
        let archive = try await ResearchExport.create(record: record, directory: directory)
        let folder = archive.deletingPathExtension()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let missingIDs = try XCTUnwrap(manifest["missingDrawingIDs"] as? [String])
        XCTAssertEqual(missingIDs, [missing.id.uuidString])
        let hashes = try XCTUnwrap(manifest["sha256"] as? [String: String])
        XCTAssertNotNil(hashes["drawings/\(sourceID.uuidString)/raw.json"])
        for (path, hash) in hashes { XCTAssertEqual(hash, RawDrawingExport.sha256(try Data(contentsOf: folder.appendingPathComponent(path)))) }
        let attachment = XCTAttachment(contentsOfFile: archive); attachment.name = "research-export.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
