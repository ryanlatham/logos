import Foundation

/// Client-side dependencies the approval/clarify interaction subsystem needs from its owner (WS1 P5,
/// mirroring `AudioCoordinatorHost` + `ProgressActivityManagerHost`). The `InteractionController`
/// reaches back through this narrow seam instead of holding the whole `LogosClient`, so the
/// interaction domain stays decoupled from the connection socket, run-status pipeline, and fast-ack
/// banner. The host is held `weak`; every member is a no-op-safe call the controller routes
/// non-interaction work through.
@MainActor
protocol InteractionControllerHost: AnyObject {
    /// The active project key interaction cards/frames are scoped to (mirrors `LogosClient.activeProjectKey`).
    var interactionActiveProjectKey: String { get }
    /// The coarse run lifecycle the interaction methods read and drive (mirrors `LogosClient.runStatus`).
    var interactionRunStatus: LogosRunStatus { get set }
    /// The device id stamped onto outbound interaction-response frames (mirrors `LogosClient.settings.deviceID`).
    var interactionDeviceID: String { get }
    /// Gate a user-facing interaction action on the connection being live (mirrors the client's
    /// `ensureConnectedForUserAction`, including its error side effect when not connected).
    @discardableResult func ensureInteractionConnected(_ action: String) -> Bool
    /// Send an interaction-response frame over the socket (mirrors `LogosClient.sendFrame`'s default-auth path).
    @discardableResult func sendInteractionFrame(_ frame: [String: Any], onCompletion: ((Result<Void, Error>) -> Void)?) -> Bool
    /// Cancel the stale-silence watchdog (mirrors `LogosClient.suspendStaleTimeout`).
    func suspendInteractionStaleTimeout()
    /// Show the transient fast-ack banner (mirrors `LogosClient.setTransientAck`).
    func setInteractionTransientAck(_ text: String?, id: String?, projectKey: String?)
    /// Clear the transient fast-ack banner unconditionally (mirrors `LogosClient.clearAck()`).
    func clearInteractionAck()
    /// Clear the transient fast-ack banner only when it matches the given id/project
    /// (mirrors `LogosClient.clearAck(matching:projectKey:)`).
    func clearInteractionAck(matchingID id: String, projectKey: String)
}

/// Owns the approval/clarify interaction subsystem lifted out of `LogosClient` (WS1 P5): the
/// published approval/clarify cards + the pending-response id, the inbound request/pending-interaction
/// handling, the view-facing approve/deny/answer actions, and the run-status/error/cancel-driven card
/// transitions. `LogosClient` keeps a reference, re-exposes `approvalCard`/`clarifyCard`/
/// `pendingInteractionResponseID` via computed forwarding, and routes inbound interaction frames
/// through the controller so views/tests are unchanged. All client-side dependencies are routed
/// through `host` (held `weak`).
@MainActor
final class InteractionController: ObservableObject {
    @Published private(set) var approvalCard: ApprovalCard?
    @Published private(set) var clarifyCard: ClarifyCard?
    @Published private(set) var pendingInteractionResponseID: String?

    weak var host: InteractionControllerHost?

    // MARK: - Inbound interaction frames

    func handleApprovalRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? host?.interactionActiveProjectKey ?? "default"
        guard projectKey == host?.interactionActiveProjectKey else { return }
        guard host?.interactionRunStatus != .cancelling else { return }
        approvalCard = ApprovalCard(
            id: root["request_id"] as? String ?? payload["approval_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            title: payload["title"] as? String ?? "Approval required",
            summary: payload["summary"] as? String ?? "Hermes needs approval.",
            commandPreview: payload["command_preview"] as? String ?? "",
            risk: payload["risk"] as? String ?? ""
        )
        host?.interactionRunStatus = .awaitingApproval
        host?.suspendInteractionStaleTimeout()
        pendingInteractionResponseID = nil
        host?.clearInteractionAck()
    }

    func handleClarifyRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? host?.interactionActiveProjectKey ?? "default"
        guard projectKey == host?.interactionActiveProjectKey else { return }
        guard host?.interactionRunStatus != .cancelling else { return }
        clarifyCard = ClarifyCard(
            id: root["request_id"] as? String ?? payload["clarify_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            question: payload["question"] as? String ?? "Hermes needs clarification.",
            choices: payload["choices"] as? [String] ?? [],
            allowFreeText: payload["allow_free_text"] as? Bool ?? true
        )
        host?.interactionRunStatus = .awaitingClarification
        host?.suspendInteractionStaleTimeout()
        pendingInteractionResponseID = nil
        host?.clearInteractionAck()
    }

    func handlePendingInteraction(_ interaction: [String: Any]) {
        let type = interaction["type"] as? String ?? interaction["frame_type"] as? String
        if type == "approval_request" {
            handleApprovalRequest(interaction)
        } else if type == "clarify_request" {
            handleClarifyRequest(interaction)
        }
    }

    // MARK: - View-facing interaction actions

