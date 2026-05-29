import Foundation
import UIKit

struct LogosPairingRoute: Equatable, Identifiable {
    var id: String { "\(adapterURL)|\(deviceID)|\(Int(expiresAt?.timeIntervalSince1970 ?? 0))" }
    let adapterURL: String
    let deviceID: String
    let pairToken: String?
    let deviceSecret: String?
    let expiresAt: Date?
    let autoConnect: Bool
    /// WS3 S4: optional direct-WSS leaf SPKI pin distributed in the deep link. nil for
    /// Tailscale/loopback invites (default TLS handling). Defaulted so existing memberwise
    /// initializers stay source-compatible.
    var certSPKISHA256: String? = nil

    var adapterHostDescription: String {
        URL(string: adapterURL)?.host ?? adapterURL
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var allowsPairingTransport: Bool {
        guard let url = URL(string: adapterURL), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "wss" { return true }
        return scheme == "ws" && LogosPairingRoute.isLoopbackHost(url.host)
    }

    static func from(url: URL) -> LogosPairingRoute? {
        guard url.scheme == "logos", url.host == "pair", let fragment = url.fragment, fragment.isEmpty == false else {
            return nil
        }
        guard let data = Data(base64URLEncoded: fragment),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let version = root["v"] as? Int ?? Int(root["v"] as? String ?? "")
        guard version == 1 else { return nil }
        guard let adapterURL = (root["adapter_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              adapterURL.isEmpty == false,
              let parsedAdapterURL = URL(string: adapterURL),
              let scheme = parsedAdapterURL.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              parsedAdapterURL.host?.isEmpty == false,
              let deviceID = (root["device_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              deviceID.isEmpty == false
        else { return nil }
        guard let pairToken = (root["pair_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        let expiresAt: Date?
        if let raw = root["expires_at"] as? TimeInterval {
            expiresAt = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        } else if let text = root["expires_at"] as? String, let raw = TimeInterval(text), raw > 0 {
            expiresAt = Date(timeIntervalSince1970: raw)
        } else {
            expiresAt = nil
        }
        let autoConnect = root["autoconnect"] as? Bool ?? true
        let certSPKISHA256 = (root["cert_spki_sha256"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return LogosPairingRoute(
            adapterURL: adapterURL,
            deviceID: deviceID,
            pairToken: pairToken,
            deviceSecret: nil,
            expiresAt: expiresAt,
            autoConnect: autoConnect,
            certSPKISHA256: certSPKISHA256
        )
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), host.isEmpty == false else { return false }
        if host == "localhost" || host == "ip6-localhost" { return true }
        if host == "::1" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }
}

struct LogosPairingCredential: Equatable {
    let adapterURL: String
    let deviceID: String
    let deviceSecret: String
}

protocol PairingCredentialExchanging {
    func exchange(route: LogosPairingRoute) async throws -> LogosPairingCredential
}

enum LogosPairingExchangeError: LocalizedError {
    case missingToken
    case invalidAdapterURL
    case insecureAdapterURL
    case expired
    case invalidResponse
    case adapterRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Pairing link is missing its one-time token."
        case .invalidAdapterURL:
            return "Pairing link contains an invalid adapter URL."
        case .insecureAdapterURL:
            return "Pairing requires wss:// unless the adapter is loopback for Simulator testing."
        case .expired:
            return "Pairing QR code has expired. Generate a fresh QR code and scan again."
        case .invalidResponse:
            return "Logos adapter returned an invalid pairing response."
        case .adapterRejected(let message):
            return message
        }
    }
}

final class WebSocketPairingCredentialExchanger: PairingCredentialExchanging {
    func exchange(route: LogosPairingRoute) async throws -> LogosPairingCredential {
        guard route.isExpired == false else { throw LogosPairingExchangeError.expired }
        guard route.allowsPairingTransport else { throw LogosPairingExchangeError.insecureAdapterURL }
        guard let pairToken = route.pairToken else { throw LogosPairingExchangeError.missingToken }
        guard let url = URL(string: route.adapterURL) else { throw LogosPairingExchangeError.invalidAdapterURL }
        // WS3 S4: pin the pairing handshake too, using the pin carried in the (signed) deep link —
        // otherwise a self-signed direct-WSS adapter would fail default CA validation here, before
        // the pin is ever persisted. nil pin -> default handling (Tailscale/loopback), unchanged.
        let pinningDelegate = LogosPinningSessionDelegate(pinnedSPKISHA256: route.certSPKISHA256)
        let session = URLSession(configuration: .ephemeral, delegate: pinningDelegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        let requestID = UUID().uuidString
        let displayName = await MainActor.run { UIDevice.current.name }
        let frame: [String: Any] = [
            "type": "pair",
            "request_id": requestID,
            "device_id": route.deviceID,
            "payload": [
                "pair_token": pairToken,
                "device_id": route.deviceID,
                "display_name": displayName,
                "adapter_url": route.adapterURL
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        try await send(task: task, string: String(decoding: data, as: UTF8.self))
        let response = try await receiveDictionary(task: task)
        if response["type"] as? String == "error" {
            let payload = response["payload"] as? [String: Any]
            let message = payload?["message"] as? String ?? "Logos pairing failed."
            throw LogosPairingExchangeError.adapterRejected(message)
        }
        guard response["type"] as? String == "pairing_complete",
              let payload = response["payload"] as? [String: Any],
              let deviceSecret = payload["device_secret"] as? String
        else { throw LogosPairingExchangeError.invalidResponse }
        let adapterURL = (payload["adapter_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? route.adapterURL
        let deviceID = (payload["device_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? route.deviceID
        guard adapterURL == route.adapterURL, deviceID == route.deviceID else {
            throw LogosPairingExchangeError.invalidResponse
        }
        return LogosPairingCredential(
            adapterURL: adapterURL,
            deviceID: deviceID,
            deviceSecret: LogosSettings.normalizedSecret(deviceSecret)
        )
    }

    private func send(task: URLSessionWebSocketTask, string: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(string)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receiveDictionary(task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
        let data: Data
        switch message {
        case .string(let string):
            guard let encoded = string.data(using: .utf8) else { throw LogosPairingExchangeError.invalidResponse }
            data = encoded
        case .data(let raw):
            data = raw
        @unknown default:
            throw LogosPairingExchangeError.invalidResponse
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LogosPairingExchangeError.invalidResponse
        }
        return root
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        self.init(base64Encoded: base64)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
