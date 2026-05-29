import Foundation

struct LogosProject: Identifiable, Hashable {
    var id: String { projectKey }
    let projectKey: String
    var title: String
    var currentSessionID: String?
    var lastPreview: String?

    static func from(dictionary: [String: Any]) -> LogosProject? {
        guard let projectKey = dictionary["project_key"] as? String else { return nil }
        return LogosProject(
            projectKey: projectKey,
            title: dictionary["title"] as? String ?? projectKey,
            currentSessionID: dictionary["current_session_id"] as? String,
            lastPreview: dictionary["last_preview"] as? String
        )
    }
}
