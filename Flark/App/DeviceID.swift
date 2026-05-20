import Foundation

/// Per-installation device identifier. Distinct from `DeviceIdentity.authorID`
/// (which is derived from the iCloud-Keychain-synced Ed25519 public key and is
/// therefore the SAME across all the user's devices). `deviceID` is generated
/// at first launch and stored in plain UserDefaults — never synced — so each
/// physical install of the app gets a unique value. The WebDAV event log is
/// laid out as `events/<authorID>/<deviceID>/...`, which makes one device's
/// writes lock-free regardless of how many other devices share the identity.
enum DeviceID {
    private static let key = "flark.deviceID"

    static var current: String {
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
