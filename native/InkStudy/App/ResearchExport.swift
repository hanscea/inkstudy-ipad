import Foundation
import InkStudyCore

@MainActor
enum ResearchExport {
    private struct Manifest: Encodable {
        let format = "inkstudy-research-export-v1"
        let sessionID: UUID
        let exportedAt: Date
        let protocolVersion: String
        let hintProtocolVersion: String?
        let pressureTargetVersion = ResearchProtocol.pressureTargetVersion
        let rendererVersion = "native-renderer-0911V4"
        let pigmentModelsByDrawing: [String: String]
        let endReason: ResearchEndReason?
        let missingDrawingIDs: [UUID]
        let sha256: [String: String]
    }

    static func create(record: ResearchRecord, directory: URL) async throws -> URL {
        let state = try record.replay()
        let folder = directory.appendingPathComponent("Exports/Study-\(record.configuration.participantCode)-\(record.configuration.visit.rawValue)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try JournalStore(url: directory.appendingPathComponent("drawings.sqlite"))
        let available = Set(try await store.list().map(\.id))
        var missing: [UUID] = [], entries: [StoredZIP.Entry] = [], hashes: [String: String] = [:]
        var pigmentModels: [String: String] = [:]
        func add(_ name: String, _ data: Data) throws {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            entries.append(.init(name: name, url: url)); hashes[name] = RawDrawingExport.sha256(data)
        }
        try add("study.json", DrawingJSON.encoder(pretty: true).encode(record))
        var trials = [["task_id", "phase", "form", "trial_id", "drawing_id", "finished", "valid", "selected_first_valid", "stroke_id", "reason", "metrics_json"]]
        var responses = [["task_id", "question_id", "response_id", "response", "correct", "at"]]
        var summary = [["task_id", "kind", "phase", "began_at", "finished_at", "attempts", "drafts_json"]]
        for activity in state.activities {
            summary.append([activity.task.id, activity.task.kind.rawValue, activity.task.phase.rawValue,
                date(activity.beganAt), date(activity.finishedAt), String(activity.attemptCount), json(activity.drafts)])
            for response in activity.responses {
                responses.append([activity.task.id, response.questionID, response.id.uuidString, response.value,
                    response.correct.map(String.init) ?? "", date(response.at)])
            }
            for reference in activity.drawings {
                trials.append([activity.task.id, activity.task.phase.rawValue, activity.task.form, reference.trialID, reference.id.uuidString,
                    String(reference.finished), reference.valid.map(String.init) ?? "", String(activity.selectedTrials[reference.trialID] == reference.id),
                    reference.selectedStrokeID?.uuidString ?? "", reference.reason ?? "", json(reference.metrics)])
                guard available.contains(reference.id) else { missing.append(reference.id); continue }
                var document = try await store.load(id: reference.id)
                if document.metadata.background?.kind == "pigment" {
                    pigmentModels[reference.id.uuidString] = PigmentSurface.modelVersion(for: document.metadata.background)
                }
                let drawing = try document.replay()
                if let id = drawing.activeStrokeID {
                    let recovery = DrawingEvent(documentID: reference.id, sequence: drawing.lastSequence + 1, payload: .strokeEnded(strokeID: id, reason: .recovered))
                    try await store.append([recovery]); document = try await store.load(id: reference.id)
                }
                let files = try await ExportService.create(document: document, root: folder.appendingPathComponent("rendered"))
                for file in files.urls { try add("drawings/\(reference.id.uuidString)/\(file.lastPathComponent)", Data(contentsOf: file)) }
                try FileManager.default.removeItem(at: files.directory)
            }
        }
        try add("summary.csv", csv(summary)); try add("trials.csv", csv(trials)); try add("responses.csv", csv(responses))
        var help = [["task_id", "help_id", "kind", "operator_code", "began_at", "ended_at", "duration_seconds"]]
        for item in state.helps {
            let duration = item.durationSeconds.map { String($0) } ?? ""
            help.append([item.taskID, item.id.uuidString, item.kind.rawValue, item.operatorCode,
                date(item.beganAt), date(item.endedAt), duration])
        }
        try add("operator-help.csv", csv(help))
        var narration = [["task_id", "request_id", "kind", "text", "feedback_id", "voice_id", "requested_at"]]
        for item in state.activities.flatMap(\.narrations) {
            narration.append([item.taskID, item.id.uuidString, item.kind.rawValue, item.text,
                item.feedbackID?.uuidString ?? "", item.voiceID, date(item.requestedAt)])
        }
        try add("narration.csv", csv(narration))
        if record.configuration.hintProtocolVersion != nil {
            var hints = [["task_id", "feedback_id", "at", "strategy", "text", "source", "model", "request_id", "latency_ms", "fallback_reason", "drawing_id", "drawing_sequence", "evidence_json"]]
            for activity in state.activities {
                for support in activity.feedback {
                    guard let detail = support.multimodal else { continue }
                    hints.append([activity.task.id, support.id.uuidString, date(support.at), detail.strategy.rawValue, support.text ?? "", detail.source,
                        detail.model ?? "", detail.requestID?.uuidString ?? "", detail.latencyMilliseconds.map(String.init) ?? "", detail.fallbackReason ?? "",
                        detail.evidence.drawingID.uuidString, String(detail.evidence.drawingSequence), json(detail.evidence)])
                }
            }
            var delivery = [["task_id", "feedback_id", "event", "at"]]
            for event in record.events {
                if case let .hintDelivered(id, kind) = event.action { delivery.append([event.taskID, id.uuidString, kind.rawValue, date(event.at)]) }
            }
            try add("hints.csv", csv(hints)); try add("hint-delivery.csv", csv(delivery))
        }
        let manifest = Manifest(sessionID: record.id, exportedAt: Date(), protocolVersion: record.configuration.protocolVersion,
            hintProtocolVersion: record.configuration.hintProtocolVersion,
            pigmentModelsByDrawing: pigmentModels, endReason: state.endReason, missingDrawingIDs: missing, sha256: hashes)
        try add("manifest.json", DrawingJSON.encoder(pretty: true).encode(manifest))
        let archive = folder.appendingPathExtension("zip")
        let archiveEntries = entries
        try await Task.detached(priority: .userInitiated) { try StoredZIP.write(archiveEntries, to: archive) }.value
        return archive
    }

    private static func date(_ value: Date?) -> String { value.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
    private static func json<T: Encodable>(_ value: T) -> String { (try? DrawingJSON.encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    private static func csv(_ rows: [[String]]) -> Data {
        Data((rows.map { row in row.map { value in
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
