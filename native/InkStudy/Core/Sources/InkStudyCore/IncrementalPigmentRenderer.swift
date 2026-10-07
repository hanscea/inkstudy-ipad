import Foundation

/// Presentation cache only. Corrections are replayed from a bounded checkpoint;
/// the caller's original event journal is never changed or decimated.
public struct IncrementalPigmentRenderer: Sendable {
    public struct Statistics: Sendable {
        public var replayedSamples = 0
        public var checkpointCount = 0
        public var fullReplay = false
    }

    private struct Position: Comparable, Sendable {
        let stroke: Int
        let samples: Int
        static func < (a: Self, b: Self) -> Bool {
            a.stroke == b.stroke ? a.samples < b.samples : a.stroke < b.stroke
        }
    }
    private struct Checkpoint: Sendable {
        let position: Position
        let surface: PigmentSurface
    }

    public private(set) var surface: PigmentSurface?
    public private(set) var statistics = Statistics()
    public private(set) var lastSequence = -1
    private var previous: DrawingState?
    private var checkpoints: [Checkpoint] = []
    private let interval = 32
    private let capacity = 8

    public init() {}

    @discardableResult
    public mutating func update(_ state: DrawingState, changes: [DrawingEvent] = []) -> Bool {
        statistics = Statistics()
        let strokes = state.visibleStrokes
        var dirty: Position?
        let contiguous = previous?.metadata.id == state.metadata.id
            && (state.lastSequence == lastSequence || changes.first?.sequence == lastSequence + 1)
            && (state.lastSequence == lastSequence || changes.last?.sequence == state.lastSequence)
        if !contiguous || surface == nil {
            surface = PigmentSurface(metadata: state.metadata)
            checkpoints.removeAll(keepingCapacity: true)
            dirty = .init(stroke: 0, samples: 0)
            statistics.fullReplay = true
        } else if let previous {
            let oldIDs = previous.visibleStrokeIDs
            let common = zip(oldIDs, state.visibleStrokeIDs).prefix { $0 == $1 }.count
            if common != oldIDs.count || common != strokes.count {
                dirty = .init(stroke: common, samples: 0)
            }
            let indices = Dictionary(uniqueKeysWithValues: state.visibleStrokeIDs.enumerated().map { ($1, $0) })
            func include(_ candidate: Position) {
                if dirty == nil || candidate < dirty! { dirty = candidate }
            }
            for event in changes {
                switch event.payload {
                case let .strokeBegan(id, _, _, _):
                    if let index = indices[id] { include(.init(stroke: index, samples: 0)) }
                case let .samplesAppended(id, _):
                    if let index = indices[id] {
                        include(.init(stroke: index, samples: previous.stroke(id: id)?.samples.count ?? 0))
                    }
                case let .samplesRevised(id, revised):
                    guard let index = indices[id] else { continue }
                    let oldStroke = previous.stroke(id: id)
                    for sample in revised {
                        guard let n = state.sampleIndex(strokeID: id, sampleID: sample.id) else { continue }
                        let old = oldStroke.flatMap { n < $0.samples.count ? $0.samples[n] : nil }
                        if old?.x != sample.x || old?.y != sample.y || old?.normalizedForce != sample.normalizedForce {
                            include(.init(stroke: index, samples: n))
                        }
                    }
                default: break
                }
            }
        }

        defer {
            previous = state
            lastSequence = state.lastSequence
            statistics.checkpointCount = checkpoints.count
        }
        guard let dirty else {
            if let last = strokes.last, last.endReason != nil, let surface {
                save(surface, at: .init(stroke: strokes.count - 1, samples: last.samples.count))
            }
            return false
        }

        // The existing full surface is itself the best checkpoint for pure appends.
        var from = Position(stroke: 0, samples: 0)
        var reuseCurrent = false
        if let previous, !statistics.fullReplay, surface != nil,
           let last = previous.visibleStrokes.last {
            let end = Position(stroke: previous.visibleStrokeIDs.count - 1, samples: last.samples.count)
            if end <= dirty { from = end; reuseCurrent = true }
        }
        checkpoints.removeAll { $0.position > dirty }
        if reuseCurrent {
            // Keep the already-rendered surface without consuming a cache slot.
        } else if let checkpoint = checkpoints.last {
            surface = checkpoint.surface
            from = checkpoint.position
        } else {
            surface = PigmentSurface(metadata: state.metadata)
            statistics.fullReplay = true
        }

        if from.stroke < strokes.count {
            for index in from.stroke..<strokes.count {
                let stroke = strokes[index]
                var offset = index == from.stroke ? from.samples : 0
                if offset == 0 { surface?.begin(style: stroke.style, samples: []) }
                while offset < stroke.samples.count {
                    let end = min(stroke.samples.count, (offset / interval + 1) * interval)
                    surface?.append(Array(stroke.samples[offset..<end]))
                    statistics.replayedSamples += end - offset
                    offset = end
                    if offset % interval == 0, let surface {
                        save(surface, at: .init(stroke: index, samples: offset))
                    }
                }
                if stroke.endReason != nil, let surface { save(surface, at: .init(stroke: index, samples: offset)) }
            }
        }
        return true
    }

    private mutating func save(_ surface: PigmentSurface, at position: Position) {
        if checkpoints.last?.position == position { checkpoints.removeLast() }
        checkpoints.append(.init(position: position, surface: surface))
        if checkpoints.count > capacity { checkpoints.removeFirst(checkpoints.count - capacity) }
    }
}
