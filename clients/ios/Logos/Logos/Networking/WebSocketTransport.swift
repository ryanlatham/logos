import Foundation

protocol WebSocketTasking: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

protocol WebSocketLifecycleObserving: AnyObject {
    func webSocketDidOpen(taskID: ObjectIdentifier)
    func webSocketDidClose(taskID: ObjectIdentifier, closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func webSocketDidFail(taskID: ObjectIdentifier, message: String)
}

protocol WebSocketTaskMaking {
    /// `pinnedSPKISHA256` (WS3 S4): when non-nil, the leaf cert's SPKI pin must match or the
    /// connection is rejected; nil keeps default CA evaluation (Tailscale/loopback).
    func webSocketTask(
        with url: URL,
        lifecycleObserver: (any WebSocketLifecycleObserving)?,
        pinnedSPKISHA256: String?
    ) -> any WebSocketTasking
}

struct URLSessionWebSocketTaskFactory: WebSocketTaskMaking {
    func webSocketTask(
        with url: URL,
        lifecycleObserver: (any WebSocketLifecycleObserving)?,
        pinnedSPKISHA256: String?
    ) -> any WebSocketTasking {
        URLSessionWebSocketTaskBox(url: url, lifecycleObserver: lifecycleObserver, pinnedSPKISHA256: pinnedSPKISHA256)
    }
}

final class URLSessionWebSocketTaskBox: NSObject, WebSocketTasking, URLSessionWebSocketDelegate, @unchecked Sendable {
    private weak var lifecycleObserver: (any WebSocketLifecycleObserving)?
    private let url: URL
    private let pinnedSPKISHA256: String?
    // `send`/`receive` run off the main actor (the async `WebSocketTasking` protocol) while `cancel()`
    // runs on the owning @MainActor `LogosConnection`. `lock` serializes access to the mutable
    // `session`/`task` so an off-main read can't race the main-actor teardown. send/receive grab the
    // task under the lock and then await on that local reference — never holding the lock across a
    // suspension — so a cancel that nils the task mid-send just makes the send throw.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?, pinnedSPKISHA256: String? = nil) {
        self.lifecycleObserver = lifecycleObserver
        self.url = url
        let trimmedPin = pinnedSPKISHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pinnedSPKISHA256 = (trimmedPin?.isEmpty == false) ? trimmedPin : nil
        super.init()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.webSocketTask(with: url)
        LogosConnectionLog.logger.info("WebSocket task created url=\(LogosConnectionLog.urlDescription(url), privacy: .public) pinned=\(self.pinnedSPKISHA256 != nil, privacy: .public)")
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func resume() {
        LogosConnectionLog.logger.info("WebSocket task resume requested url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
        lock.withLock { task }?.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        LogosConnectionLog.logger.info("WebSocket task cancel requested close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        lock.withLock {
            task?.cancel(with: closeCode, reason: reason)
            session?.invalidateAndCancel()
            session = nil
            task = nil
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let task = lock.withLock({ self.task }) else {
            LogosConnectionLog.logger.error("WebSocket send requested after task was released")
            throw URLError(.notConnectedToInternet)
        }
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let task = lock.withLock({ self.task }) else {
            LogosConnectionLog.logger.error("WebSocket receive requested after task was released")
            throw URLError(.notConnectedToInternet)
        }
        return try await task.receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        LogosConnectionLog.logger.info("URLSession WebSocket did open url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public) protocol=\(`protocol` ?? "<none>", privacy: .public)")
        lifecycleObserver?.webSocketDidOpen(taskID: ObjectIdentifier(self))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        LogosConnectionLog.logger.warning("URLSession WebSocket did close url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public) close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        lifecycleObserver?.webSocketDidClose(taskID: ObjectIdentifier(self), closeCode: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            LogosConnectionLog.logger.info("URLSession WebSocket task completed without error url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
            return
        }
        let message = failureMessage(for: error)
        LogosConnectionLog.logger.error("URLSession WebSocket task completed with error \(message, privacy: .public)")
        lifecycleObserver?.webSocketDidFail(taskID: ObjectIdentifier(self), message: message)
    }

    private func failureMessage(for error: Error) -> String {
        "WebSocket failed: \(LogosConnectionLog.errorDescription(error, url: url))"
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let isServerTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        // Pinned direct-WSS: the SPKI pin is the trust anchor, so the matching (self-signed) leaf
        // is accepted and all else rejected — independent of CA evaluation. No pin -> default.
        let accepted = LogosCertPinning.resolve(
            challenge: challenge,
            pinnedSPKISHA256: pinnedSPKISHA256,
            completionHandler: completionHandler
        )
        if isServerTrust, pinnedSPKISHA256 != nil, accepted == false {
            LogosConnectionLog.logger.error("Logos cert pin mismatch — rejecting connection url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
        }
    }
}
