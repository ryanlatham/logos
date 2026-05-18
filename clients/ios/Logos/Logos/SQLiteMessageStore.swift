import Foundation
import SQLite3

final class SQLiteMessageStore {
    private var db: OpaquePointer?

    init(filename: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.resolvedFilename(filename: filename, environment: environment))
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            createSchema()
        }
    }

    static func resolvedFilename(filename: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let candidate = filename ?? environment["LOGOS_MESSAGE_STORE_FILENAME"] ?? "LogosMessages.sqlite3"
        let lastPathComponent = URL(fileURLWithPath: candidate).lastPathComponent
        return lastPathComponent.isEmpty ? "LogosMessages.sqlite3" : lastPathComponent
    }

    deinit {
        sqlite3_close(db)
    }

    func upsert(_ message: LogosMessage) {
        let sql = """
        INSERT OR REPLACE INTO messages (
            project_key, session_id, message_id, server_seq, role, content, timestamp, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(message.projectKey, at: 1, statement: statement)
        bind(message.sessionID, at: 2, statement: statement)
        bind(message.messageID, at: 3, statement: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(message.serverSeq))
        bind(message.role, at: 5, statement: statement)
        bind(message.content, at: 6, statement: statement)
        sqlite3_bind_double(statement, 7, message.timestamp)
        bind(message.status, at: 8, statement: statement)
        sqlite3_step(statement)
    }

    func loadMessages(projectKey: String, limit: Int = 100) -> [LogosMessage] {
        let sql = """
        SELECT project_key, session_id, message_id, server_seq, role, content, timestamp, status
        FROM messages
        WHERE project_key = ?
        ORDER BY server_seq ASC, timestamp ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(projectKey, at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [LogosMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(LogosMessage(
                projectKey: string(at: 0, statement: statement),
                sessionID: string(at: 1, statement: statement),
                messageID: string(at: 2, statement: statement),
                serverSeq: Int(sqlite3_column_int64(statement, 3)),
                role: string(at: 4, statement: statement),
                content: string(at: 5, statement: statement),
                timestamp: sqlite3_column_double(statement, 6),
                status: string(at: 7, statement: statement)
            ))
        }
        return results
    }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS messages (
            project_key TEXT NOT NULL,
            session_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp REAL NOT NULL,
            status TEXT NOT NULL,
            PRIMARY KEY (session_id, message_id)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_project_seq ON messages(project_key, server_seq);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func string(at index: Int32, statement: OpaquePointer?) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
