import Foundation
import SQLite3

public struct StoredDocument: Sendable {
    public let metadata: DocumentMetadata
    public let events: [DrawingEvent]
    public init(metadata: DocumentMetadata, events: [DrawingEvent]) { self.metadata = metadata; self.events = events }
    public func replay() throws -> DrawingState { try DrawingState(metadata: metadata, events: events) }
}

public protocol DrawingRepository: Sendable {
    func create(_ metadata: DocumentMetadata) async throws
    func list() async throws -> [DocumentMetadata]
    func load(id: UUID) async throws -> StoredDocument
    func append(_ events: [DrawingEvent]) async throws
}

public actor JournalStore: DrawingRepository {
    private let connection: DatabaseConnection

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try DatabaseConnection(url: url)
    }

    public func create(_ metadata: DocumentMetadata) throws {
        try connection.run("INSERT INTO documents(id, created_at, metadata) VALUES (?, ?, ?)", [
            metadata.id.uuidString, String(metadata.createdAt.timeIntervalSince1970),
            String(decoding: DrawingJSON.encoder().encode(metadata), as: UTF8.self)
        ])
    }

    public func list() throws -> [DocumentMetadata] {
        try connection.rows("SELECT metadata FROM documents ORDER BY created_at DESC, id DESC").map {
            try DrawingJSON.decoder().decode(DocumentMetadata.self, from: Data($0[0].utf8))
        }
    }

    public func load(id: UUID) throws -> StoredDocument {
        guard let row = try connection.rows("SELECT metadata FROM documents WHERE id = ?", [id.uuidString]).first else {
            throw DrawingError.persistence("drawing not found")
        }
        let metadata = try DrawingJSON.decoder().decode(DocumentMetadata.self, from: Data(row[0].utf8))
        let events = try connection.rows("SELECT payload FROM events WHERE document_id = ? ORDER BY sequence", [id.uuidString]).map {
            try DrawingJSON.decoder().decode(DrawingEvent.self, from: Data($0[0].utf8))
        }
        let document = StoredDocument(metadata: metadata, events: events)
        _ = try document.replay()
        return document
    }

    public func append(_ events: [DrawingEvent]) throws {
        guard let first = events.first else { return }
        guard events.allSatisfy({ $0.documentID == first.documentID }) else { throw DrawingError.persistence("mixed document batch") }
        try connection.run("BEGIN IMMEDIATE")
        do {
            var last = Int(try connection.rows("SELECT COALESCE(MAX(sequence), 0) FROM events WHERE document_id = ?", [first.documentID.uuidString])[0][0]) ?? 0
            for event in events {
                let json = String(decoding: try DrawingJSON.encoder().encode(event), as: UTF8.self)
                let previous = try connection.rows("SELECT payload FROM events WHERE id = ?", [event.id.uuidString])
                if let row = previous.first {
                    guard row[0] == json else { throw DrawingError.persistence("event ID reused with different data") }
                    continue
                }
                guard event.sequence == last + 1 else { throw DrawingError.persistence("event sequence gap") }
                try connection.run("INSERT INTO events(id, document_id, sequence, payload) VALUES (?, ?, ?, ?)",
                                   [event.id.uuidString, event.documentID.uuidString, String(event.sequence), json])
                last = event.sequence
            }
            try connection.run("COMMIT")
        } catch {
            try? connection.run("ROLLBACK")
            throw error
        }
    }

    public func integrityCheck() throws -> String { try connection.rows("PRAGMA integrity_check")[0][0] }
}

// This connection never escapes the store actor; SQLite also uses its full mutex mode.
private final class DatabaseConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(handle); handle = nil; throw DrawingError.persistence(message)
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            let version = Int(try rows("PRAGMA user_version")[0][0]) ?? -1
            guard version == 0 || version == 1 else { throw DrawingError.persistence("unsupported database version \(version)") }
            try run("PRAGMA journal_mode = WAL")
            try run("PRAGMA synchronous = FULL")
            try run("PRAGMA foreign_keys = ON")
            try run("CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, created_at REAL NOT NULL, metadata TEXT NOT NULL)")
            try run("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id), sequence INTEGER NOT NULL, payload TEXT NOT NULL, UNIQUE(document_id, sequence))")
            try run("PRAGMA user_version = 1")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }

    func run(_ sql: String, _ values: [String] = []) throws { _ = try rows(sql, values) }

    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    private func failure() -> DrawingError { .persistence(String(cString: sqlite3_errmsg(handle))) }
}
