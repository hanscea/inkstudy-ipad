import UIKit
import InkStudyCore

private struct PigmentFrame: @unchecked Sendable {
    let image: CGImage?
    let sequence: Int
    let milliseconds: Double
    let statistics: IncrementalPigmentRenderer.Statistics
    let documentID: UUID
    let loadID: UUID?
    let remainingLoadFraction: Double
}

private actor PigmentRenderWorker {
    private var renderer = IncrementalPigmentRenderer()

    func render(_ state: DrawingState, changes: [DrawingEvent]) -> PigmentFrame {
        let start = ContinuousClock.now
        let changed = renderer.update(state, changes: changes)
        let image = changed ? renderer.surface.flatMap { PigmentRenderer.cgImage($0) } : nil
        let duration = start.duration(to: .now).components
        return .init(image: image, sequence: state.lastSequence,
            milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
            statistics: renderer.statistics, documentID: state.metadata.id, loadID: state.brush.pigmentLoadID,
            remainingLoadFraction: renderer.surface?.remainingLoadFraction(for: state.brush) ?? 0)
    }
}

@MainActor
final class PigmentDisplayController {
    struct Statistics {
        var requests = 0
        var presentedFrames = 0
        var fullReplays = 0
        var maxMilliseconds = 0.0
        var lastMilliseconds = 0.0
        var replayedSamples = 0
        var backgroundDurations: [Double] = []
    }

    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: PigmentDisplayController?
        @objc func tick() { owner?.tick() }
    }

    private let state: @MainActor () -> DrawingState?
    private let present: @MainActor (CGImage) -> Void
    private let loadStatus: @MainActor (UUID, UUID?, Double) -> Void
    private let worker = PigmentRenderWorker()
    private let target = DisplayTarget()
    private var displayLink: CADisplayLink?
    private var task: Task<Void, Never>?
    private var changes: [DrawingEvent] = []
    private var needsFrame = false
    private var generation = 0
    private var ready: PigmentFrame?
    private(set) var statistics = Statistics()
    private(set) var presentedSequence = -1

    isolated deinit { displayLink?.invalidate() }

    init(state: @escaping @MainActor () -> DrawingState?, present: @escaping @MainActor (CGImage) -> Void,
         loadStatus: @escaping @MainActor (UUID, UUID?, Double) -> Void = { _, _, _ in }) {
        self.state = state; self.present = present
        self.loadStatus = loadStatus
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func reset() {
        generation += 1
        changes.removeAll(keepingCapacity: true)
        ready = nil; needsFrame = true; presentedSequence = -1
        displayLink?.isPaused = false
    }

    func enqueue(_ event: DrawingEvent) {
        changes.append(event)
        needsFrame = true
        displayLink?.isPaused = false
    }

    func stop() {
        generation += 1
        changes.removeAll(); ready = nil; needsFrame = false
        displayLink?.invalidate(); displayLink = nil
    }

    private func tick() {
        if let frame = ready {
            ready = nil
            if let image = frame.image { present(image); statistics.presentedFrames += 1 }
            loadStatus(frame.documentID, frame.loadID, frame.remainingLoadFraction)
            presentedSequence = frame.sequence
        }
        guard task == nil, needsFrame else {
            if task == nil && !needsFrame { displayLink?.isPaused = true }
            return
        }
        guard let snapshot = state() else {
            needsFrame = false; changes.removeAll(); displayLink?.isPaused = true
            return
        }
        let batch = changes
        changes.removeAll(keepingCapacity: true); needsFrame = false
        let requestGeneration = generation
        statistics.requests += 1
        task = Task { [weak self, worker] in
            let frame = await worker.render(snapshot, changes: batch)
            guard let self else { return }
            self.task = nil
            guard requestGeneration == self.generation else { return }
            self.ready = frame
            self.statistics.lastMilliseconds = frame.milliseconds
            self.statistics.backgroundDurations.append(frame.milliseconds)
            if self.statistics.backgroundDurations.count > 300 { self.statistics.backgroundDurations.removeFirst() }
            self.statistics.maxMilliseconds = max(self.statistics.maxMilliseconds, frame.milliseconds)
            self.statistics.replayedSamples += frame.statistics.replayedSamples
            if frame.statistics.fullReplay { self.statistics.fullReplays += 1 }
        }
    }

    // Also used by offscreen rendering tests: wait for the actual async pipeline,
    // rather than substituting a separate synchronous renderer.
    func flush() async {
        while needsFrame || task != nil || ready != nil {
            tick()
            if let task { await task.value }
        }
    }
}
