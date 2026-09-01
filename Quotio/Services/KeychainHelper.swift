//
//  KeychainHelper.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Keychain helper for secure credential storage
//

import Foundation
import Darwin
import LocalAuthentication
import Security

/// Applies both macOS controls required to make a Security query fail closed
/// instead of presenting an authentication/ACL dialog from a background path.
nonisolated enum KeychainNoUIQuery {
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // `interactionNotAllowed` alone can still surface Allow/Deny dialogs on
        // macOS. Resolve the deprecated Security constant at runtime so the
        // explicit fail policy remains available without a compiler warning.
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    static func uiFailPolicyForTesting() -> String {
        uiFailPolicy
    }

    private static func resolveUIFailPolicy() -> String {
        let securityFramework = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityFramework, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let value = symbol.assumingMemoryBound(to: CFString?.self).pointee
        return (value as String?) ?? "u_AuthUIF"
    }
}

/// Secret-data queries can still trigger a legacy login-keychain ACL dialog on
/// macOS even when authentication UI is disabled on the query. Inspect the
/// item's decrypt ACL without requesting its payload first, then read only when
/// the current executable is already trusted.
nonisolated enum KeychainAccessPreflight {
    enum Outcome {
        case allowed(account: String?)
        case interactionRequired
        case notFound
        case failure(OSStatus)
    }

    static func checkGenericPassword(service: String, account: String?) -> Outcome {
        var result: AnyObject?
        let status = KeychainHelper.performSecurityCall {
            SecItemCopyMatching(
                query(service: service, account: account) as CFDictionary,
                &result
            )
        }
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                  let reference = attributes[kSecValueRef as String]
            else { return .interactionRequired }
            let item = unsafeDowncast(reference as AnyObject, to: SecKeychainItem.self)
            guard decryptACLAllowsCurrentExecutable(item: item) else {
                return .interactionRequired
            }
            return .allowed(account: attributes[kSecAttrAccount as String] as? String)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    static func decryptACLAllowsCurrentExecutable(
        trustedApplicationValidationResults: [Bool]?,
        promptSelector: SecKeychainPromptSelector
    ) -> Bool {
        guard promptSelector.rawValue == 0 else { return false }
        guard let trustedApplicationValidationResults else { return true }
        return trustedApplicationValidationResults.contains(true)
    }

    private static func decryptACLAllowsCurrentExecutable(item: SecKeychainItem) -> Bool {
        guard let copyItemAccess = securityFunction(
            named: "SecKeychainItemCopyAccess",
            as: SecKeychainItemCopyAccessFunction.self
        ), let copyMatchingACLs = securityFunction(
            named: "SecAccessCopyMatchingACLList",
            as: SecAccessCopyMatchingACLListFunction.self
        ), let copyACLContents = securityFunction(
            named: "SecACLCopyContents",
            as: SecACLCopyContentsFunction.self
        ), let executablePath = Bundle.main.executableURL?.path,
           FileManager.default.fileExists(atPath: executablePath)
        else { return false }

        var access: SecAccess?
        guard copyItemAccess(item, &access) == errSecSuccess,
              let access,
              let rawACLs = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawACLs as? [SecACL],
              !acls.isEmpty
        else { return false }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyACLContents(acl, &applications, &description, &selector) == errSecSuccess else {
                continue
            }
            guard let applications else {
                if decryptACLAllowsCurrentExecutable(
                    trustedApplicationValidationResults: nil,
                    promptSelector: selector
                ) {
                    return true
                }
                continue
            }
            guard let trustedApplications = applications as? [SecTrustedApplication] else {
                continue
            }
            let validationResults = trustedApplications.map {
                trustedApplication($0, validatesExecutableAt: executablePath)
            }
            if decryptACLAllowsCurrentExecutable(
                trustedApplicationValidationResults: validationResults,
                promptSelector: selector
            ) {
                return true
            }
        }
        return false
    }

    private static func trustedApplication(
        _ application: SecTrustedApplication,
        validatesExecutableAt path: String
    ) -> Bool {
        guard let validate = securityFunction(
            named: "SecTrustedApplicationValidateWithPath",
            as: SecTrustedApplicationValidateWithPathFunction.self
        ) else { return false }
        return path.withCString { validate(application, $0) == errSecSuccess }
    }

    private typealias SecKeychainItemCopyAccessFunction = @convention(c) (
        SecKeychainItem,
        UnsafeMutablePointer<SecAccess?>
    ) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFunction = @convention(c) (
        SecAccess,
        CFTypeRef
    ) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFunction = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>,
        UnsafeMutablePointer<CFString?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>
    ) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFunction = @convention(c) (
        SecTrustedApplication,
        UnsafePointer<CChar>
    ) -> OSStatus

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW
    )

    private static func securityFunction<T>(named name: String, as _: T.Type) -> T? {
        guard let securityFrameworkHandle,
              let symbol = dlsym(securityFrameworkHandle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

nonisolated enum KeychainTestSafety {
    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        processName.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    nonisolated enum MonitorCredentialBackend: Equatable {
        case keychain
        case vault
    }

    nonisolated enum LocalManagementKeyReadResult: Equatable {
        case success(String)
        case absent
        case unavailable
    }

    nonisolated private enum DataReadResult {
        case success(Data)
        case absent
        case unavailable
    }

    nonisolated private static let securityLock = NSRecursiveLock()
    nonisolated private static var localService: String {
        AppIdentity.keychainService(suffix: "local-management")
    }
    nonisolated private static var warpService: String {
        AppIdentity.keychainService(suffix: "warp")
    }
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"
    nonisolated private static var monitorAuthService: String {
        AppIdentity.keychainService(suffix: "monitor-auth")
    }

    // Legacy service names for keychain migration (newest first)
    nonisolated private static var legacyLocalServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "local-management")
    }
    nonisolated private static var legacyWarpServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "warp")
    }
    nonisolated private static var legacyMonitorAuthServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "monitor-auth")
    }

    static func saveLocalManagementKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let saved = saveData(data, service: localService, account: localManagementAccount)
        if !saved {
            Log.keychain("Failed to save local management key")
        }
        return saved
    }

    static func getLocalManagementKey() -> String? {
        guard case let .success(key) = getLocalManagementKeyResult() else {
            return nil
        }
        return key
    }

    static func getLocalManagementKeyResult() -> LocalManagementKeyReadResult {
        switch readDataResult(service: localService, account: localManagementAccount) {
        case let .success(data):
            guard let key = String(data: data, encoding: .utf8) else { return .unavailable }
            return .success(key)
        case .unavailable:
            return .unavailable
        case .absent:
            break
        }

        // Migrate from legacy keychain service name
        if AppIdentity.isProduction,
           let legacyKey = migrateString(from: legacyLocalServices, to: localService, account: localManagementAccount) {
            return .success(legacyKey)
        }

        guard let legacyKey = UserDefaults.standard.string(forKey: localManagementDefaultsKey),
              !legacyKey.hasPrefix("$2a$") else {
            return .absent
        }

        if saveLocalManagementKey(legacyKey) {
            UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
        }

        return .success(legacyKey)
    }

    static func deleteLocalManagementKey() {
        deleteData(service: localService, account: localManagementAccount)
        if AppIdentity.isProduction {
            for legacy in legacyLocalServices {
                deleteData(service: legacy, account: localManagementAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
    }

    static func saveWarpTokens(_ data: Data) -> Bool {
        let saved = saveData(data, service: warpService, account: warpTokensAccount)
        if !saved {
            Log.keychain("Failed to save Warp tokens")
        }
        return saved
    }

    static func getWarpTokens() -> Data? {
        if let data = readData(service: warpService, account: warpTokensAccount) {
            return data
        }

        if AppIdentity.isProduction,
           let legacyData = migrateData(from: legacyWarpServices, to: warpService, account: warpTokensAccount) {
            return legacyData
        }

        guard let legacyData = UserDefaults.standard.data(forKey: warpTokensDefaultsKey) else {
            return nil
        }

        if saveWarpTokens(legacyData) {
            UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
        }

        return legacyData
    }

    static func deleteWarpTokens() {
        deleteData(service: warpService, account: warpTokensAccount)
        if AppIdentity.isProduction {
            for legacy in legacyWarpServices {
                deleteData(service: legacy, account: warpTokensAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }

    // MARK: - Monitor-only credentials

    nonisolated static func saveMonitorCredential(_ data: Data, account: String) -> Bool {
        saveData(data, service: monitorAuthService, account: account)
    }

    /// Save a Quotio-owned credential from an explicit foreground action such
    /// as OAuth completion or API-key entry. Background refreshes must continue
    /// to use `saveMonitorCredential`, which never presents authentication UI.
    nonisolated static func saveMonitorCredentialUserInitiated(_ data: Data, account: String) -> Bool {
        saveData(
            data,
            service: monitorAuthService,
            account: account,
            allowAuthenticationUI: true
        )
    }

    /// How a stored Quotio-owned credential answered a read attempt.
    ///
    /// `unreadable` is deliberately distinct from `absent`: the Keychain item is
    /// still there, but its ACL names a code identity the running executable no
    /// longer matches (every local rebuild changes the ad-hoc signature), so the
    /// prompt-free read path fails closed. Callers must surface that instead of
    /// treating the account as signed out, otherwise it silently drops out of
    /// every quota surface while staying in the tracked account list.
    nonisolated enum MonitorCredentialRead: Equatable, Sendable {
        case success(Data)
        case absent
        case unreadable
    }

    nonisolated static func readMonitorCredential(account: String) -> MonitorCredentialRead {
        switch readDataResult(service: monitorAuthService, account: account) {
        case let .success(data):
            return .success(data)
        case .absent:
            guard let migrated = migratedMonitorCredential(account: account) else { return .absent }
            return .success(migrated)
        case .unavailable:
            guard let migrated = migratedMonitorCredential(account: account) else { return .unreadable }
            return .success(migrated)
        }
    }

    /// Read an existing Monitor credential after the user explicitly asked to
    /// refresh that account. Unlike background reads, this path may present the
    /// macOS Keychain authorization UI so an ad-hoc development build can regain
    /// access without forcing the user through OAuth again.
    nonisolated static func readMonitorCredentialUserInitiated(account: String) -> MonitorCredentialRead {
        let result = YubiKeySecretVault.isEnabled
            ? readDataResult(service: monitorAuthService, account: account)
            : readKeychainDataResultUserInitiated(service: monitorAuthService, account: account)
        switch result {
        case let .success(data):
            return .success(data)
        case .absent:
            guard let migrated = migratedMonitorCredential(account: account) else { return .absent }
            return .success(migrated)
        case .unavailable:
            return .unreadable
        }
    }

    nonisolated private static func migratedMonitorCredential(account: String) -> Data? {
        guard AppIdentity.isProduction else { return nil }
        return migrateData(from: legacyMonitorAuthServices, to: monitorAuthService, account: account)
    }

    nonisolated static func getMonitorCredential(account: String) -> Data? {
        guard case let .success(data) = readMonitorCredential(account: account) else { return nil }
        return data
    }

    nonisolated static func deleteMonitorCredential(account: String) {
        deleteData(service: monitorAuthService, account: account)
        if AppIdentity.isProduction {
            for legacy in legacyMonitorAuthServices {
                deleteData(service: legacy, account: account)
            }
        }
    }

    nonisolated static func compareAndSwapMonitorCredential(
        _ data: Data,
        account: String,
        expectedFingerprint: String
    ) -> Bool {
        guard let current = getMonitorCredential(account: account),
              MonitorIdentity.fingerprint(current.base64EncodedString()) == expectedFingerprint else {
            return false
        }
        if monitorCredentialBackend(vaultEnabled: YubiKeySecretVault.isEnabled) == .vault {
            return YubiKeySecretVault.save(data, service: monitorAuthService, account: account)
        }
        let query = keychainUpdateQuery(
            service: monitorAuthService,
            account: account
        )
        return performSecurityCall {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } == errSecSuccess
    }

    nonisolated static func monitorCredentialBackend(vaultEnabled: Bool) -> MonitorCredentialBackend {
        vaultEnabled ? .vault : .keychain
    }

    /// Read a credential owned by another local CLI/app without mutating it.
    nonisolated static func readExternalCredential(service: String, account: String? = nil) -> Data? {
        readExternalCredentialRecord(service: service, account: account)?.data
    }

    nonisolated static func readExternalCredentialRecord(
        service: String,
        account: String? = nil
    ) -> (data: Data, account: String)? {
        let resolvedAccount: String?
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case let .allowed(account):
            resolvedAccount = account
        case .interactionRequired, .notFound, .failure:
            return nil
        }
        let query = externalCredentialQuery(
            service: service,
            account: resolvedAccount ?? account
        )

        var result: AnyObject?
        let status = performSecurityCall {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecSuccess,
           let item = result as? [String: Any],
           let data = item[kSecValueData as String] as? Data,
           let resolvedAccount = item[kSecAttrAccount as String] as? String {
            return (data, resolvedAccount)
        }
        if status != errSecItemNotFound && status != errSecInteractionNotAllowed && status != errSecAuthFailed {
            Log.keychain("External keychain read failed (service: \(service)): \(status)")
        }
        return nil
    }

    nonisolated static func externalCredentialQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    /// App-owned credential reads run during startup and refresh. They must
    /// never interrupt those background paths with a macOS authorization UI.
    nonisolated static func keychainReadQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    /// Foreground account refreshes deliberately omit the no-UI controls. This
    /// query must only be used in direct response to an explicit user action.
    nonisolated static func keychainUserInitiatedReadQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Update a known writable credential source after an OAuth refresh.
    nonisolated static func writeExternalCredential(_ data: Data, service: String, account: String) -> Bool {
        saveData(data, service: service, account: account)
    }

    nonisolated static func compareAndSwapExternalCredential(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) -> Bool {
        guard readExternalCredentialRecord(service: service, account: account)?.data == expectedData else {
            return false
        }
        let query = externalCredentialUpdateQuery(service: service, account: account)
        let status = performSecurityCall {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: newData] as CFDictionary
            )
        }
        return status == errSecSuccess
    }

    nonisolated static func externalCredentialUpdateQuery(service: String, account: String) -> [String: Any] {
        keychainUpdateQuery(service: service, account: account)
    }

    nonisolated static func keychainUpdateQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    /// User-initiated updates deliberately omit the no-UI controls. Security
    /// defaults to allowing authentication UI when those controls are absent,
    /// so macOS can ask the user to trust the current Quotio build exactly at
    /// the point where they chose to save a credential.
    nonisolated static func keychainUserInitiatedUpdateQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    nonisolated private static func migrateData(from oldServices: [String], to newService: String, account: String) -> Data? {
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            if saveData(data, service: newService, account: account) {
                deleteData(service: oldService, account: account)
            }
            return data
        }
        return nil
    }

    nonisolated private static func migrateString(from oldServices: [String], to newService: String, account: String) -> String? {
        // Non-destructive read: validate UTF-8 before committing the destructive migration
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            guard let decoded = String(data: data, encoding: .utf8) else { continue }
            _ = migrateData(from: [oldService], to: newService, account: account)
            return decoded
        }
        return nil
    }


    nonisolated private static func saveData(
        _ data: Data,
        service: String,
        account: String,
        allowAuthenticationUI: Bool = false
    ) -> Bool {
        if YubiKeySecretVault.isEnabled {
            let existing = YubiKeySecretVault.readResult(service: service, account: account)
            guard allowsVaultOverwrite(existing) else {
                Log.keychain("Refusing to overwrite unreadable vault envelope (service: \(service), account: \(account))")
                return false
            }
            return YubiKeySecretVault.save(data, service: service, account: account)
        }
        return saveKeychainData(
            data,
            service: service,
            account: account,
            allowAuthenticationUI: allowAuthenticationUI
        )
    }

    /// Whether a vault write may proceed over whatever is already stored.
    ///
    /// A caller that could not read a secret cannot tell "absent" from "hardware
    /// key unavailable", so it may regenerate one and store it -- destroying the
    /// envelope that still holds the real value. `CLIProxyManager` does exactly
    /// this at construction. Refuse rather than roll a live credential back.
    /// `.absent` costs only a file-existence check, so first writes stay
    /// prompt-free; only an overwrite pays for a decrypt.
    nonisolated static func allowsVaultOverwrite(_ existing: YubiKeySecretVault.ReadResult) -> Bool {
        if case .unreadable = existing { return false }
        return true
    }

    nonisolated private static func saveKeychainData(
        _ data: Data,
        service: String,
        account: String,
        allowAuthenticationUI: Bool
    ) -> Bool {
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case .allowed:
            let identity = keychainUpdateQuery(service: service, account: account)
            let updateStatus = performSecurityCall {
                SecItemUpdate(
                    identity as CFDictionary,
                    [
                        kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    ] as CFDictionary
                )
            }
            if updateStatus == errSecSuccess { return true }
            Log.keychain("Keychain update failed (service: \(service), account: \(account)): \(updateStatus)")
            return false
        case .interactionRequired:
            guard allowAuthenticationUI else { return false }
            // The stored item's ACL names a code identity this executable no longer
            // matches, so `SecItemUpdate` would leave that ACL in place and write a
            // credential the app can never read back: the user re-authenticates, sees
            // no error, and the account still reports no quota. Drop the item so the
            // add below rebuilds the ACL around the running executable. Losing the
            // previous payload costs nothing — it was already unreadable, and the
            // replacement value is in hand.
            let deleteStatus = performSecurityCall {
                SecItemDelete(
                    keychainUserInitiatedUpdateQuery(service: service, account: account) as CFDictionary
                )
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                Log.keychain("Keychain replace failed (service: \(service), account: \(account)): \(deleteStatus)")
                return false
            }
        case let .failure(status):
            Log.keychain("Keychain preflight failed (service: \(service), account: \(account)): \(status)")
            return false
        case .notFound:
            break
        }

        // Authentication controls are query-only. Build a clean add request for an
        // item that is genuinely new — either the preflight reported it absent, or
        // the user-initiated path above removed an item bound to a stale identity.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = performSecurityCall {
            SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            return true
        }

        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(status)")
        return false
    }

    nonisolated private static func readData(service: String, account: String) -> Data? {
        guard case let .success(data) = readDataResult(service: service, account: account) else {
            return nil
        }
        return data
    }

    nonisolated private static func readDataResult(service: String, account: String) -> DataReadResult {
        if YubiKeySecretVault.isEnabled {
            let result = YubiKeySecretVault.readResult(service: service, account: account)
            if case let .success(data) = result { return .success(data) }
            // Only an absent envelope may be filled from a legacy Keychain copy.
            // An unreadable one means the hardware key is unavailable or the
            // envelope is bad, and overwriting it would roll the credential back.
            guard YubiKeySecretVault.shouldMigrateLegacy(result) else { return .unavailable }
            // Move a legacy secret only after a complete encrypted write/read
            // round trip has succeeded.
            let legacyResult = readKeychainDataResult(service: service, account: account)
            guard case let .success(legacy) = legacyResult else { return legacyResult }
            guard YubiKeySecretVault.save(legacy, service: service, account: account),
                  case let .success(roundTripped) = YubiKeySecretVault.readResult(service: service, account: account),
                  roundTripped == legacy else { return .unavailable }
            deleteKeychainData(service: service, account: account)
            return .success(legacy)
        }
        return readKeychainDataResult(service: service, account: account)
    }

    nonisolated private static func readKeychainData(service: String, account: String) -> Data? {
        guard case let .success(data) = readKeychainDataResult(service: service, account: account) else {
            return nil
        }
        return data
    }

    nonisolated private static func readKeychainDataResult(service: String, account: String) -> DataReadResult {
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case .allowed:
            break
        case .notFound:
            return .absent
        case .interactionRequired, .failure:
            return .unavailable
        }
        let query = keychainReadQuery(service: service, account: account)

        var result: AnyObject?
        let status = performSecurityCall {
            SecItemCopyMatching(query as CFDictionary, &result)
        }

        if status == errSecSuccess {
            guard let data = result as? Data else { return .unavailable }
            return .success(data)
        }

        if status == errSecItemNotFound {
            return .absent
        }

        if status != errSecInteractionNotAllowed && status != errSecAuthFailed {
            Log.keychain("Keychain read failed (service: \(service), account: \(account)): \(status)")
        }

        return .unavailable
    }

    nonisolated private static func readKeychainDataResultUserInitiated(
        service: String,
        account: String
    ) -> DataReadResult {
        let query = keychainUserInitiatedReadQuery(service: service, account: account)
        var result: AnyObject?
        let status = performSecurityCall {
            SecItemCopyMatching(query as CFDictionary, &result)
        }

        if status == errSecSuccess {
            guard let data = result as? Data else { return .unavailable }
            return .success(data)
        }
        if status == errSecItemNotFound {
            return .absent
        }
        if status != errSecInteractionNotAllowed
            && status != errSecAuthFailed
            && status != errSecUserCanceled {
            Log.keychain("User-initiated Keychain read failed (service: \(service), account: \(account)): \(status)")
        }
        return .unavailable
    }

    private static func readString(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteData(service: String, account: String) {
        if YubiKeySecretVault.isEnabled {
            YubiKeySecretVault.delete(service: service, account: account)
        }
        deleteKeychainData(service: service, account: account)
    }

    nonisolated private static func deleteKeychainData(service: String, account: String) {
        guard case .allowed = KeychainAccessPreflight.checkGenericPassword(
            service: service,
            account: account
        ) else { return }
        let query = keychainUpdateQuery(service: service, account: account)

        let status = performSecurityCall {
            SecItemDelete(query as CFDictionary)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain("Keychain delete failed (service: \(service), account: \(account)): \(status)")
        }
    }

    nonisolated static func performSecurityCall(
        _ operation: () -> OSStatus
    ) -> OSStatus {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        securityLock.lock()
        defer { securityLock.unlock() }
        return operation()
    }
}