    func approveCurrentRequest() {
        guard let approvalCard else { return }
        guard host?.interactionRunStatus != .cancelling else { return }
        guard host?.ensureInteractionConnected("approve request") == true else { return }
        let sent = host?.sendInteractionFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": host?.interactionDeviceID ?? "",
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "approve"]
        ]) { [weak self, requestID = approvalCard.id, projectKey = approvalCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        } ?? false
        if sent {
            pendingInteractionResponseID = approvalCard.id
            host?.setInteractionTransientAck("Approved. Waiting for Hermes…", id: approvalCard.id, projectKey: approvalCard.projectKey)
        }
    }

    func denyCurrentRequest() {
        guard let approvalCard else { return }
        guard host?.interactionRunStatus != .cancelling else { return }
        guard host?.ensureInteractionConnected("deny request") == true else { return }
        let sent = host?.sendInteractionFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": host?.interactionDeviceID ?? "",
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "deny"]
        ]) { [weak self, requestID = approvalCard.id, projectKey = approvalCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        } ?? false
        if sent {
            pendingInteractionResponseID = approvalCard.id
            host?.setInteractionTransientAck("Denied. Waiting for Hermes…", id: approvalCard.id, projectKey: approvalCard.projectKey)
        }
    }

    @discardableResult
    func answerClarification(_ text: String) -> Bool {
        guard let clarifyCard else { return false }
        guard host?.interactionRunStatus != .cancelling else { return false }
        guard host?.ensureInteractionConnected("answer clarification") == true else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let sent = host?.sendInteractionFrame([
            "type": "clarify_response",
            "request_id": clarifyCard.id,
            "device_id": host?.interactionDeviceID ?? "",
            "project_key": clarifyCard.projectKey,
            "payload": [
                "clarify_id": clarifyCard.id,
                "text": trimmed
            ]
        ]) { [weak self, requestID = clarifyCard.id, projectKey = clarifyCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        } ?? false
        if sent {
            pendingInteractionResponseID = clarifyCard.id
            host?.setInteractionTransientAck("Clarification sent. Waiting for Hermes…", id: clarifyCard.id, projectKey: clarifyCard.projectKey)
        }
        return sent
    }

    // MARK: - Reconciliation / clearing

    func reconcilePendingInteractionCards(_ pending: [[String: Any]], projectKey: String) {
        guard projectKey == host?.interactionActiveProjectKey else { return }
        let pendingIDs = Set(pending.compactMap { interaction in
            interaction["request_id"] as? String ?? (interaction["payload"] as? [String: Any])?["approval_id"] as? String ?? (interaction["payload"] as? [String: Any])?["clarify_id"] as? String
        })
        if let approvalCard, pendingIDs.contains(approvalCard.id) == false {
            host?.clearInteractionAck(matchingID: approvalCard.id, projectKey: approvalCard.projectKey)
            self.approvalCard = nil
        }
        if let clarifyCard, pendingIDs.contains(clarifyCard.id) == false {
            host?.clearInteractionAck(matchingID: clarifyCard.id, projectKey: clarifyCard.projectKey)
            self.clarifyCard = nil
        }
        if let pendingInteractionResponseID, pendingIDs.contains(pendingInteractionResponseID) == false {
            host?.clearInteractionAck(matchingID: pendingInteractionResponseID, projectKey: projectKey)
            self.pendingInteractionResponseID = nil
        }
    }

    func clearPendingInteractionResponse(requestID: String, projectKey: String) {
        if pendingInteractionResponseID == requestID {
            pendingInteractionResponseID = nil
        }
        host?.clearInteractionAck(matchingID: requestID, projectKey: projectKey)
    }

    func clearInteractionStateForCancel() {
        approvalCard = nil
        clarifyCard = nil
        pendingInteractionResponseID = nil
    }

    func clearCardsNotMatchingActiveProject() {
        let activeProjectKey = host?.interactionActiveProjectKey
        if let approvalCard, approvalCard.projectKey != activeProjectKey {
            self.approvalCard = nil
        }
        if let clarifyCard, clarifyCard.projectKey != activeProjectKey {
            self.clarifyCard = nil
        }
    }

    // MARK: - Client-pipeline helpers

    /// Apply the awaiting-approval/clarification card transitions lifted from `LogosClient.handleRunStatus`.
    /// The client owns the rest of the run-status machine; this only mutates interaction cards based on
    /// the previous/next run status.
    func applyRunStatusTransition(previous: LogosRunStatus, next: LogosRunStatus) {
        if previous == .awaitingApproval && next != .awaitingApproval {
            approvalCard = nil
            pendingInteractionResponseID = nil
        } else if let approvalCard, pendingInteractionResponseID == approvalCard.id, next != .awaitingApproval {
            self.approvalCard = nil
            pendingInteractionResponseID = nil
        }
        if previous == .awaitingClarification && next != .awaitingClarification {
            clarifyCard = nil
            pendingInteractionResponseID = nil
        } else if let clarifyCard, pendingInteractionResponseID == clarifyCard.id, next != .awaitingClarification {
            self.clarifyCard = nil
            pendingInteractionResponseID = nil
        }
    }

    /// Drop the approval card if it matches the given request id (called from the client's
    /// `approval_not_pending` adapter-error path).
    func clearApprovalCardIfMatches(requestID: String?) {
        if approvalCard?.id == requestID { approvalCard = nil }
    }

    /// Drop the clarify card if it matches the given request id (called from the client's
    /// `clarify_not_pending` adapter-error path).
    func clearClarifyCardIfMatches(requestID: String?) {
        if clarifyCard?.id == requestID { clarifyCard = nil }
    }

    /// Resolve an in-flight interaction when the socket drops (called from the client's socket-failure
    /// path). When `clearCards` is true the cards are torn down; otherwise only the pending response is
    /// cleared so the user can retry once reconnected.
    func failInterruptedInteraction(clearCards: Bool) {
        if clearCards {
            clearInteractionStateForCancel()
        } else if let pendingInteractionResponseID {
            clearPendingInteractionResponse(requestID: pendingInteractionResponseID, projectKey: host?.interactionActiveProjectKey ?? "default")
        }
    }

    /// Clear approval/clarify interaction cards when a run ends via cancel/interrupt (called from the
    /// progress manager's run-teardown path through the client).
    func clearInteractionStateForProgress() {
        clearInteractionStateForCancel()
    }
}
