import Foundation
import OSLog
import UIKit

/// Client-side dependencies the APNS/notification-routing + auto-play subsystem needs from its owner
/// (WS1 P5, mirroring `AudioCoordinatorHost` + `ProgressActivityManagerHost` + `InteractionControllerHost`).
/// The `NotificationRouter` reaches back through this narrow seam instead of holding the whole
/// `LogosClient`, so the notification/auto-play domain stays decoupled from the connection socket,
/// message store, and audio coordinator. The host is held `weak`; every member is a no-op-safe call
/// the router routes non-notification work through.
@MainActor
protocol NotificationRouterHost: AnyObject {
    /// The active project key notification routes/frames are scoped to (mirrors `LogosClient.activeProjectKey`);
    /// settable because `handleNotificationRoute` switches the active project to the route's project.
    var notificationActiveProjectKey: String { get set }
    /// The device id stamped onto outbound `register_device` frames (mirrors `LogosClient.settings.deviceID`).
    var notificationDeviceID: String { get }
    /// Whether the signed hello is authenticated (mirrors `connectionState == .connected`).
    var notificationIsConnected: Bool { get }
    /// Whether the underlying task + open socket exist (mirrors `task != nil && isWebSocketOpen`).
    var notificationHasOpenSocket: Bool { get }
    /// Kick a fresh connect attempt when a route arrives while disconnected (mirrors `LogosClient.connect()`).
    func notificationConnect()
    /// Send a notification-subsystem frame over the socket (mirrors `LogosClient.sendFrame`'s default-auth path).
    @discardableResult func sendNotificationFrame(_ frame: [String: Any], onCompletion: ((Result<Void, Error>) -> Void)?) -> Bool
    /// Request a message backfill window (mirrors `LogosClient.requestMessages(afterServerSeq:)`).
    func notificationRequestMessages(afterServerSeq: Int)
    /// The newest persisted `server_seq` for a project (mirrors `LogosClient.latestServerSeq(projectKey:)`).
    func notificationLatestServerSeq(projectKey: String) -> Int
    /// Look up a specific stored message (mirrors `store.message(projectKey:sessionID:messageID:)`).
    func notificationStoredMessage(projectKey: String, sessionID: String?, messageID: String) -> LogosMessage?
    /// The latest final message at/after a `server_seq` (mirrors `store.latestFinalMessage(...)`).
    func notificationLatestFinalMessage(projectKey: String, sessionID: String, atOrAfterServerSeq serverSeq: Int) -> LogosMessage?
    /// Re-derive the visible thread after the router mutates its anchors (mirrors `LogosClient.refreshMessages()`).
    func notificationRefreshMessages()
    /// The currently visible thread, used to decide whether an anchored message is already on screen
    /// (mirrors reading `LogosClient.messages`).
    var notificationVisibleMessages: [LogosMessage] { get }
    /// Route an auto-play request to the audio coordinator, threading the autoplay/route keys so a
    /// failed send releases them (mirrors `audioCoordinator.requestPlayback(message:mode:"final_auto":…)`).
    @discardableResult func requestAutoPlay(message: LogosMessage, autoPlayKey: String?, notificationRouteKey: String?) -> Bool
}

/// Owns the APNS/notification-routing + auto-play subsystem lifted out of `LogosClient` (WS1 P5): the
/// published thread-focus request, the pending notification route + finished-route fulfillment, the
/// auto-played/fulfilled route-key bookkeeping, the notification-route anchors, the pending APNS token,
/// and the scene-activation gate that defers playback until the foreground scene is active. `LogosClient`
/// keeps a reference, re-exposes `threadFocusRequest` via computed forwarding, keeps the public
/// `registerDevice`/`handleNotificationRoute`/`updateSceneActivationForPlayback`/`completeThreadFocusRequest`
/// names as delegating forwarders, and routes the run-reconciled auto-play tail through the router so
/// views/tests are unchanged. All client-side dependencies are routed through `host` (held `weak`).
@MainActor
final class NotificationRouter: ObservableObject {
    @Published private(set) var threadFocusRequest: ThreadFocusRequest?

    weak var host: NotificationRouterHost?

