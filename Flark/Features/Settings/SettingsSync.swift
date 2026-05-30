import Foundation

/// Mirrors a fixed set of non-secret `UserDefaults` settings into a single
/// iCloud-Keychain-synced blob so they follow the user to their other devices —
/// the same transport the model registry already uses (`Keychain.set(sync:true)`),
/// so no iCloud entitlement is required.
///
/// `UserDefaults.standard` stays the local source of truth: `@AppStorage` and the
/// various direct reads (`EmojiPackResolver`, `AIConfig`) are untouched. On launch
/// we `pull()` the blob back into UserDefaults; thereafter any change to a
/// registered key — observed via `UserDefaults.didChangeNotification` — is
/// debounced and `push()`ed back up.
///
/// Limitation: iCloud Keychain has no change notification, so a change made on
/// another device is picked up on the *next launch*, not live mid-session —
/// matching how the model registry already behaves.
///
/// To sync a new setting, add its `UserDefaults` key to `syncedKeys`.
enum SettingsSync {
    /// The non-secret UserDefaults keys that ride iCloud. The model registry and
    /// its provider API keys are already a synced Keychain item of their own, so
    /// they are intentionally not listed here.
    private static let syncedKeys: [String] = [
        AppSettingsKeys.emojiPack,
        AppSettingsKeys.emojiFlightEnabled,
        AISettingsKeys.personas,
        AISettingsKeys.defaultModelOptionID,
    ]

    /// Keychain account for the combined settings blob.
    private static let blobAccount = "flark.settings.sync.v1"

    private static var started = false
    private static var pushWork: DispatchWorkItem?

    /// Call once at launch, before any setting is read. Restores remote values,
    /// then starts mirroring local changes back up.
    static func start() {
        guard !started else { return }
        started = true
        pull()
        // Registered AFTER pull so restoring values doesn't immediately echo
        // them back up. Unrelated defaults churn just reschedules a cheap,
        // debounced snapshot of our own keys.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in schedulePush() }
    }

    /// Restore each registered key present in the synced blob into UserDefaults.
    static func pull() {
        guard let data = Keychain.get(blobAccount),
              let dict = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any]
        else { return }
        for key in syncedKeys where dict[key] != nil {
            UserDefaults.standard.set(dict[key], forKey: key)
        }
    }

    /// Snapshot the registered keys and write them to the synced Keychain blob.
    static func push() {
        var dict: [String: Any] = [:]
        for key in syncedKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                dict[key] = value
            }
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)
        else { return }
        Keychain.set(data, account: blobAccount, sync: true)
    }

    private static func schedulePush() {
        pushWork?.cancel()
        let work = DispatchWorkItem { push() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
