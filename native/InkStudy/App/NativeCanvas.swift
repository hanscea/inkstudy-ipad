import SwiftUI
import UIKit
import InkStudyCore

struct NativeCanvas: UIViewRepresentable {
    @ObservedObject var model: StudioModel
    func makeUIView(context: Context) -> DrawingCanvasView {
        let view = DrawingCanvasView(); view.model = model
        model.interruptCanvas = { [weak view] reason in view?.interrupt(reason) }
        model.didApplyEvent = { [weak view] event in view?.applyDrawingChange(event) }
        return view
    }
    func updateUIView(_ view: DrawingCanvasView, context: Context) { view.synchronize() }
    static func dismantleUIView(_ view: DrawingCanvasView, coordinator: ()) { view.stopRendering() }
}

@MainActor
final class DrawingCanvasView: UIView {
    weak var model: StudioModel?
    private var primaryTouch: UITouch?
    private var strokeID: UUID?
    private var inputTransform: CanvasTransform?
    private var seenCaptures = Set<CaptureKey>()
    private var estimates: [Int64: [EstimateTarget]] = [:]
    private var lastSize: CGSize = .zero
    private let paperLayer = CALayer()
    private let pigmentLayer = CALayer()
    private let outlineLayer = CALayer()
    private var pigmentDisplay: PigmentDisplayController?
    private var strokeLayers: [UUID: CALayer] = [:]
    private var chunks: [UUID: [CAShapeLayer]] = [:]
    private var representedDocumentID: UUID?
    private var renderedSequence = -1
    private let chunkSize = 256

    private struct CaptureKey: Hashable {
        let timestamp: Double
        let x: Double
        let y: Double
        let phase: SamplePhase
        let force: Double?
        let estimatedProperties: UInt64
        let propertiesExpectingUpdates: UInt64
    }
    private struct EstimateTarget {
        let strokeID: UUID
        let original: TouchSample
        let transform: CanvasTransform
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true; isOpaque = true; backgroundColor = .white
        contentMode = .redraw; clipsToBounds = true
        paperLayer.anchorPoint = .zero; paperLayer.position = .zero; layer.addSublayer(paperLayer)
        isAccessibilityElement = true; accessibilityIdentifier = "drawingCanvas"
        accessibilityLabel = "画布"; accessibilityTraits = [.allowsDirectInteraction]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func synchronize() {
        if representedDocumentID != model?.state?.metadata.id || renderedSequence != model?.state?.lastSequence { rebuildLayers() }
        if model?.canDraw == false && primaryTouch != nil { interrupt(.cancelled) }
        accessibilityValue = "\(model?.visibleCount ?? 0)笔"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            interrupt(.layoutChanged); estimates.removeAll(); lastSize = bounds.size
        }
        updatePaperTransform()
    }

    private func updatePaperTransform() {
        guard let metadata = model?.state?.metadata else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paperLayer.bounds = CGRect(x: 0, y: 0, width: metadata.paperWidth, height: metadata.paperHeight)
        paperLayer.setAffineTransform(CGAffineTransform(scaleX: bounds.width / metadata.paperWidth, y: bounds.height / metadata.paperHeight))
        CATransaction.commit()
    }

    private func rebuildLayers() {
        guard let state = model?.state else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paperLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokeLayers.removeAll(); chunks.removeAll(); estimates.removeAll()
        representedDocumentID = state.metadata.id
        if state.metadata.background != nil {
            let background = CALayer()
            background.frame = CGRect(x: 0, y: 0, width: state.metadata.paperWidth, height: state.metadata.paperHeight)
            background.contents = InkRenderer.background(state.metadata, includeOutline: false).cgImage
            paperLayer.addSublayer(background)
        }
        pigmentDisplay?.stop(); pigmentDisplay = nil
        if state.metadata.background?.kind == "pigment" {
            pigmentLayer.frame = CGRect(x: 0, y: 0, width: state.metadata.paperWidth, height: state.metadata.paperHeight)
            pigmentLayer.contents = nil
            paperLayer.addSublayer(pigmentLayer)
            pigmentDisplay = PigmentDisplayController(state: { [weak self] in self?.model?.state }, present: { [weak self] image in
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self?.pigmentLayer.contents = image
                CATransaction.commit()
            }, loadStatus: { [weak self] documentID, loadID, fraction in
                self?.model?.updatePigmentLoad(documentID: documentID, loadID: loadID, fraction: fraction)
            })
            pigmentDisplay?.reset()
        } else {
            for stroke in state.strokes {
                updateChunks(stroke: stroke, indices: Set(0..<max(1, (stroke.samples.count + chunkSize - 1) / chunkSize)))
                strokeLayers[stroke.id]?.isHidden = !state.visibleStrokeIDs.contains(stroke.id)
            }
        }
        if state.metadata.background?.kind == "outline" {
            let foreground = outlineLayer
            foreground.frame = CGRect(x: 0, y: 0, width: state.metadata.paperWidth, height: state.metadata.paperHeight)
            foreground.contents = InkRenderer.foreground(state.metadata).cgImage
            // A fixed z position keeps reference ink above every subsequently added color stroke.
            foreground.zPosition = 1
            paperLayer.addSublayer(foreground)
        }
        renderedSequence = state.lastSequence
        updatePaperTransform(); CATransaction.commit()
    }

