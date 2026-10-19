import Foundation
import QuotioDomain

public protocol AccountDiscovering: Sendable {
    func discoverAccounts() async -> [Account]
}

public enum AccountServiceFailure: Error, Equatable, Sendable {
    case invalidCredential
    case duplicateAccount
    case accountNotFound
    case deletionNotAllowed
}

public protocol AccountManaging: Sendable {
    func accounts() async -> [Account]
    func setDisabled(_ disabled: Bool, accountID: String) async
    func delete(accountID: String) async throws
    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) async throws

    /// Removes an account from Quotio. A Quotio-owned credential is deleted; a credential
    /// owned by another app or CLI is only hidden and stays untouched at its source.
    func remove(accountID: String) async throws
    @discardableResult
    func restoreRemovedAccounts() async -> Int
    func removedAccountCount() async -> Int
    /// Credential state of every Quotio-owned account, keyed by account ID.
    func credentialStates() async -> [String: StoredCredentialState]
    /// Asks macOS for access to an owned credential this build cannot read. Must only be
    /// called in direct response to a user action.
    func restoreCredentialAccess(accountID: String) async -> Bool
}

extension AccountManaging {
    public func remove(accountID: String) async throws {
        try await delete(accountID: accountID)
    }

    @discardableResult
    public func restoreRemovedAccounts() async -> Int { 0 }
    public func removedAccountCount() async -> Int { 0 }
    public func credentialStates() async -> [String: StoredCredentialState] { [:] }
    public func restoreCredentialAccess(accountID: String) async -> Bool { false }
}

public actor AccountService: AccountManaging {
    private let discovery: any AccountDiscovering
    private let metadataRepository: any AccountMetadataRepository
    private let credentialVault: any CredentialVault
    private let reservedLabels: [AccountProviderID: Set<String>]

    public init(
        discovery: any AccountDiscovering,
        metadataRepository: any AccountMetadataRepository,
        credentialVault: any CredentialVault,
        reservedLabels: [AccountProviderID: Set<String>] = [:]
    ) {
        self.discovery = discovery
        self.metadataRepository = metadataRepository
        self.credentialVault = credentialVault
        self.reservedLabels = reservedLabels.mapValues { labels in
            Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        }
    }

    public func accounts() async -> [Account] {
        await discovery.discoverAccounts()
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        try? await metadataRepository.setDisabled(disabled, accountID: accountID)
    }

    public func delete(accountID: String) async throws {
        guard let account = await discovery.discoverAccounts().first(where: { $0.id == accountID }) else {
            throw AccountServiceFailure.accountNotFound
        }
        guard account.canDelete else {
            throw AccountServiceFailure.deletionNotAllowed
        }
        await credentialVault.delete(accountID: accountID)
    }

    public func remove(accountID: String) async throws {
        // A row restored from a quota snapshot may no longer be discoverable; hiding its
        // identity still keeps a later refresh from bringing it back.
        let account = await discovery.discoverAccounts().first { $0.id == accountID }
        if let account, account.canDelete, account.source == .quotioKeychain {
            await credentialVault.delete(accountID: accountID)
        } else {
            try await metadataRepository.setRemoved(true, accountID: accountID)
        }
    }

    @discardableResult
    public func restoreRemovedAccounts() async -> Int {
        (try? await metadataRepository.restoreRemovedAccounts()) ?? 0
    }

    public func removedAccountCount() async -> Int {
        await metadataRepository.removedAccountIDs().count
    }

    public func credentialStates() async -> [String: StoredCredentialState] {
        var states: [String: StoredCredentialState] = [:]
        for account in await credentialVault.accounts() where account.source == .quotioKeychain {
            states[account.id] = await credentialVault.credentialState(for: account.id)
        }
        return states
    }

    public func restoreCredentialAccess(accountID: String) async -> Bool {
        await credentialVault.credentialForUserInitiatedAccess(for: accountID) != nil
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil
    ) async throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              !trimmedKey.isEmpty,
              reservedLabels[providerID]?.contains(trimmedLabel.lowercased()) != true else {
            throw AccountServiceFailure.invalidCredential
        }

        let currentAccounts = await discovery.discoverAccounts()
        let account: Account
        if let existingAccountID {
            guard let existing = currentAccounts.first(where: {
                $0.id == existingAccountID && $0.providerID == providerID
            }) else {
                throw AccountServiceFailure.accountNotFound
            }
            guard !currentAccounts.contains(where: {
                $0.id != existing.id
                    && $0.providerID == providerID
                    && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else {
                throw AccountServiceFailure.duplicateAccount
            }
            account = Account(
                identity: AccountIdentity(
                    id: existing.id,
                    providerID: existing.providerID,
                    accountKey: trimmedLabel
                ),
                displayName: trimmedLabel,
                source: existing.source,
                credentialReference: existing.credentialReference,
                capabilities: existing.capabilities,
                status: existing.status,
                credentialMetadata: RedactedCredentialMetadata(kind: .apiKey)
            )
            _ = await credentialVault.credential(for: existing.id)
        } else {
            guard !currentAccounts.contains(where: {
                $0.providerID == providerID
                    && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else {
                throw AccountServiceFailure.duplicateAccount
            }
            account = Account.make(
                providerID: providerID,
                accountKey: trimmedLabel,
                source: .quotioKeychain,
                credentialReference: "keychain",
                capabilities: [.disable, .delete, .edit],
                credentialMetadata: RedactedCredentialMetadata(kind: .apiKey)
            )
        }

        // Entering a key is an explicit user action: it may rebuild a Keychain item that
        // an older build owns, and it restores an account the user removed earlier.
        try await credentialVault.saveUserInitiated(
            StoredCredential(
                accessToken: trimmedKey,
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: nil,
                extra: [:]
            ),
            metadata: account
        )
    }
}
