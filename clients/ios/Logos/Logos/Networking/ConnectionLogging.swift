import Foundation
import OSLog

enum LogosConnectionLog {
    static let logger = Logger(subsystem: "dev.logos", category: "connection")

    static func urlDescription(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    static func urlDescription(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "<invalid-url>" }
        return urlDescription(url)
    }

    static func closeReasonDescription(_ reason: Data?) -> String {
        guard let reason else { return "<none>" }
        if let text = String(data: reason, encoding: .utf8), text.isEmpty == false {
            return text
        }
        return "<\(reason.count) bytes>"
    }

    static func errorDescription(_ error: Error, url: URL? = nil) -> String {
        let nsError = error as NSError
        var parts = [
            error.localizedDescription,
            "[\(nsError.domain) \(nsError.code)]"
        ]
        if let url {
            parts.append("url=\(urlDescription(url))")
        }
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("failingURL=\(urlDescription(failingURL))")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=[\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }

    static func frameSummary(_ frame: [String: Any]) -> String {
        let type = stringValue(frame["type"])
        let requestID = stringValue(frame["request_id"])
        let projectKey = stringValue(frame["project_key"])
        let payloadKeys = dictionaryKeysDescription(frame["payload"])
        return "type=\(type) request_id=\(requestID) project_key=\(projectKey) payload_keys=\(payloadKeys)"
    }

    static func inboundFrameSummary(_ root: [String: Any]) -> String {
        let type = stringValue(root["type"])
        let requestID = stringValue(root["request_id"])
        let projectKey = stringValue(root["project_key"])
        let payloadKeys = dictionaryKeysDescription(root["payload"])
        return "type=\(type) request_id=\(requestID) project_key=\(projectKey) payload_keys=\(payloadKeys)"
    }

    static func messageSummary(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let string):
            return "string bytes=\(string.utf8.count)"
        case .data(let data):
            return "data bytes=\(data.count)"
        @unknown default:
            return "unknown"
        }
    }

    static func taskIDDescription(_ task: (any WebSocketTasking)?) -> String {
        guard let task else { return "<none>" }
        return String(describing: ObjectIdentifier(task))
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "<none>" }
        if let text = value as? String {
            return text.isEmpty ? "<empty>" : text
        }
        return String(describing: value)
    }

    private static func dictionaryKeysDescription(_ value: Any?) -> String {
        guard let dictionary = value as? [String: Any] else { return "[]" }
        return "[" + dictionary.keys.sorted().joined(separator: ",") + "]"
    }
}
