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
        deleteExisting(sessionID: message.sessionID, messageID: message.messageID)
        let sql = """
        INSERT INTO messages (
            project_key, session_id, message_id, server_seq, role, content, timestamp, status, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        bind(metadataJSON(for: message), at: 9, statement: statement)
        sqlite3_step(statement)
    }

    func loadMessages(projectKey: String, limit: Int = 100) -> [LogosMessage] {
        let sql = """
        SELECT project_key, session_id, message_id, server_seq, role, content, timestamp, status, metadata_json
        FROM (
            SELECT project_key, session_id, message_id, server_seq, role, content, timestamp, status, metadata_json
            FROM messages
            WHERE project_key = ?
            ORDER BY server_seq DESC, timestamp DESC
            LIMIT ?
        )
        ORDER BY server_seq ASC, timestamp ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(projectKey, at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [LogosMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dictionary: [String: Any] = [
                "project_key": string(at: 0, statement: statement),
                "session_id": string(at: 1, statement: statement),
                "message_id": string(at: 2, statement: statement),
                "server_seq": Int(sqlite3_column_int64(statement, 3)),
                "role": string(at: 4, statement: statement),
                "content": string(at: 5, statement: statement),
                "timestamp": sqlite3_column_double(statement, 6),
                "status": string(at: 7, statement: statement),
                "metadata": metadataDictionary(from: string(at: 8, statement: statement))
            ]
            if let message = LogosMessage.from(dictionary: dictionary) {
                results.append(message)
            }
        }
        return results
    }

    func latestServerSeq(projectKey: String) -> Int {
        let sql = "SELECT MAX(server_seq) FROM messages WHERE project_key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(projectKey, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func message(projectKey: String, sessionID: String?, messageID: String) -> LogosMessage? {
        var sql = """
        SELECT project_key, session_id, message_id, server_seq, role, content, timestamp, status, metadata_json
        FROM messages
        WHERE project_key = ? AND message_id = ?
        """
        if sessionID != nil {
            sql += " AND session_id = ?"
        }
        sql += " ORDER BY server_seq DESC, timestamp DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(projectKey, at: 1, statement: statement)
        bind(messageID, at: 2, statement: statement)
        if let sessionID {
            bind(sessionID, at: 3, statement: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return messageFromCurrentRow(statement)
    }

    func latestFinalMessage(projectKey: String, sessionID: String, atOrAfterServerSeq serverSeq: Int) -> LogosMessage? {
        let sql = """
        SELECT project_key, session_id, message_id, server_seq, role, content, timestamp, status, metadata_json
        FROM messages
        WHERE project_key = ? AND session_id = ? AND server_seq >= ? AND role != 'user' AND status = 'persisted'
        ORDER BY server_seq DESC, timestamp DESC
        LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(projectKey, at: 1, statement: statement)
        bind(sessionID, at: 2, statement: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(serverSeq))
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let message = messageFromCurrentRow(statement) else { continue }
            if message.isFinal && message.hasFinalizedMetadata && message.isProgressUpdate == false {
                return message
            }
        }
        return nil
    }

    private func deleteExisting(sessionID: String, messageID: String) {
        let sql = "DELETE FROM messages WHERE session_id = ? AND message_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(sessionID, at: 1, statement: statement)
        bind(messageID, at: 2, statement: statement)
        sqlite3_step(statement)
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
            metadata_json TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (session_id, message_id)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_project_seq ON messages(project_key, server_seq);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'", nil, nil, nil)
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func string(at index: Int32, statement: OpaquePointer?) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func messageFromCurrentRow(_ statement: OpaquePointer?) -> LogosMessage? {
        let dictionary: [String: Any] = [
            "project_key": string(at: 0, statement: statement),
            "session_id": string(at: 1, statement: statement),
            "message_id": string(at: 2, statement: statement),
            "server_seq": Int(sqlite3_column_int64(statement, 3)),
            "role": string(at: 4, statement: statement),
            "content": string(at: 5, statement: statement),
            "timestamp": sqlite3_column_double(statement, 6),
            "status": string(at: 7, statement: statement),
            "metadata": metadataDictionary(from: string(at: 8, statement: statement))
        ]
        return LogosMessage.from(dictionary: dictionary)
    }

    private func metadataJSON(for message: LogosMessage) -> String {
        let metadata = message.metadataDictionary
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private func metadataDictionary(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return decoded
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
