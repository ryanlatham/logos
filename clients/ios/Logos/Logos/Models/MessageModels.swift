import Foundation

struct LogosMessage: Identifiable, Hashable {
    var id: String { "\(sessionID):\(messageID)" }
    let projectKey: String
    let sessionID: String
    let messageID: String
    let serverSeq: Int
    let role: String
    let content: String
    let timestamp: TimeInterval
    var status: String
    var isFinal: Bool = true
    var hasFinalizedMetadata: Bool = false
    var metadataSource: String? = nil
    var progressKind: String? = nil
    var metadataRequestID: String? = nil
    var metadataTransient: Bool? = nil
    var metadataKind: String? = nil
    var metadataFinalStatus: String? = nil
    var metadataIsError: Bool = false
    var metadataJSON: String = "{}"

    var gatewayProgressKind: String? {
        Self.gatewayProgressKind(for: content)
    }

    var progressEventKind: String {
        progressKind ?? metadataSource ?? gatewayProgressKind ?? "progress"
    }

    var isGatewayStatusUpdate: Bool {
        progressEventKind == "gateway_status" || gatewayProgressKind != nil
    }

    var isProgressUpdate: Bool {
        guard role != "user" else { return false }
        if gatewayProgressKind != nil {
            return true
        }
        if hasFinalizedMetadata && isFinal {
            return false
        }
        return isFinal == false
            || progressKind != nil
            || metadataSource == "tool_progress"
            || metadataSource == "progress"
    }

