import Foundation
import CryptoKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Everything needed to *be* the same user on another device / platform:
/// the private key, the name, and the Spaces (with their WebDAV passwords).
struct PortableIdentity: Codable {
    var v = 1
    var key: String              // base64 raw Curve25519 private key
    var name: String
    var spaces: [SpaceConfig]
    var passwords: [String: String]   // spaceID → WebDAV password
}

/// Passphrase-encrypted export/import (B). The recovery code carries secrets,
/// so it is always sealed with the user's passphrase (HKDF-SHA256 → AES-GCM).
enum IdentityKit {
    private static let prefix = "FLARK1."
    private static let info = Data("flark-identity-v1".utf8)

    private static func key(_ passphrase: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt, info: info, outputByteCount: 32)
    }

    static func export(_ identity: PortableIdentity, passphrase: String) -> String? {
        guard let plain = try? JSONEncoder().encode(identity) else { return nil }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard let sealed = try? AES.GCM.seal(plain, using: key(passphrase, salt: salt)),
              let combined = sealed.combined else { return nil }
        return prefix + (salt + combined).base64EncodedString()
    }

    static func `import`(_ code: String, passphrase: String) -> PortableIdentity? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix),
              let raw = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))),
              raw.count > 16 else { return nil }
        let salt = raw.prefix(16)
        let box = raw.dropFirst(16)
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(sealed, using: key(passphrase, salt: Data(salt))),
              let id = try? JSONDecoder().decode(PortableIdentity.self, from: plain)
        else { return nil }
        return id
    }

    /// Render the recovery code as a QR for scanning with another device.
    static func qrImage(_ text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cg))
        #else
        return Image(nsImage: NSImage(cgImage: cg, size: .init(width: out.extent.width,
                                                               height: out.extent.height)))
        #endif
    }
}
