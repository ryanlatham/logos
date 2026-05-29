import Foundation

struct LogosProject: Identifiable, Hashable, Decodable {
    var id: String { projectKey }
    let projectKey: String
    var title: String
    var currentSessionID: String?
    var lastPreview: String?

    enum CodingKeys: String, CodingKey {
        case projectKey = "project_key"
        case title
        case currentSessionID = "current_session_id"
        case lastPreview = "last_preview"
    }

    init(projectKey: String, title: String, currentSessionID: String? = nil, lastPreview: String? = nil) {
        self.projectKey = projectKey
        self.title = title
        self.currentSessionID = currentSessionID
        self.lastPreview = lastPreview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // project_key is required; a missing/non-string value throws -> the frame is dropped.
        let key = try container.decode(String.self, forKey: .projectKey)
        projectKey = key
        // `try?` mirrors the prior `as? String ?? projectKey` coercion: a missing or non-string
        // title falls back to the key; optional fields tolerate missing/wrong types as nil.
        title = (try? container.decode(String.self, forKey: .title)) ?? key
        currentSessionID = try? container.decode(String.self, forKey: .currentSessionID)
        lastPreview = try? container.decode(String.self, forKey: .lastPreview)
    }

    /// WS1 P3/P8: thin shim over the Codable decoder so the wire schema lives in one place
    /// (CodingKeys). Returns nil on malformed input (e.g. missing project_key), matching the
    /// previous `[String: Any]` decoder's drop-on-failure behavior.
    static func from(dictionary: [String: Any]) -> LogosProject? {
        guard
            JSONSerialization.isValidJSONObject(dictionary),
            let data = try? JSONSerialization.data(withJSONObject: dictionary)
        else { return nil }
        return try? JSONDecoder().decode(LogosProject.self, from: data)
    }
}
