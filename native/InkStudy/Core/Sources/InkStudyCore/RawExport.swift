import Foundation
import CryptoKit

public struct RawDrawingExport: Codable, Sendable {
    public let format: String
    public let exportedAt: Date
    public let metadata: DocumentMetadata
    public let pressureMapping: String
    public let pressureUnits: String
    public let pressureVerification: String
    public let sampleNotes: String
    public let pigmentMixing: String?
    public let visibleStrokeIDs: [UUID]
    public let redoStrokeIDs: [UUID]
    public let strokes: [InkStroke]
    public let events: [DrawingEvent]

    public init(document: StoredDocument, exportedAt: Date = Date()) throws {
        let state = try document.replay()
        format = "inkstudy-raw-v1"; self.exportedAt = exportedAt; metadata = document.metadata
        pressureMapping = document.metadata.background?.kind == "pigment" ? PigmentSurface.formula(for: document.metadata.background) : PressureMapping.formula
        pressureUnits = "UIKit force / maximumPossibleForce; not newtons. Raw values are never rescaled in the journal."
        pressureVerification = "unverified-prototype; finger input never counts as measured pressure"
        sampleNotes = "strokes contain latest actual samples after estimated-property corrections; events preserve original captures and every correction. No predicted samples are persisted. Positions are paper units and raw view points; timestamp is UITouch.timestamp in seconds since system startup. receivedAt and recordedAt are UTC epoch milliseconds."
        pigmentMixing = PaletteMixing.formula(for: document.metadata.background?.pigmentModel)
        visibleStrokeIDs = state.visibleStrokeIDs; redoStrokeIDs = state.redoStrokeIDs
        strokes = state.strokes; events = document.events
    }

    public func jsonData() throws -> Data { try DrawingJSON.encoder(pretty: true).encode(self) }

    public func csvData() -> Data {
        var lines = ["document_id,stroke_id,visible,sample_id,uptime_seconds,received_at_epoch_ms,x_paper,y_paper,x_view,y_view,input,phase,source,force_raw,maximum_possible_force,normalized_force,altitude_radians,azimuth_radians,estimation_index,estimated_properties,properties_expecting_updates,brush_color,brush_size,end_reason"]
        if pigmentMixing != nil { lines[0] += ",pigment_load_id" }
        let visible = Set(visibleStrokeIDs)
        func number(_ value: Double?) -> String { value.map(String.init(describing:)) ?? "" }
        for stroke in strokes {
            for sample in stroke.samples {
                var fields = [metadata.id.uuidString, stroke.id.uuidString, String(visible.contains(stroke.id)), sample.id.uuidString,
                              number(sample.uptime), String(Int64((sample.receivedAt.timeIntervalSince1970 * 1000).rounded())),
                              number(sample.x), number(sample.y), number(sample.viewX), number(sample.viewY), sample.input.rawValue,
                              sample.phase.rawValue, sample.source.rawValue, number(sample.force), number(sample.maximumPossibleForce),
                              number(sample.normalizedForce), number(sample.altitude), number(sample.azimuth),
                              sample.estimationIndex.map(String.init) ?? "", String(sample.estimatedProperties),
                              String(sample.propertiesExpectingUpdates), stroke.style.color.hex, number(stroke.style.size),
                              stroke.endReason?.rawValue ?? "unfinished"]
                if pigmentMixing != nil { fields.append(stroke.style.pigmentLoadID?.uuidString ?? "") }
                lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