    static func gatewayProgressKind(for content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed
            .lowercased()
            .replacingOccurrences(of: #"^\s*(?:⏳|⚠️|⚠|❌)\s*"#, with: "", options: .regularExpression)
        if lower.hasPrefix("still working...") || lower.hasPrefix("still working…") {
            return "gateway_status"
        }
        if lower.range(of: #"^retrying\s+in\s+.+\battempt\s+\d+/\d+\b"#, options: .regularExpression) != nil {
            return "gateway_status"
        }
        if lower.range(
            of: #"^non-retryable error\s+\(http\s+[^)]*\)(?:\s*[—-]\s*trying fallback(?:\.\.\.|…)?|:\s+.+)\s*$"#,
            options: .regularExpression
        ) != nil {
            return "gateway_status"
        }
        if lower.range(of: #"^no response from provider for\s+.*\baborting call\.?$"#, options: .regularExpression) != nil {
            return "gateway_status"
        }
        if lower.range(
            of: #"^(?:(?:preflight\s+compression|context\s+(?:compaction|compression))\s*[:\-–—]\s*(?:(?:started|starting|running|complete|completed|in progress)(?:\.\.\.|[.!…])?\s*$|(?:compact(?:ing)?|compress(?:ing)?)\s+context(?:\s*(?:\.\.\.|…)|\s+(?:before\s+continuing|to\s+continue|for\s+continuation|now|started|starting|running|complete|completed|in\s+progress)(?:\.\.\.|[.!…])?)\s*$|context(?:\.\.\.|[.!…])?\s*$)|(?:compact|compacting|compressing)\s+context(?:\s*(?:\.\.\.|…)|\s+(?:before\s+continuing|to\s+continue|for\s+continuation|now|started|starting|running|complete|completed|in\s+progress)(?:\.\.\.|[.!…])?|\s*)$)"#,
            options: .regularExpression
        ) != nil {
            return "gateway_status"
        }
        if lower.hasPrefix("gateway restarting") || lower.hasPrefix("gateway shutting down") {
            return "gateway_status"
        }
        return nil
    }

    static func from(dictionary: [String: Any]) -> LogosMessage? {
        guard
            let projectKey = dictionary["project_key"] as? String,
            let sessionID = dictionary["session_id"] as? String,
            let messageID = dictionary["message_id"] as? String,
            let role = dictionary["role"] as? String,
            let content = dictionary["content"] as? String
        else { return nil }
        let serverSeq = dictionary["server_seq"] as? Int ?? Int(dictionary["server_seq"] as? String ?? "") ?? 0
        let timestamp = dictionary["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        let metadata = dictionary["metadata"] as? [String: Any]
        let finalized = metadata?["finalized"] as? Bool
        let source = metadata?["source"] as? String
        let progressKind = metadata?["progress_kind"] as? String ?? metadata?["kind"] as? String
        let requestID = metadata?["request_id"] as? String
        let transient = Self.boolValue(metadata?["transient"])
        let kind = metadata?["kind"] as? String
        let finalStatus = metadata?["final_status"] as? String
        let isError = Self.boolValue(metadata?["error"]) ?? false
        return LogosMessage(
            projectKey: projectKey,
            sessionID: sessionID,
            messageID: messageID,
            serverSeq: serverSeq,
            role: role,
            content: content,
            timestamp: timestamp,
            status: dictionary["status"] as? String ?? "persisted",
            isFinal: finalized ?? true,
            hasFinalizedMetadata: finalized != nil,
            metadataSource: source,
            progressKind: progressKind,
            metadataRequestID: requestID,
            metadataTransient: transient,
            metadataKind: kind,
            metadataFinalStatus: finalStatus,
            metadataIsError: isError,
            metadataJSON: metadata.map(Self.metadataJSONString(from:)) ?? "{}"
        )
    }

    var metadataDictionary: [String: Any] {
        var metadata = Self.metadataDictionary(fromJSON: metadataJSON)
        if hasFinalizedMetadata {
            metadata["finalized"] = isFinal
        }
        if let metadataSource {
            metadata["source"] = metadataSource
        }
        if let progressKind {
            metadata["progress_kind"] = progressKind
        }
        if let metadataRequestID {
            metadata["request_id"] = metadataRequestID
        }
        if let metadataTransient {
            metadata["transient"] = metadataTransient
        }
        if let metadataKind {
            metadata["kind"] = metadataKind
        }
        if let metadataFinalStatus {
            metadata["final_status"] = metadataFinalStatus
        }
        if metadataIsError {
            metadata["error"] = true
        }
        return metadata
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func metadataDictionary(fromJSON json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return decoded
    }

    private static func metadataJSONString(from metadata: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    static func pending(projectKey: String, messageID: String = UUID().uuidString, content: String) -> LogosMessage {
        LogosMessage(
            projectKey: projectKey,
            sessionID: "pending",
            messageID: messageID,
            serverSeq: 0,
            role: "user",
            content: content,
            timestamp: Date().timeIntervalSince1970,
            status: "pending"
        )
    }

    static func localNotice(projectKey: String, requestID: String, sequence: Int, content: String, timestamp: TimeInterval = Date().timeIntervalSince1970) -> LogosMessage {
        LogosMessage(
            projectKey: projectKey,
            sessionID: "local:\(projectKey)",
            messageID: "local-stale-\(requestID)-\(sequence)",
            serverSeq: 0,
            role: "assistant",
            content: content,
            timestamp: timestamp,
            status: "local_notice",
            isFinal: true,
            hasFinalizedMetadata: true,
            metadataSource: "local_notice",
            progressKind: nil,
            metadataRequestID: requestID,
            metadataTransient: false
        )
    }
}

struct UndeliveredSpeechDraft: Identifiable, Equatable {
    var id: String { inputID }
    let inputID: String
    let projectKey: String
    let text: String
    let reason: String
}

enum PendingMessageReconciliation {
    static func shouldRemove(pending: LogosMessage, whenPersisted persisted: LogosMessage) -> Bool {
        guard pending.status == "pending",
              pending.role == persisted.role,
              pending.projectKey == persisted.projectKey else { return false }
        if pending.messageID == persisted.messageID { return true }
        return pending.content == persisted.content && persisted.timestamp >= pending.timestamp
    }
}

struct PendingMessageBuffer: Equatable {
    private var pendingByID: [String: LogosMessage] = [:]

    var isEmpty: Bool { pendingByID.isEmpty }

    mutating func add(_ message: LogosMessage, persisted: [LogosMessage] = []) {
        guard message.status == "pending" else { return }
        guard persisted.contains(where: { PendingMessageReconciliation.shouldRemove(pending: message, whenPersisted: $0) }) == false else {
            pendingByID.removeValue(forKey: message.messageID)
            return
        }
        pendingByID[message.messageID] = message
    }

    mutating func remove(messageID: String) {
        pendingByID.removeValue(forKey: messageID)
    }

    mutating func reconcile(with persisted: LogosMessage) {
        pendingByID = pendingByID.filter { _, pending in
            PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: persisted) == false
        }
    }

    mutating func reconcile(with persisted: [LogosMessage]) {
        for message in persisted {
            reconcile(with: message)
        }
    }

    func merged(with persisted: [LogosMessage], projectKey: String) -> [LogosMessage] {
        let pending = pendingByID.values
            .filter { $0.projectKey == projectKey }
            .filter { pending in
                persisted.contains(where: { PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: $0) }) == false
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.messageID < rhs.messageID }
                return lhs.timestamp < rhs.timestamp
            }
        return persisted + pending
    }
}
