import Foundation

public actor ResearchStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func list() throws -> [ResearchRecord] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let record = try DrawingJSON.decoder().decode(ResearchRecord.self, from: Data(contentsOf: url))
            _ = try record.replay(); return record
        }.sorted { $0.configuration.createdAt > $1.configuration.createdAt }
    }
    public func load(_ id: UUID) throws -> ResearchRecord {
        let record = try DrawingJSON.decoder().decode(ResearchRecord.self, from: Data(contentsOf: path(id)))
        guard record.id == id else { throw DrawingError.invalidEvent("研究记录 ID 不匹配。") }
        _ = try record.replay(); return record
    }
    public func create(_ configuration: ResearchConfiguration) throws -> ResearchRecord {
        guard !FileManager.default.fileExists(atPath: path(configuration.id).path) else { throw DrawingError.persistence("研究记录已存在。") }
        try ResearchProtocol.validate(configuration, prior: list())
        let task = ResearchProtocol.tasks(for: configuration).first!
        let record = ResearchRecord(configuration: configuration, events: [.init(sequence: 1, taskID: task.id, at: configuration.createdAt, action: .entered)])
        try persist(record); return record
    }
    public func append(id: UUID, eventID: UUID = UUID(), taskID: String, action: ResearchAction, at: Date = Date()) throws -> ResearchRecord {
        var record = try load(id)
        if let existing = record.events.first(where: { $0.id == eventID }) {
            guard existing.taskID == taskID && existing.action == action else { throw DrawingError.invalidEvent("研究事件 ID 冲突。") }
            return record
        }
        let event = ResearchEvent(id: eventID, sequence: record.events.count + 1, taskID: taskID, at: at, action: action)
        var state = try record.replay(); try state.apply(event)
        record.events.append(event); try persist(record); return record
    }
    public func requestFeedback(id: UUID, taskID: String, trigger: String = "help_request", at: Date = Date()) throws -> ResearchRecord {
        let state = try load(id).replay()
        guard let current = state.current, current.task.id == taskID else { throw DrawingError.invalidEvent("提示任务已变更。") }
        var evidence = state.learningEvidence()
        if trigger == "inactivity" { evidence.inactivitySeconds = 45 }
        let decision = ResearchFeedback.decide(group: state.configuration.group, phase: current.task.phase, evidence: evidence,
                                               history: current.feedback, trigger: trigger, at: at)
        return try append(id: id, taskID: taskID, action: .feedback(decision), at: at)
    }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func persist(_ record: ResearchRecord) throws {
        _ = try record.replay()
        let url = path(record.id)
        try DrawingJSON.encoder().encode(record).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
