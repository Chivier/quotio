import Foundation

/// One identity contract for native Kiro credentials, CLIProxyAPI auth files, and the
/// keys older builds wrote for them.
///
/// A profile ARN names exactly one Kiro profile. A login provider (`Google`, `GitHub`)
/// is not an identity at all, so the synthetic `Kiro (Google)` key older builds used
/// survives only as a migration alias for the very same file.
public enum KiroAccountIdentity {
    public static func canonicalKey(email: String?, profileARN: String?, filename: String) -> String {
        nonBlank(profileARN) ?? nonBlank(email) ?? stem(filename)
    }

    /// Keys earlier builds may have used for the same credential, excluding the
    /// canonical key itself.
    public static func legacyKeys(
        email: String?,
        profileARN: String?,
        filename: String,
        loginProvider: String?,
        isNativeCredential: Bool
    ) -> Set<String> {
        var keys: Set<String> = [stem(filename)]
        if let email = nonBlank(email) { keys.insert(email) }
        if let profile = nonBlank(profileARN) { keys.insert(profile) }
        if nonBlank(email) == nil, let provider = nonBlank(loginProvider) {
            keys.insert("Kiro (\(provider))")
        }
        if isNativeCredential, nonBlank(email) == nil, nonBlank(profileARN) == nil {
            keys.insert("Kiro")
        }
        keys.remove(canonicalKey(email: email, profileARN: profileARN, filename: filename))
        return keys
    }

    private static func stem(_ filename: String) -> String {
        filename.hasSuffix(".json") ? String(filename.dropLast(".json".count)) : filename
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
