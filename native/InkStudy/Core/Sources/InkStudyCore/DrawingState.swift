import Foundation

public struct DrawingState: Sendable {
    public let metadata: DocumentMetadata
    public private(set) var strokes: [InkStroke] = []
    public private(set) var visibleStrokeIDs: [UUID] = []
    public private(set) var redoStrokeIDs: [UUID] = []
    public private(set) var activeStrokeID: UUID?
    public private(set) var brush = BrushStyle()
    public private(set) var fingerInputEnabled = false
    public private(set) var lastSequence = 0
    private var strokeIndices: [UUID: Int] = [:]
    private var sampleIndices: [UUID: [UUID: Int]] = [:]
    private var pigmentLoadColors: [UUID: InkColor] = [:]

    public init(metadata: DocumentMetadata, events: [DrawingEvent] = []) throws {
        self.metadata = metadata
        for event in events { try apply(event) }
    }

    public var visibleStrokes: [InkStroke] { visibleStrokeIDs.compactMap { stroke(id: $0) } }
    public var canUndo: Bool { activeStrokeID == nil && !visibleStrokeIDs.isEmpty }
    public var canRedo: Bool { activeStrokeID == nil && !redoStrokeIDs.isEmpty }
    public var sampleCount: Int { strokes.reduce(0) { $0 + $1.samples.count } }
    public func stroke(id: UUID) -> InkStroke? { strokeIndices[id].map { strokes[$0] } }
    public func sampleIndex(strokeID: UUID, sampleID: UUID) -> Int? { sampleIndices[strokeID]?[sampleID] }

    public mutating func apply(_ event: DrawingEvent) throws {
        guard event.documentID == metadata.id, event.sequence == lastSequence + 1 else {
            throw DrawingError.invalidEvent("document or sequence mismatch at \(event.sequence)")
        }
        switch event.payload {
        case let .strokeBegan(id, style, transform, samples):
            guard activeStrokeID == nil, strokeIndices[id] == nil, !samples.isEmpty,
                  transform.viewWidth > 0, transform.viewHeight > 0,
                  transform.paperWidth == metadata.paperWidth, transform.paperHeight == metadata.paperHeight,
                  BrushStyle.sizeRange.contains(style.size), validColor(style.color) else {
                throw DrawingError.invalidEvent("invalid stroke start")
            }
            try validate(samples)
            guard Set(samples.map(\.id)).count == samples.count else { throw DrawingError.invalidEvent("duplicate samples") }
            try validateLoad(style)
            strokeIndices[id] = strokes.count
            sampleIndices[id] = Dictionary(uniqueKeysWithValues: samples.enumerated().map { ($1.id, $0) })
            strokes.append(.init(id: id, style: style, transform: transform, samples: samples, endReason: nil))
            visibleStrokeIDs.append(id); redoStrokeIDs.removeAll(); activeStrokeID = id
        case let .samplesAppended(id, samples):
            guard activeStrokeID == id, let index = strokeIndices[id], !samples.isEmpty else {
                throw DrawingError.invalidEvent("append without active stroke")
            }
            try validate(samples)
            guard Set(samples.map(\.id)).count == samples.count,
                  samples.allSatisfy({ sampleIndices[id]?[$0.id] == nil }) else { throw DrawingError.invalidEvent("duplicate samples") }
            let offset = strokes[index].samples.count
            for (n, sample) in samples.enumerated() { sampleIndices[id]?[sample.id] = offset + n }
            strokes[index].samples.append(contentsOf: samples)
        case let .samplesRevised(id, samples):
            guard let index = strokeIndices[id], !samples.isEmpty else { throw DrawingError.invalidEvent("revision without stroke") }
            try validate(samples)
            for sample in samples {
                guard sample.source == .estimatedUpdate, let n = sampleIndices[id]?[sample.id],
                      sample.estimationIndex == strokes[index].samples[n].estimationIndex,
                      sample.estimationIndex != nil, sample.uptime == strokes[index].samples[n].uptime else {
                    throw DrawingError.invalidEvent("revision target mismatch")
                }
            }
            for sample in samples { strokes[index].samples[sampleIndices[id]![sample.id]!] = sample }
        case let .strokeEnded(id, reason):
            guard activeStrokeID == id, let index = strokeIndices[id] else { throw DrawingError.invalidEvent("end without active stroke") }
            strokes[index].endReason = reason; activeStrokeID = nil
        case .undone(let id):
            guard canUndo, visibleStrokeIDs.last == id else { throw DrawingError.invalidEvent("undo target mismatch") }
            visibleStrokeIDs.removeLast(); redoStrokeIDs.append(id)
        case .redone(let id):
            guard canRedo, redoStrokeIDs.last == id else { throw DrawingError.invalidEvent("redo target mismatch") }
            redoStrokeIDs.removeLast(); visibleStrokeIDs.append(id)
        case .brushChanged(let style):
            guard activeStrokeID == nil, BrushStyle.sizeRange.contains(style.size), validColor(style.color) else {
                throw DrawingError.invalidEvent("invalid brush change")
            }
            try validateLoad(style)
            brush = style
        case .fingerInputChanged(let enabled):
            guard activeStrokeID == nil else { throw DrawingError.invalidEvent("input change during stroke") }
            fingerInputEnabled = enabled
        }
        lastSequence = event.sequence
    }

    private func validColor(_ color: InkColor) -> Bool {
        if metadata.background?.kind == "pigment" {
            return PigmentSurface.palette(for: metadata.background).contains(color)
        }
        return InkColor.palette.contains(color) || InkColor.legacyPalette.contains(color) || (metadata.context != nil && color == .researchLine)
    }

    private mutating func validateLoad(_ style: BrushStyle) throws {
        guard let id = style.pigmentLoadID else { return }
        guard PaletteMixing.supports(metadata.background?.pigmentModel),
              pigmentLoadColors[id] == nil || pigmentLoadColors[id] == style.color else {
            throw DrawingError.invalidEvent("pigment load identity or model mismatch")
        }
        pigmentLoadColors[id] = style.color
    }

    private func validate(_ samples: [TouchSample]) throws {
        for sample in samples {
            let required = [sample.uptime, sample.x, sample.y, sample.viewX, sample.viewY, sample.receivedAt.timeIntervalSince1970]
            let optional = [sample.force, sample.maximumPossibleForce, sample.altitude, sample.azimuth].compactMap { $0 }
            guard required.allSatisfy(\.isFinite), optional.allSatisfy(\.isFinite) else {
                throw DrawingError.invalidEvent("non-finite sample")
            }
        }
    }
}