    private var autoPlayedMessageKeys = Set<String>()
    private var pendingAPNSToken: String?
    private var pendingNotificationRoute: PendingNotificationRouteState?
    private var pendingFinalAutoPlayMessage: LogosMessage?
    private var fulfilledNotificationRouteKeys = Set<String>()
    private var notificationRouteAnchors: [String: LogosMessage] = [:]
    private var threadFocusRequestSequence = 0
    private var notificationPlaybackSceneActive = false

    private static let maxNotificationRouteAnchors = 8
    private static let notificationReplayContextWindow = 25

    private struct PendingNotificationRouteState {
        var route: LogosNotificationRoute
        var didRequestMessages: Bool = false
    }

    private enum PrivateNotificationRouteKind {
        static let finished = "finished"
    }

    // MARK: - Device registration

    func registerDevice(apnsToken: String?) {
        if let token = apnsToken, token.isEmpty == false {
            pendingAPNSToken = token
            LogosConnectionLog.logger.info("Stored pending APNS token for registration token_bytes=\(token.utf8.count, privacy: .public)")
        }
        guard host?.notificationHasOpenSocket == true, host?.notificationIsConnected == true else {
            LogosConnectionLog.logger.info("Device registration deferred until signed hello is authenticated pending_apns_token=\(self.pendingAPNSToken != nil, privacy: .public) connected=\(self.host?.notificationIsConnected == true, privacy: .public) open=\(self.host?.notificationHasOpenSocket == true, privacy: .public)")
            return
        }
        let projectKey = host?.notificationActiveProjectKey ?? "default"
        let deviceID = host?.notificationDeviceID ?? ""
        var payload: [String: Any] = [
            "display_name": UIDevice.current.name,
            "apns_environment": LogosAPNSEnvironment.resolved(),
            "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio", "notifications"]
        ]
        if let token = pendingAPNSToken, token.isEmpty == false {
            payload["apns_token"] = token
        }
        let sent = host?.sendNotificationFrame([
            "type": "register_device",
            "request_id": UUID().uuidString,
            "device_id": deviceID,
            "project_key": projectKey,
            "payload": payload
        ], onCompletion: nil) ?? false
        LogosConnectionLog.logger.info("Device registration send requested sent=\(sent, privacy: .public) device_id=\(deviceID, privacy: .public) project_key=\(projectKey, privacy: .public) includes_apns_token=\(payload["apns_token"] != nil, privacy: .public)")
    }

    /// Re-arm device registration with whatever pending token is already stored (mirrors the client's
    /// former `registerDevice(apnsToken: pendingAPNSToken)` dispatch from the `hello` handler).
    func registerDeviceWithPendingToken() {
        registerDevice(apnsToken: nil)
    }

    /// Forget the pending APNS token once the adapter confirms registration (mirrors the client's
    /// former `pendingAPNSToken = nil` in the `registered` handler).
    func clearPendingAPNSToken() {
        pendingAPNSToken = nil
    }

    // MARK: - Notification routing

    func handleNotificationRoute(_ route: LogosNotificationRoute) {
        host?.notificationActiveProjectKey = route.projectKey
        pendingNotificationRoute = PendingNotificationRouteState(route: route)
        if host?.notificationIsConnected != true || host?.notificationHasOpenSocket != true {
            host?.notificationConnect()
        } else {
            processPendingNotificationRouteIfReady()
        }
    }

    func updateSceneActivationForPlayback(isActive: Bool) {
        let wasActive = notificationPlaybackSceneActive
        notificationPlaybackSceneActive = isActive
        guard isActive, wasActive == false else { return }
        processPendingNotificationRouteIfReady()
        processPendingFinalAutoPlayIfReady()
    }

    func processPendingNotificationRouteIfReady() {
        guard host?.notificationIsConnected == true, host?.notificationHasOpenSocket == true else { return }
        guard var pending = pendingNotificationRoute else { return }
        if pending.didRequestMessages == false {
            host?.notificationRequestMessages(afterServerSeq: notificationFetchAfterServerSeq(for: pending.route))
            pending.didRequestMessages = true
            pendingNotificationRoute = pending
        }
        if pending.route.kind.lowercased() == PrivateNotificationRouteKind.finished {
            fulfillPendingFinishedNotificationRouteIfPossible()
        } else {
            pendingNotificationRoute = nil
        }
    }

    private func notificationFetchAfterServerSeq(for route: LogosNotificationRoute) -> Int {
        if let serverSeq = route.serverSeq {
            return max(serverSeq - Self.notificationReplayContextWindow, 0)
        }
        return host?.notificationLatestServerSeq(projectKey: route.projectKey) ?? 0
    }

    private func notificationRouteKey(_ route: LogosNotificationRoute) -> String {
        [
            route.kind.lowercased(),
            route.projectKey,
            route.sessionID ?? "",
            route.messageID ?? "",
            route.requestID ?? "",
            route.serverSeq.map(String.init) ?? ""
        ].joined(separator: "|")
    }

    func fulfillPendingFinishedNotificationRouteIfPossible() {
        guard let pending = pendingNotificationRoute else { return }
        let route = pending.route
        guard route.kind.lowercased() == PrivateNotificationRouteKind.finished else { return }
        let routeKey = notificationRouteKey(route)
        guard fulfilledNotificationRouteKeys.contains(routeKey) == false else {
            pendingNotificationRoute = nil
            return
        }
        guard let message = notificationFinalMessage(for: route) else { return }
        anchorNotificationRouteMessage(message, routeKey: routeKey)
        guard notificationPlaybackSceneActive else { return }
        guard requestNotificationPlayback(message, routeKey: routeKey) else { return }
        pendingNotificationRoute = nil
        fulfilledNotificationRouteKeys.insert(routeKey)
    }

    private func anchorNotificationRouteMessage(_ message: LogosMessage, routeKey: String) {
        guard message.isProgressUpdate == false else { return }
        notificationRouteAnchors[message.id] = message
        trimNotificationRouteAnchors()
        host?.notificationRefreshMessages()
        let isVisible = host?.notificationVisibleMessages.contains { $0.id == message.id } ?? false
        LogosConnectionLog.logger.info("Finished notification route anchored project_key=\(message.projectKey, privacy: .public) session_id=\(message.sessionID, privacy: .public) message_id=\(message.messageID, privacy: .public) server_seq=\(message.serverSeq, privacy: .public) route_key=\(routeKey, privacy: .public) visible=\(isVisible, privacy: .public)")
        setThreadFocusRequest(
            targetMessageID: message.id,
            projectKey: message.projectKey,
            reason: .finishedNotification,
            routeKey: routeKey,
            serverSeq: message.serverSeq,
            isVisible: isVisible
        )
    }

    private func setThreadFocusRequest(
        targetMessageID: String,
        projectKey: String,
        reason: ThreadFocusReason,
        routeKey: String,
        serverSeq: Int,
        isVisible: Bool
    ) {
        threadFocusRequestSequence += 1
        let request = ThreadFocusRequest(
            id: "thread-focus-\(threadFocusRequestSequence)",
            projectKey: projectKey,
            targetMessageID: targetMessageID,
            reason: reason,
            createdAt: Date().timeIntervalSince1970
        )
        threadFocusRequest = request
        LogosConnectionLog.logger.info("Thread focus requested project_key=\(projectKey, privacy: .public) target_message_id=\(targetMessageID, privacy: .public) server_seq=\(serverSeq, privacy: .public) route_key=\(routeKey, privacy: .public) focus_id=\(request.id, privacy: .public) visible=\(isVisible, privacy: .public)")
    }

    func completeThreadFocusRequest(id: String) {
        guard threadFocusRequest?.id == id else { return }
        LogosConnectionLog.logger.info("Thread focus completed focus_id=\(id, privacy: .public) target_message_id=\(self.threadFocusRequest?.targetMessageID ?? "<none>", privacy: .public)")
        threadFocusRequest = nil
    }

    /// Drop the published thread-focus request if it no longer targets the active project (called from
    /// the client's project-switch reset; mirrors the former inline `threadFocusRequest = nil`).
    func clearThreadFocusRequestIfProjectChanged(activeProjectKey: String) {
        if let request = threadFocusRequest, request.projectKey != activeProjectKey {
            threadFocusRequest = nil
        }
    }

    private func trimNotificationRouteAnchors() {
        guard notificationRouteAnchors.count > Self.maxNotificationRouteAnchors else { return }
        let removeCount = notificationRouteAnchors.count - Self.maxNotificationRouteAnchors
        let oldestKeys = notificationRouteAnchors
            .sorted { lhs, rhs in
                if lhs.value.serverSeq != rhs.value.serverSeq {
                    return lhs.value.serverSeq < rhs.value.serverSeq
                }
                if lhs.value.timestamp != rhs.value.timestamp {
                    return lhs.value.timestamp < rhs.value.timestamp
                }
                return lhs.key < rhs.key
            }
            .prefix(removeCount)
            .map(\.key)
        for key in oldestKeys {
            notificationRouteAnchors.removeValue(forKey: key)
        }
    }

    /// The anchored notification messages for the active project, merged into the visible thread by the
    /// client's `refreshMessages` (mirrors the former inline iteration over `notificationRouteAnchors`).
    func anchoredMessages(forProjectKey projectKey: String) -> [LogosMessage] {
        notificationRouteAnchors.values.filter { $0.projectKey == projectKey && $0.isProgressUpdate == false }
    }

    // MARK: - Auto-play

    @discardableResult
    private func requestNotificationPlayback(_ message: LogosMessage, routeKey: String) -> Bool {
        requestFinalAutoPlayback(message, notificationRouteKey: routeKey)
    }

    @discardableResult
    private func requestFinalAutoPlayback(_ message: LogosMessage, notificationRouteKey: String? = nil) -> Bool {
        let key = message.id
        guard autoPlayedMessageKeys.contains(key) == false else {
            if pendingFinalAutoPlayMessage?.id == key {
                pendingFinalAutoPlayMessage = nil
            }
            return true
        }
        let sent = host?.requestAutoPlay(message: message, autoPlayKey: key, notificationRouteKey: notificationRouteKey) ?? false
        if sent {
            autoPlayedMessageKeys.insert(key)
            if pendingFinalAutoPlayMessage?.id == key {
                pendingFinalAutoPlayMessage = nil
            }
        }
        return sent
    }

    func processPendingFinalAutoPlayIfReady() {
        guard notificationPlaybackSceneActive else { return }
        guard host?.notificationIsConnected == true, host?.notificationHasOpenSocket == true else { return }
        guard let message = pendingFinalAutoPlayMessage else { return }
        guard message.projectKey == host?.notificationActiveProjectKey else { return }
        _ = requestFinalAutoPlayback(message)
    }

    private func notificationFinalMessage(for route: LogosNotificationRoute) -> LogosMessage? {
        if let messageID = route.messageID, messageID.isEmpty == false {
            guard let message = host?.notificationStoredMessage(projectKey: route.projectKey, sessionID: route.sessionID, messageID: messageID) else {
                return nil
            }
            guard message.status == "persisted",
                  message.role != "user",
                  message.isFinal,
                  message.hasFinalizedMetadata,
                  message.isProgressUpdate == false
            else {
                return nil
            }
            if let serverSeq = route.serverSeq, message.serverSeq < serverSeq {
                return nil
            }
            return message
        }
        guard let sessionID = route.sessionID, sessionID.isEmpty == false,
              let serverSeq = route.serverSeq else {
            return nil
        }
        return host?.notificationLatestFinalMessage(projectKey: route.projectKey, sessionID: sessionID, atOrAfterServerSeq: serverSeq)
    }

    /// The auto-play tail lifted from `LogosClient.maybeAutoPlayLiveAssistantMessage`. The client keeps
    /// the run-reconciliation gate (runStatus/progress/outstanding ids) because it is driven from the
    /// `state_update` pipeline, and calls here once the message has been accepted for auto-play. Owns
    /// the auto-play dedupe + scene-active deferral that this router now holds.
    func autoPlayLiveAssistantMessageIfNeeded(_ message: LogosMessage) {
        let key = message.id
        guard autoPlayedMessageKeys.contains(key) == false else { return }
        guard notificationPlaybackSceneActive else {
            pendingFinalAutoPlayMessage = message
            return
        }
        _ = requestFinalAutoPlayback(message)
    }

    // MARK: - Audio ↔ notification key clearing

    /// Release a notification auto-play key (mirrors the former `autoPlayedMessageKeys.remove`); called
    /// by the audio coordinator (through the client's `AudioCoordinatorHost`) on a failed playback.
    func clearAutoPlayedMessageKey(_ key: String) {
        autoPlayedMessageKeys.remove(key)
    }

    /// Release a fulfilled notification-route key (mirrors the former `fulfilledNotificationRouteKeys.remove`);
    /// called by the audio coordinator (through the client's `AudioCoordinatorHost`) on a failed playback so
    /// the finished-route can be retried.
    func clearFulfilledNotificationRouteKey(_ key: String) {
        fulfilledNotificationRouteKeys.remove(key)
    }
}
