import CryptoKit
import Foundation
import Security

/// Leaf-certificate SPKI pinning for the direct-WSS transport (WS3 S4, iOS side).
///
/// Computes the same pin the adapter distributes via the pairing deep link:
/// `base64( SHA-256( DER SubjectPublicKeyInfo ) )` of the leaf's public key. Must stay
/// byte-for-byte compatible with `plugins/logos/tls.py` `spki_sha256_b64` — the cross-impl
/// known-answer test (`LogosCertPinningTests`) pins that contract with a fixed certificate.
///
/// The adapter serves a self-signed EC P-256 leaf, so we reconstruct the SubjectPublicKeyInfo
/// DER by prepending the fixed prime256v1 ASN.1 header to the key's ANSI X9.63 point that
/// `SecKeyCopyExternalRepresentation` returns. Non-EC-P256 leaves yield nil (pin can't match).
enum LogosCertPinning {
    /// ASN.1 SubjectPublicKeyInfo header for an EC prime256v1 (P-256) public key, followed by
    /// the 65-byte uncompressed point (0x04 || X || Y).
    private static let p256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// The base64 SPKI-SHA256 pin of `certificate`, or nil if its key isn't EC P-256.
    static func spkiSHA256(of certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        // EC P-256 external representation is the 65-byte uncompressed point.
        guard raw.count == 65, raw.first == 0x04 else { return nil }
        var spki = Data(p256SPKIHeader)
        spki.append(raw)
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// Constant-time string compare so a pin check doesn't leak via timing.
    static func pinsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }

    /// Whether the leaf of `serverTrust` matches `expectedPin`. False (reject) if the chain or
    /// key can't be read — fail closed, since a pin was explicitly expected.
    static func leafMatches(serverTrust: SecTrust, expectedPin: String) -> Bool {
        guard
            let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leaf = chain.first,
            let pin = spkiSHA256(of: leaf)
        else { return false }
        return pinsMatch(pin, expectedPin)
    }

    /// Shared server-trust challenge resolution used by both the live socket box and the pairing
    /// exchanger. With a pin, the matching (self-signed) leaf is accepted and all else rejected —
    /// pinning replaces CA evaluation. Without a pin, default CA handling (Tailscale/loopback).
    /// Returns true when the pin was enforced and matched (for logging), false otherwise.
    @discardableResult
    static func resolve(
        challenge: URLAuthenticationChallenge,
        pinnedSPKISHA256: String?,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return false
        }
        let trimmed = pinnedSPKISHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pin = trimmed, pin.isEmpty == false else {
            completionHandler(.performDefaultHandling, nil)
            return false
        }
        if leafMatches(serverTrust: serverTrust, expectedPin: pin) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return true
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        return false
    }
}

/// A URLSession delegate that enforces leaf SPKI pinning — used for the one-shot pairing
/// exchange connection (the live control socket uses URLSessionWebSocketTaskBox directly).
final class LogosPinningSessionDelegate: NSObject, URLSessionDelegate {
    private let pinnedSPKISHA256: String?

    init(pinnedSPKISHA256: String?) {
        self.pinnedSPKISHA256 = pinnedSPKISHA256
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LogosCertPinning.resolve(challenge: challenge, pinnedSPKISHA256: pinnedSPKISHA256, completionHandler: completionHandler)
    }
}