    func applyDrawingChange(_ event: DrawingEvent) {
        guard representedDocumentID == event.documentID, renderedSequence == event.sequence - 1 else { rebuildLayers(); return }
        if let pigmentDisplay {
            pigmentDisplay.enqueue(event)
            renderedSequence = event.sequence
            accessibilityValue = "\(model?.visibleCount ?? 0)笔"
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch event.payload {
        case let .strokeBegan(id, _, _, _):
            if let stroke = model?.state?.stroke(id: id) {
                updateChunks(stroke: stroke, indices: Set(0..<max(1, (stroke.samples.count + chunkSize - 1) / chunkSize)))
            }
        case let .samplesAppended(id, samples):
            if let stroke = model?.state?.stroke(id: id) {
                let first = max(0, stroke.samples.count - samples.count - 1) / chunkSize
                let last = max(0, stroke.samples.count - 1) / chunkSize
                updateChunks(stroke: stroke, indices: Set(first...last))
            }
        case let .samplesRevised(id, samples):
            if let stroke = model?.state?.stroke(id: id) {
                var dirty = Set<Int>()
                for sample in samples {
                    if let index = model?.state?.sampleIndex(strokeID: id, sampleID: sample.id) {
                        dirty.insert(index / chunkSize)
                        if index + 1 < stroke.samples.count { dirty.insert((index + 1) / chunkSize) }
                    }
                }
                updateChunks(stroke: stroke, indices: dirty)
            }
        case .undone(let id): strokeLayers[id]?.isHidden = true
        case .redone(let id): strokeLayers[id]?.isHidden = false
        default: break
        }
        renderedSequence = event.sequence
        accessibilityValue = "\(model?.visibleCount ?? 0)笔"
        CATransaction.commit()
    }

    func stopRendering() { pigmentDisplay?.stop(); pigmentDisplay = nil }
    func flushPigmentRendering() async { await pigmentDisplay?.flush() }
    var pigmentStatistics: PigmentDisplayController.Statistics? { pigmentDisplay?.statistics }

    private func updateChunks(stroke: InkStroke, indices: Set<Int>) {
        if strokeLayers[stroke.id] == nil {
            let layer = CALayer(); layer.anchorPoint = .zero; layer.position = .zero; layer.bounds = paperLayer.bounds
            if outlineLayer.superlayer === paperLayer { paperLayer.insertSublayer(layer, below: outlineLayer) }
            else { paperLayer.addSublayer(layer) }
            strokeLayers[stroke.id] = layer; chunks[stroke.id] = []
        }
        for index in indices.sorted() {
            while chunks[stroke.id]!.count <= index {
                let shape = CAShapeLayer(); shape.fillColor = InkRenderer.color(stroke.style.color.hex).cgColor
                shape.contentsScale = window?.screen.scale ?? traitCollection.displayScale
                strokeLayers[stroke.id]?.addSublayer(shape); chunks[stroke.id]?.append(shape)
            }
            // Adjacent chunks share one endpoint so the join stays continuous.
            let start = max(0, index * chunkSize - 1), end = min(stroke.samples.count, (index + 1) * chunkSize)
            guard start < end else { continue }
            chunks[stroke.id]?[index].path = InkRenderer.path(samples: stroke.samples[start..<end], style: stroke.style, neutral: model?.state?.metadata.neutralRendering == true)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let model, model.canDraw, let metadata = model.state?.metadata else { return }
        let pencil = touches.first(where: { $0.type == .pencil })
        if primaryTouch?.type != .pencil, pencil != nil { interrupt(.cancelled) }
        guard primaryTouch == nil,
              let touch = pencil ?? (model.fingerInputEnabled ? touches.first(where: { $0.type == .direct }) : nil),
              bounds.contains(touch.preciseLocation(in: self)), bounds.width > 0, bounds.height > 0 else { return }
        let id = UUID()
        let mapping = CanvasTransform(viewWidth: bounds.width, viewHeight: bounds.height,
                                      paperWidth: metadata.paperWidth, paperHeight: metadata.paperHeight)
        inputTransform = mapping; strokeID = id; primaryTouch = touch; seenCaptures.removeAll(keepingCapacity: true)
        let samples = capture(touch, event: event, mapping: mapping, stroke: id)
        if !model.beginStroke(id: id, transform: mapping, samples: samples) { primaryTouch = nil; strokeID = nil }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primaryTouch, touches.contains(touch), let id = strokeID, let inputTransform else { return }
        model?.appendSamples(strokeID: id, samples: capture(touch, event: event, mapping: inputTransform, stroke: id))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event: event, reason: .lifted) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event: event, reason: .cancelled) }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, reason: StrokeEndReason) {
        guard let touch = primaryTouch, touches.contains(touch), let id = strokeID, let inputTransform else { return }
        model?.appendSamples(strokeID: id, samples: capture(touch, event: event, mapping: inputTransform, stroke: id))
        interrupt(reason)
    }

    func interrupt(_ reason: StrokeEndReason) {
        primaryTouch = nil; strokeID = nil; inputTransform = nil; seenCaptures.removeAll(keepingCapacity: true)
        if reason == .layoutChanged || reason == .navigation { estimates.removeAll() }
        model?.endActive(reason); setNeedsDisplay()
    }

    private func capture(_ touch: UITouch, event: UIEvent?, mapping: CanvasTransform, stroke: UUID) -> [TouchSample] {
        // Coalesced touches are read in this callback. Predicted touches never enter the journal.
        let coalesced = event?.coalescedTouches(for: touch)
        var touches = coalesced ?? [touch]
        if touches.last?.timestamp != touch.timestamp || touches.last?.phase != touch.phase { touches.append(touch) }
        var samples: [TouchSample] = []
        for item in touches {
            let sample = sample(from: item, mapping: mapping, source: coalesced == nil ? .direct : .coalesced)
            let key = CaptureKey(timestamp: sample.uptime, x: sample.viewX, y: sample.viewY, phase: sample.phase,
                                 force: sample.force, estimatedProperties: sample.estimatedProperties,
                                 propertiesExpectingUpdates: sample.propertiesExpectingUpdates)
            guard seenCaptures.insert(key).inserted else { continue }
            samples.append(sample)
            if let index = sample.estimationIndex, sample.propertiesExpectingUpdates != 0 {
                estimates[index, default: []].append(.init(strokeID: stroke, original: sample, transform: mapping))
            }
        }
        return samples
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touch.estimationUpdateIndex?.int64Value, let targets = estimates[index] else { continue }
            for target in targets {
                var updated = sample(from: touch, mapping: target.transform, source: .estimatedUpdate)
                updated.id = target.original.id; updated.uptime = target.original.uptime; updated.phase = target.original.phase
                model?.reviseSamples(strokeID: target.strokeID, samples: [updated])
            }
            if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimates.removeValue(forKey: index) }
        }
        setNeedsDisplay()
    }

    private func sample(from touch: UITouch, mapping: CanvasTransform, source: SampleSource) -> TouchSample {
        let point = touch.preciseLocation(in: self)
        let input: InputKind = touch.type == .pencil ? .pencil : touch.type == .direct ? .finger : .indirect
        let phase: SamplePhase
        switch touch.phase {
        case .began: phase = .began
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        case .stationary: phase = .stationary
        default: phase = .moved
        }
        return TouchSample(uptime: touch.timestamp, x: point.x * mapping.paperWidth / mapping.viewWidth,
                           y: point.y * mapping.paperHeight / mapping.viewHeight, viewX: point.x, viewY: point.y,
                           force: input == .pencil ? touch.force : nil,
                           maximumPossibleForce: input == .pencil ? touch.maximumPossibleForce : nil,
                           altitude: input == .pencil ? touch.altitudeAngle : nil,
                           azimuth: input == .pencil ? touch.azimuthAngle(in: self) : nil,
                           input: input, phase: phase, source: source, estimationIndex: touch.estimationUpdateIndex?.int64Value,
                           estimatedProperties: UInt64(touch.estimatedProperties.rawValue),
                           propertiesExpectingUpdates: UInt64(touch.estimatedPropertiesExpectingUpdates.rawValue))
    }
}
