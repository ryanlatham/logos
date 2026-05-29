import Foundation

// WS3/WS1: slash-command catalog + completion requests and their inbound handlers,
// split out of the LogosClient monolith (P5). Same type/state via an extension.
extension LogosClient {
    @discardableResult
    func requestCommandCatalog(includeUnavailable: Bool = true) -> Bool {
        guard connectionState == .connected, logosConnection.hasOpenSocket else { return false }
        let requestID = UUID().uuidString
        pendingCommandCatalogRequestID = requestID
        return sendFrame([
            "type": "commands_get",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": ["include_unavailable": includeUnavailable]
        ])
    }

    @discardableResult
    func requestSlashCommandCompletion(text: String) -> Bool {
        guard connectionState == .connected, logosConnection.hasOpenSocket else { return false }
        guard text.hasPrefix("/"), text.count <= 500, text.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let requestID = UUID().uuidString
        pendingCommandCompletionRequestID = requestID
        return sendFrame([
            "type": "commands_complete",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "text": text,
                "catalog_version": slashCommandCatalog.catalogVersion
            ]
        ])
    }

    func handleCommandsList(_ root: [String: Any]) {
        let requestID = root["request_id"] as? String
        if let pendingCommandCatalogRequestID, requestID != pendingCommandCatalogRequestID {
            LogosConnectionLog.logger.info("Ignoring stale command catalog request_id=\(requestID ?? "<none>", privacy: .public)")
            return
        }
        guard let payload = root["payload"] as? [String: Any],
              let catalog = SlashCommandCatalog.from(dictionary: payload)
        else { return }
        slashCommandCatalog = catalog
        pendingCommandCatalogRequestID = nil
    }

    func handleCommandsCompleteResult(_ root: [String: Any]) {
        let requestID = root["request_id"] as? String
        if let pendingCommandCompletionRequestID, requestID != pendingCommandCompletionRequestID {
            LogosConnectionLog.logger.info("Ignoring stale command completion request_id=\(requestID ?? "<none>", privacy: .public)")
            return
        }
        guard let payload = root["payload"] as? [String: Any],
              let completion = SlashCommandCompletionResult.from(dictionary: payload)
        else { return }
        slashCommandCompletion = completion
        pendingCommandCompletionRequestID = nil
    }
}
