import Darwin
import Foundation
import LocalAuthentication
@preconcurrency import Security

enum ProcessKeychainLock {
    nonisolated static let value = NSRecursiveLock()
}

/// Applies both macOS controls required to make a Security query fail closed instead of
/// presenting an authentication or ACL dialog from a background path.
enum KeychainNoUIQuery {
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // `interactionNotAllowed` alone can still surface Allow/Deny dialogs on macOS.
        // Resolve the deprecated constant at runtime so the explicit fail policy stays
        // available without a compiler warning.
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    static func uiFailPolicyForTesting() -> String {
        uiFailPolicy
    }

    private static func resolveUIFailPolicy() -> String {
        guard let handle = dlopen(securityFrameworkPath, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        let value = symbol.assumingMemoryBound(to: CFString?.self).pointee
        return (value as String?) ?? "u_AuthUIF"
    }
}

/// Keeps test processes away from the user's login Keychain. A package or app test must
/// never read, rotate, or prompt for a real credential; every Security call answers as if
/// the Keychain were empty.
enum KeychainTestSafety {
    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        isXCTestLoaded
            || processName == "xctest"
            || processName.hasSuffix(".xctest")
            || processName == "swiftpm-testing-helper"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }

    static let isBlocking = shouldBlockRealKeychainAccess()
}

enum KeychainSecurityCall {
    /// Serializes Security calls and short-circuits them inside test processes.
    static func perform(_ operation: () -> OSStatus) -> OSStatus {
        guard !KeychainTestSafety.isBlocking else { return errSecItemNotFound }
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        return operation()
    }
}

/// Secret-data queries can still trigger a legacy login-keychain ACL dialog even when
/// authentication UI is disabled on the query. Inspect the item's decrypt ACL without
/// requesting its payload first, and read only when the running executable is already
/// trusted.
enum KeychainAccessPreflight {
    enum Outcome: Equatable {
        case allowed(account: String?)
        case interactionRequired
        case notFound
        case failure(OSStatus)
    }

    static func checkGenericPassword(service: String, account: String?) -> Outcome {
        guard !KeychainTestSafety.isBlocking else { return .notFound }
        // The ACL inspection below uses legacy file-keychain APIs that ignore the query's
        // no-UI controls (for example, a locked keychain would ask to be unlocked), so
        // the whole preflight runs with process-wide user interaction disabled.
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }

        var keychainStatus = SecKeychainStatus()
        if SecKeychainGetStatus(nil, &keychainStatus) == errSecSuccess,
           keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) == 0 {
            return .interactionRequired
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query(service: service, account: account) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                  let reference = attributes[kSecValueRef as String] else {
                return .interactionRequired
            }
            let item = unsafeDowncast(reference as AnyObject, to: SecKeychainItem.self)
            guard decryptACLAllowsCurrentExecutable(item: item) else { return .interactionRequired }
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

    /// An ACL entry without an application list trusts every application; otherwise one
    /// of its trusted applications must validate against the running executable. Any
    /// prompt selector means macOS would ask before decrypting.
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
           FileManager.default.fileExists(atPath: executablePath) else { return false }

        var access: SecAccess?
        guard copyItemAccess(item, &access) == errSecSuccess,
              let access,
              let rawACLs = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawACLs as? [SecACL],
              !acls.isEmpty else { return false }

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
            guard let trustedApplications = applications as? [SecTrustedApplication] else { continue }
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

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? =
        dlopen(securityFrameworkPath, RTLD_NOW)

    private static func securityFunction<T>(named name: String, as _: T.Type) -> T? {
        guard let securityFrameworkHandle,
              let symbol = dlsym(securityFrameworkHandle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private let securityFrameworkPath = "/System/Library/Frameworks/Security.framework/Security"
