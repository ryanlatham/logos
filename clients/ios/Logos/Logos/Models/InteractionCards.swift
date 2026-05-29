import Foundation

struct ApprovalCard: Identifiable, Equatable {
    let id: String
    let projectKey: String
    let title: String
    let summary: String
    let commandPreview: String
    let risk: String
}

struct ClarifyCard: Identifiable, Equatable {
    let id: String
    let projectKey: String
    let question: String
    let choices: [String]
    let allowFreeText: Bool
}
