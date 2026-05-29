import Foundation

protocol WebSocketTasking: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

protocol WebSocketLifecycleObserving: AnyObject {
    func webSocketDidOpen(taskID: ObjectIdentifier)
    func webSocketDidClose(taskID: ObjectIdentifier, closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func webSocketDidFail(taskID: ObjectIdentifier, message: String)
}

protocol WebSocketTaskMaking {
    func webSocketTask(with url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) -> any WebSocketTasking
}

struct URLSessionWebSocketTaskFactory: WebSocketTaskMaking {
    func webSocketTask(with url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) -> any WebSocketTasking {
        URLSessionWebSocketTaskBox(url: url, lifecycleObserver: lifecycleObserver)
    }
}

final class URLSessionWebSocketTaskBox: NSObject, WebSocketTasking, URLSessionWebSocketDelegate {
    private weak var lifecycleObserver: (any WebSocketLifecycleObserving)?
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) {
        self.lifecycleObserver = lifecycleObserver
        self.url = url
        super.init()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.webSocketTask(with: url)
        LogosConnectionLog.logger.info("WebSocket task created url=\(LogosConnectionLog.urlDescription(url), privacy: .public)")
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func resume() {
        LogosConnectionLog.logger.info("WebSocket task resume requested url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
        task?.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        LogosConnectionLog.logger.info("WebSocket task cancel requested close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        task?.cancel(with: closeCode, reason: reason)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        guard let task else {
            LogosConnectionLog.logger.error("WebSocket send requested after task was released")
            completionHandler(URLError(.notConnectedToInternet))
            return
        }
        task.send(message, completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        guard let task else {
            LogosConnectionLog.logger.error("WebSocket receive requested after task was released")
            completionHandler(.failure(URLError(.notConnectedToInternet)))
            return
        }
        task.receive(completionHandler: completionHandler)
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
}
