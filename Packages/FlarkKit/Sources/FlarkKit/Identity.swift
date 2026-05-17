import Foundation
import CryptoKit

/// A local device identity. The author id is derived from the public key so
/// nobody can impersonate another author: events are signed with the private
/// key and verified against the id.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let displayNameSeed: String

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.displayNameSeed = ""
    }

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }

    /// Stable author id = base32(sha256(publicKey)) prefix — path-safe, short.
    public var authorID: String { Self.authorID(forPublicKey: publicKeyData) }

    public static func authorID(forPublicKey pub: Data) -> String {
        let digest = SHA256.hash(data: pub)
        return base32(Data(digest)).prefix(26).lowercased()
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
    }

    public func sign(_ data: Data) -> Data {
        (try? privateKey.signature(for: data)) ?? Data()
    }

    public static func verify(_ signature: Data, of data: Data, publicKey pub: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// RFC 4648 base32 (no padding) — keeps ids filename-safe across WebDAV servers.
func base32(_ data: Data) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var out = ""
    var bits = 0
    var value = 0
    for byte in data {
        value = (value << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            out.append(alphabet[(value >> (bits - 5)) & 0x1F])
            bits -= 5
        }
    }
    if bits > 0 {
        out.append(alphabet[(value << (5 - bits)) & 0x1F])
    }
    return out
}
