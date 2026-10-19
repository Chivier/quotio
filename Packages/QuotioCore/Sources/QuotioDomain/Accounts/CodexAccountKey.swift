import CryptoKit
import Foundation

/// Codex exposes both a user-facing email and a ChatGPT account (workspace) ID. One
/// email can belong to several ChatGPT workspaces, so keying quota rows or owned
/// credentials by the email alone silently collapses distinct accounts.
///
/// The key format (`email • <first 8 hex of SHA-256(account ID)>`) is shared with
/// earlier Quotio builds; changing it would orphan persisted snapshots and markers.
public enum CodexAccountKey {
    public static let separator = " • "

    public static func canonical(
        email: String?,
        accountID: String?,
        aliases: [String: String] = [:],
        fallback: String
    ) -> String {
        let normalizedAccountID = nonBlank(accountID)
        if let normalizedAccountID, let alias = nonBlank(aliases[normalizedAccountID]) {
            return alias
        }
        let base = nonBlank(email) ?? fallback
        guard let normalizedAccountID else { return base }
        return base + separator + fingerprint(normalizedAccountID)
    }

    /// The short, non-reversible workspace marker used in canonical keys.
    public static func fingerprint(_ accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(8))
    }

    public static func keysMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func hasFingerprintSuffix(_ accountKey: String) -> Bool {
        guard let delimiter = accountKey.range(of: separator, options: .backwards) else {
            return false
        }
        let suffix = accountKey[delimiter.upperBound...]
        return suffix.count == 8 && suffix.allSatisfy(\.isHexDigit)
    }

    /// Whether a requested quota key may name a Quotio-owned account before its
    /// credential is decoded.
    ///
    /// Older metadata used only the email while snapshots may already carry the
    /// fingerprinted key. A metadata key that already carries a fingerprint names
    /// exactly one workspace, so its plain email and sibling fingerprints stay
    /// available to their own credential sources.
    public static func mayIdentifyStoredAccount(
        _ requestedKey: String,
        metadataKey: String,
        displayName: String
    ) -> Bool {
        if keysMatch(requestedKey, metadataKey) { return true }
        if hasFingerprintSuffix(metadataKey) { return false }
        if keysMatch(requestedKey, displayName) { return true }
        let requested = requestedKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for base in [metadataKey, displayName] {
            let prefix = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + separator
            guard requested.hasPrefix(prefix) else { continue }
            let suffix = requested.dropFirst(prefix.count)
            if suffix.count == 8, suffix.allSatisfy(\.isHexDigit) { return true }
        }
        return false
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
