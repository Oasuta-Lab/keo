import Foundation
import Security

enum Keychain {
    /// Derived rather than written out: a hardcoded service silently orphans every stored
    /// token the day the bundle identifier changes.
    private static let service = Bundle.main.bundleIdentifier ?? "keo"

    /// `Synchronizable` belongs to the item's primary key, so a query that omits it only ever
    /// sees local items, and one that pins it to `true` only ever sees synced ones. `Any` is
    /// the single query that finds the token whichever nature it has — which is what keeps the
    /// migration below invisible to every caller.
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    /// Writes the synchronizable item, then drops the local one — never the other way round.
    /// There is no way to ask iOS whether iCloud Keychain is on, so an add that fails must cost
    /// nothing: the old token stays readable and the next launch retries.
    static func set(_ value: String, account: String) {
        var item = query(account)
        item[kSecAttrSynchronizable as String] = true

        // Not a `…ThisDeviceOnly` class: those refuse to sync, and refuse in silence.
        // `AfterFirstUnlock` is the strictest class that still syncs, and it is what a download
        // resumed in the background after a reboot needs.
        let payload: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]

        // Update in place rather than delete-then-add: a delete that succeeds followed by an
        // add that fails would destroy the one copy of the token that travels through iCloud.
        var status = SecItemUpdate(item as CFDictionary, payload as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(payload) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return }

        var local = query(account)
        local[kSecAttrSynchronizable as String] = false
        SecItemDelete(local as CFDictionary)
    }

    static func get(account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecReturnAttributes as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }

        // Migration of a token paired before Keo knew how to share it. An item cannot be turned
        // synchronizable in place, so it is rewritten — on the read path, the one place every
        // caller already goes through. Idempotent: an already synchronizable token is left alone.
        if found[kSecAttrSynchronizable as String] as? Bool != true { set(value, account: account) }
        return value
    }

    /// Both natures, or the token the owner just disconnected comes back from iCloud.
    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
