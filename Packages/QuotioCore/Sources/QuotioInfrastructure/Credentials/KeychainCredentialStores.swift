import CryptoKit
import Foundation
import LocalAuthentication
import QuotioApplication
@preconcurrency import Security

public enum ProtectedCredentialReadResult: Equatable, Sendable {
    case absent
    case unreadable
    case success(Data)
}

public protocol ProtectedCredentialDataStoring: Sendable {
    var isEnabled: Bool { get async }
    func read(service: String, account: String) async -> ProtectedCredentialReadResult
    func save(_ data: Data, service: String, account: String) async -> Bool
    func delete(service: String, account: String) async
}

public actor KeychainCredentialDataStore: CredentialDataStoring {
    enum PlainReadResult: Equatable {
        case success(Data)
        case absent
        case unreadable
    }

    private let service: String
    private let legacyServices: [String]
    private let canMigrateLegacy: Bool
    private let protectedStore: (any ProtectedCredentialDataStoring)?

    public init(
        service: String,
        legacyServices: [String] = [],
        canMigrateLegacy: Bool,
        protectedStore: (any ProtectedCredentialDataStoring)? = nil
    ) {
        self.service = service
        self.legacyServices = legacyServices
        self.canMigrateLegacy = canMigrateLegacy
        self.protectedStore = protectedStore
    }

    public var backend: CredentialStorageBackend {
        get async {
            if let protectedStore, await protectedStore.isEnabled { return .protectedVault }
            return .keychain
        }
    }

    public func read(accountID: String) async -> CredentialDataRecord? {
        guard case .success(let record) = await readResult(accountID: accountID) else { return nil }
        return record
    }

    public func readResult(accountID: String) async -> CredentialReadResult {
        Self.record(for: await readData(accountID: accountID))
    }

    public func readUserInitiated(accountID: String) async -> CredentialReadResult {
        if let protectedStore, await protectedStore.isEnabled {
            return await readResult(accountID: accountID)
        }
        switch Self.readKeychainDataUserInitiated(service: service, account: accountID) {
        case .success(let data):
            return Self.record(for: .success(data))
        case .unreadable:
            return .unreadable
        case .absent:
            // Legacy copies still go through the prompt-free migration path.
            return await readResult(accountID: accountID)
        }
    }

    public func save(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        await save(data, accountID: accountID, allowAuthenticationUI: false)
    }

    public func saveUserInitiated(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        await save(data, accountID: accountID, allowAuthenticationUI: true)
    }

    public func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) async -> CredentialDataRecord? {
        guard case .success(let current) = await readData(accountID: accountID),
              Self.generation(for: current) == expectedGeneration else { return nil }
        let didSave: Bool
        if let protectedStore, await protectedStore.isEnabled {
            didSave = await protectedStore.save(data, service: service, account: accountID)
        } else {
            didSave = Self.updateKeychainData(data, service: service, account: accountID)
        }
        guard didSave else { return nil }
        return CredentialDataRecord(data: data, generation: Self.generation(for: data))
    }

    public func delete(accountID: String) async {
        let enabledProtectedStore: (any ProtectedCredentialDataStoring)?
        if let protectedStore, await protectedStore.isEnabled {
            enabledProtectedStore = protectedStore
            await protectedStore.delete(service: service, account: accountID)
        } else {
            enabledProtectedStore = nil
        }
        Self.deleteKeychainData(service: service, account: accountID)
        if canMigrateLegacy {
            for legacyService in legacyServices {
                if let enabledProtectedStore {
                    await enabledProtectedStore.delete(service: legacyService, account: accountID)
                }
                Self.deleteKeychainData(service: legacyService, account: accountID)
            }
        }
    }

    private func save(
        _ data: Data,
        accountID: String,
        allowAuthenticationUI: Bool
    ) async -> CredentialDataRecord? {
        let didSave: Bool
        if let protectedStore, await protectedStore.isEnabled {
            // An unreadable envelope means the hardware key is missing or the envelope
            // is bad; overwriting it would roll the credential back.
            let existing = await protectedStore.read(service: service, account: accountID)
            guard existing != .unreadable else { return nil }
            didSave = await protectedStore.save(data, service: service, account: accountID)
        } else {
            didSave = Self.saveKeychainData(
                data,
                service: service,
                account: accountID,
                allowAuthenticationUI: allowAuthenticationUI
            )
        }
        guard didSave else { return nil }
        return CredentialDataRecord(data: data, generation: Self.generation(for: data))
    }

    private func readData(accountID: String) async -> PlainReadResult {
        if let protectedStore, await protectedStore.isEnabled {
            let result = await protectedStore.read(service: service, account: accountID)
            if case .success(let data) = result { return .success(data) }
            guard result == .absent else { return .unreadable }

            var sawUnreadablePlaintext = false
            switch Self.readKeychainData(service: service, account: accountID) {
            case .success(let plaintext):
                guard await migrateToProtectedStore(
                    plaintext,
                    accountID: accountID,
                    protectedStore: protectedStore
                ) else { return .unreadable }
                Self.deleteKeychainData(service: service, account: accountID)
                return .success(plaintext)
            case .unreadable:
                sawUnreadablePlaintext = true
            case .absent:
                break
            }

            guard canMigrateLegacy else { return sawUnreadablePlaintext ? .unreadable : .absent }
            for legacyService in legacyServices {
                switch await protectedStore.read(service: legacyService, account: accountID) {
                case .success(let legacyData):
                    guard await migrateToProtectedStore(
                        legacyData,
                        accountID: accountID,
                        protectedStore: protectedStore
                    ) else { return .unreadable }
                    await protectedStore.delete(service: legacyService, account: accountID)
                    Self.deleteKeychainData(service: legacyService, account: accountID)
                    return .success(legacyData)
                case .unreadable:
                    continue
                case .absent:
                    guard case .success(let plaintext) = Self.readKeychainData(
                        service: legacyService,
                        account: accountID
                    ) else { continue }
                    guard await migrateToProtectedStore(
                        plaintext,
                        accountID: accountID,
                        protectedStore: protectedStore
                    ) else { return .unreadable }
                    Self.deleteKeychainData(service: legacyService, account: accountID)
                    return .success(plaintext)
                }
            }
            return sawUnreadablePlaintext ? .unreadable : .absent
        }

        let current = Self.readKeychainData(service: service, account: accountID)
        guard current == .absent, canMigrateLegacy else { return current }
        for legacyService in legacyServices {
            guard case .success(let data) = Self.readKeychainData(
                service: legacyService,
                account: accountID
            ) else { continue }
            if Self.saveKeychainData(
                data,
                service: service,
                account: accountID,
                allowAuthenticationUI: false
            ) {
                Self.deleteKeychainData(service: legacyService, account: accountID)
            }
            return .success(data)
        }
        return .absent
    }

    private func migrateToProtectedStore(
        _ data: Data,
        accountID: String,
        protectedStore: any ProtectedCredentialDataStoring
    ) async -> Bool {
        guard await protectedStore.save(data, service: service, account: accountID),
              case .success(let roundTripped) = await protectedStore.read(
                service: service,
                account: accountID
              ) else { return false }
        return roundTripped == data
    }

    private nonisolated static func record(for result: PlainReadResult) -> CredentialReadResult {
        switch result {
        case .success(let data):
            .success(CredentialDataRecord(data: data, generation: generation(for: data)))
        case .absent:
            .absent
        case .unreadable:
            .unreadable
        }
    }

    private nonisolated static func generation(for data: Data) -> String {
        SHA256.hash(data: Data(data.base64EncodedString().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(20)
            .description
    }

    private nonisolated static func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Background queries carry both no-UI controls so they fail closed.
    nonisolated static func noUIQuery(service: String, account: String) -> [String: Any] {
        var query = identity(service: service, account: account)
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    private nonisolated static func saveKeychainData(
        _ data: Data,
        service: String,
        account: String,
        allowAuthenticationUI: Bool
    ) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case .allowed:
            return KeychainSecurityCall.perform {
                SecItemUpdate(
                    noUIQuery(service: service, account: account) as CFDictionary,
                    attributes as CFDictionary
                )
            } == errSecSuccess
        case .interactionRequired:
            guard allowAuthenticationUI else { return false }
            // The item's ACL names a code identity this executable no longer matches,
            // so updating it would keep that ACL and store a credential this build can
            // never read back. Rebuild the item around the running executable. The old
            // payload was already unreadable and the replacement is in hand.
            let deleteStatus = KeychainSecurityCall.perform {
                SecItemDelete(identity(service: service, account: account) as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return false
            }
        case .failure:
            return false
        case .notFound:
            break
        }

        // Authentication controls are query-only; an add request must be clean.
        var query = identity(service: service, account: account)
        query.merge(attributes) { _, new in new }
        return KeychainSecurityCall.perform {
            SecItemAdd(query as CFDictionary, nil)
        } == errSecSuccess
    }

    private nonisolated static func updateKeychainData(
        _ data: Data,
        service: String,
        account: String
    ) -> Bool {
        KeychainSecurityCall.perform {
            SecItemUpdate(
                noUIQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } == errSecSuccess
    }

    nonisolated static func readKeychainData(service: String, account: String) -> PlainReadResult {
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case .allowed:
            break
        case .notFound:
            return .absent
        case .interactionRequired, .failure:
            return .unreadable
        }
        var query = noUIQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = KeychainSecurityCall.perform {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unreadable }
            return .success(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .unreadable
        }
    }

    /// Deliberately omits the no-UI controls; only a direct user action may use it.
    private nonisolated static func readKeychainDataUserInitiated(
        service: String,
        account: String
    ) -> PlainReadResult {
        var query = identity(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = KeychainSecurityCall.perform {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unreadable }
            return .success(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .unreadable
        }
    }

    private nonisolated static func deleteKeychainData(service: String, account: String) {
        // Deleting an item this build cannot access would ask for authorization.
        guard case .allowed = KeychainAccessPreflight.checkGenericPassword(
            service: service,
            account: account
        ) else { return }
        _ = KeychainSecurityCall.perform {
            SecItemDelete(noUIQuery(service: service, account: account) as CFDictionary)
        }
    }
}

public actor ExternalKeychainCredentialReader: ExternalCredentialReading {
    public init() {}

    public func read(service: String, account: String?) -> ExternalCredentialRecord? {
        // A data query can still raise a legacy ACL dialog for another app's item, so
        // only read items whose decrypt ACL already trusts this executable.
        guard case .allowed(let resolvedAccount) = KeychainAccessPreflight.checkGenericPassword(
            service: service,
            account: account
        ) else { return nil }
        var result: AnyObject?
        let status = Self.performWithoutInteraction {
            SecItemCopyMatching(
                Self.readQuery(service: service, account: resolvedAccount ?? account) as CFDictionary,
                &result
            )
        }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let resolvedAccount = item[kSecAttrAccount as String] as? String else { return nil }
        return ExternalCredentialRecord(data: data, account: resolvedAccount)
    }

    public func compareAndSwap(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) async -> Bool {
        guard read(service: service, account: account)?.data == expectedData else { return false }
        return Self.performWithoutInteraction {
            SecItemUpdate(
                Self.updateQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: newData] as CFDictionary
            )
        } == errSecSuccess
    }

    public nonisolated static func readQuery(
        service: String,
        account: String? = nil
    ) -> [String: Any] {
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

    public nonisolated static func updateQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    private nonisolated static func performWithoutInteraction(
        _ operation: () -> OSStatus
    ) -> OSStatus {
        guard !KeychainTestSafety.isBlocking else { return errSecItemNotFound }
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
