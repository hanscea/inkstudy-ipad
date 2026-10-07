import Foundation
import InkStudyCore

func milliseconds(_ operation: () -> Void) -> Double {
    let start = ContinuousClock.now
    operation()
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
func percentile(_ samples: [Double], _ p: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

var reports: [[String: Any]] = []
for version in [PigmentSurface.version, SpectralMixing.version, PaletteMixing.version, StandardPalette.mixingVersion] {
    let metadata = DocumentMetadata(title: "Synthetic benchmark", background: .init(kind: "pigment", subject: "orange",
        pigmentModel: version))
    var state = try DrawingState(metadata: metadata)
    let transform = CanvasTransform(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850)
    let palette = PigmentSurface.palette(for: metadata.background)
    var id = UUID()
    for color in ["red", "yellow"] {
        id = UUID()
        let samples = (0..<960).map { i in
            TouchSample(uptime: Double(i) / 240, x: 600 + cos(Double(i) * 0.025) * 230,
                y: 425 + sin(Double(i) * 0.025) * 180, force: 1.4, maximumPossibleForce: 4,
                estimationIndex: Int64(i), propertiesExpectingUpdates: 1)
        }
        try state.apply(.init(documentID: metadata.id, sequence: state.lastSequence + 1,
            payload: .strokeBegan(strokeID: id, style: .init(color: palette.first { $0.id == color }!, size: 96,
                pigmentLoadID: PaletteMixing.supports(version) ? UUID() : nil),
                transform: transform, samples: samples)))
        try state.apply(.init(documentID: metadata.id, sequence: state.lastSequence + 1, payload: .strokeEnded(strokeID: id, reason: .lifted)))
    }
    var cache = IncrementalPigmentRenderer()
    cache.update(state)
    var full: [Double] = [], incremental: [Double] = [], checksum = 0
    var replayedSamples: [Int] = []
    for i in 0..<24 {
        var sample = state.strokes[1].samples[945 + i % 7]
        sample.source = .estimatedUpdate; sample.force = 0.7 + Double(i % 9) * 0.15
        let event = DrawingEvent(documentID: metadata.id, sequence: state.lastSequence + 1,
            payload: .samplesRevised(strokeID: id, samples: [sample]))
        try state.apply(event)
        full.append(milliseconds { checksum += Int(PigmentSurface(state: state).rgba[(i * 7919) % (600 * 425 * 4)]) })
        incremental.append(milliseconds { cache.update(state, changes: [event]) })
        replayedSamples.append(cache.statistics.replayedSamples)
    }
    precondition(cache.surface?.rgba == PigmentSurface(state: state).rgba, "Cached pixels differ from full replay")
    reports.append([
        "model": PigmentSurface.modelVersion(for: metadata.background), "input": "synthetic; not real Pencil input",
        "strokes": 2, "samples": 1920, "corrections": 24,
        "fullReplayMedianMs": percentile(full, 0.5), "fullReplayP95Ms": percentile(full, 0.95),
        "cachedMedianMs": percentile(incremental, 0.5), "cachedP95Ms": percentile(incremental, 0.95),
        "speedupMedian": percentile(full, 0.5) / max(0.000001, percentile(incremental, 0.5)),
        "maximumReplayedSamples": replayedSamples.max()!, "checkpoints": cache.statistics.checkpointCount,
        "exactPixelMatch": true, "checksum": checksum
    ])
}
let data = try JSONSerialization.data(withJSONObject: ["platform": ProcessInfo.processInfo.operatingSystemVersionString, "results": reports], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
