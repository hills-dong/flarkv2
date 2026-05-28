import Foundation
import CryptoKit

/// Decrypted contents of an invite URL — everything a recipient needs to
/// re-bind a WebDAV Space without re-entering any fields.
struct SpaceInvitePayload: Codable, Identifiable, Equatable {
    var v: Int = 1
    var id: String          // SpaceConfig.id (== WebDAV directory name)
    var name: String
    var url: String         // WebDAV base URL
    var user: String
    var pw: String
    var iat: Int64          // issued-at, unix seconds
    var exp: Int64          // expires-at, unix seconds (iat + ttl)

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

enum SpaceInviteError: Error, LocalizedError {
    case malformed
    case decryptFailed
    case expired
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .malformed:          return String(localized: "邀请链接格式不正确")
        case .decryptFailed:      return String(localized: "邀请链接解密失败")
        case .expired:            return String(localized: "邀请链接已过期")
        case .unsupportedVersion: return String(localized: "邀请链接版本过新，请升级 App")
        }
    }
}

/// `flark://invite/<token>` codec. Token bytes = `key(32) ‖ AES-GCM.combined`,
/// where `combined = nonce(12) ‖ ciphertext ‖ tag(16)`. The 256-bit key is
/// generated per invite on this device — never persisted, never sent to a
/// server, only embedded in the link itself. Encryption isn't an access gate
/// (anyone with the link can join, by design) — it provides tamper resistance
/// for the embedded `exp` and avoids leaking the WebDAV password in plain
/// base64 on the clipboard.
enum SpaceInviteCodec {
    static let scheme = "flark"
    static let host = "invite"
    static let ttl: TimeInterval = 7 * 24 * 3600

    static func makeURL(spaceID: String, name: String, url: String,
                        user: String, pw: String,
                        now: Date = Date()) throws -> URL {
        let iat = Int64(now.timeIntervalSince1970)
        let payload = SpaceInvitePayload(
            id: spaceID, name: name, url: url, user: user, pw: pw,
            iat: iat, exp: iat + Int64(ttl))
        let plaintext = try JSONEncoder().encode(payload)
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw SpaceInviteError.malformed }
        var token = Data()
        token.append(key.withUnsafeBytes { Data($0) })
        token.append(combined)
        let encoded = base64URLEncode(token)
        guard let u = URL(string: "\(scheme)://\(host)/\(encoded)") else {
            throw SpaceInviteError.malformed
        }
        return u
    }

    static func parse(_ url: URL, now: Date = Date()) throws -> SpaceInvitePayload {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host else { throw SpaceInviteError.malformed }
        // path is "/<token>"; pathComponents = ["/", "<token>"] (or just
        // ["<token>"] on macOS depending on URL). Take the first non-"/" piece.
        let token = url.pathComponents.first { $0 != "/" && !$0.isEmpty } ?? ""
        guard !token.isEmpty else { throw SpaceInviteError.malformed }
        guard let raw = base64URLDecode(token), raw.count > 32 else {
            throw SpaceInviteError.malformed
        }
        let keyData = raw.prefix(32)
        let combined = raw.suffix(from: 32)
        let key = SymmetricKey(data: keyData)
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw SpaceInviteError.decryptFailed
        }
        let payload: SpaceInvitePayload
        do {
            payload = try JSONDecoder().decode(SpaceInvitePayload.self, from: plaintext)
        } catch {
            throw SpaceInviteError.malformed
        }
        if payload.v > 1 { throw SpaceInviteError.unsupportedVersion }
        if Int64(now.timeIntervalSince1970) >= payload.exp {
            throw SpaceInviteError.expired
        }
        return payload
    }

    /// Lightweight test of `url.scheme + host` so the app can decide whether
    /// to claim an incoming `onOpenURL` callback.
    static func isInviteURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    // MARK: - base64url

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (t.count % 4)
        if pad < 4 { t.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: t)
    }
}
