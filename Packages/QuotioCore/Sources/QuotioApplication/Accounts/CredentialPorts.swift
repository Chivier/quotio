import Foundation
import QuotioDomain

public struct StoredCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?
    public var expiresAt: Date?
    public var extra: [String: String]

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountID: String?,
        expiresAt: Date?,
        extra: [String: String]
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.extra = extra
    }

    public var redactedMetadata: RedactedCredentialMetadata {
        RedactedCredentialMetadata(
            kind: refreshToken == nil && idToken == nil ? .apiKey : .oauth,
            expiresAt: expiresAt,
            hasRefreshToken: refreshToken != nil,
            hasAccountIdentifier: accountID != nil
        )
    }
}

public struct CredentialDataRecord: Equatable, Sendable {
    public let data: Data
    public let generation: String

    public init(data: Data, generation: String) {
        self.data = data
        self.generation = generation
    }
}

public struct ExternalCredentialRecord: Equatable, Sendable {
    public let data: Data
    public let account: String

    public init(data: Data, account: String) {
        self.data = data
        self.account = account
    }
}

/// How a stored secret answered a read attempt.
///
/// `unreadable` is deliberately distinct from `absent`: the item still exists, but this
/// executable cannot decrypt it without user interaction (a Keychain ACL bound to another
/// code signature, or a hardware vault whose key is not attached). Treating it as absent
/// silently drops the account from every quota surface while it stays in the account list.
public enum CredentialReadResult: Equatable, Sendable {
    case success(CredentialDataRecord)
    case absent
    case unreadable
}

/// Which secure store currently answers credential reads.
public enum CredentialStorageBackend: Equatable, Sendable {
    /// The login Keychain authorizes per code identity, so a secret decoded once stays
    /// usable for the rest of the run.
    case keychain
    /// The hardware vault requires the key for every use; nothing may be cached.
    case protectedVault
}

public protocol CredentialDataStoring: Sendable {
    func read(accountID: String) async -> CredentialDataRecord?
    func save(_ data: Data, accountID: String) async -> CredentialDataRecord?
    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) async -> CredentialDataRecord?
    func delete(accountID: String) async

    /// Prompt-free read that distinguishes an unreadable item from a missing one.
    func readResult(accountID: String) async -> CredentialReadResult
    /// Read in direct response to a user action; may present a macOS authorization prompt.
    func readUserInitiated(accountID: String) async -> CredentialReadResult
    /// Write in direct response to a user action; may replace an item whose access control
    /// names another code identity, and may present a macOS authorization prompt.
    func saveUserInitiated(_ data: Data, accountID: String) async -> CredentialDataRecord?
    var backend: CredentialStorageBackend { get async }
}

extension CredentialDataStoring {
    public func readResult(accountID: String) async -> CredentialReadResult {
        guard let record = await read(accountID: accountID) else { return .absent }
        return .success(record)
    }

    public func readUserInitiated(accountID: String) async -> CredentialReadResult {
        await readResult(accountID: accountID)
    }

    public func saveUserInitiated(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        await save(data, accountID: accountID)
    }

    public var backend: CredentialStorageBackend {
        get async { .keychain }
    }
}

public protocol ExternalCredentialReading: Sendable {
    func read(service: String, account: String?) async -> ExternalCredentialRecord?
    func compareAndSwap(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) async -> Bool
}

public protocol AccountMetadataRepository: Sendable {
    func accounts() async -> [Account]
    func disabledAccountIDs() async -> Set<String>
    func saveAccount(_ account: Account) async throws
    func deleteAccount(_ accountID: String) async throws
    func setDisabled(_ disabled: Bool, accountID: String) async throws

    /// Accounts the user removed from Quotio. Externally owned credentials are hidden
    /// rather than deleted, so discovery must keep honoring these markers.
    func removedAccountIDs() async -> Set<String>
    func isRemoved(_ accountID: String) async -> Bool
    func setRemoved(_ removed: Bool, accountID: String) async throws
    @discardableResult
    func restoreRemovedAccounts() async throws -> Int
    /// Links account IDs that were proven to name one identity, so markers recorded
    /// under an older key keep applying after the key is canonicalized.
    func reconcileAliases(_ aliasesByIdentity: [String: Set<String>]) async throws
    /// Drops removed accounts, applies disabled markers through aliases, and keeps one
    /// row per canonical identity.
    func filteringAccounts(_ accounts: [Account]) async -> [Account]
    /// Account IDs whose quota must not be shown or persisted.
    func excludedQuotaAccountIDs() async -> Set<String>
}

extension AccountMetadataRepository {
    public func removedAccountIDs() async -> Set<String> { [] }
    public func isRemoved(_ accountID: String) async -> Bool { false }
    public func setRemoved(_ removed: Bool, accountID: String) async throws {}
    @discardableResult
    public func restoreRemovedAccounts() async throws -> Int { 0 }
    public func reconcileAliases(_ aliasesByIdentity: [String: Set<String>]) async throws {}
    public func filteringAccounts(_ accounts: [Account]) async -> [Account] { accounts }
    public func excludedQuotaAccountIDs() async -> Set<String> { await disabledAccountIDs() }
}

/// Whether a Quotio-owned credential is usable, gone, or present-but-unreadable.
public enum StoredCredentialState: Equatable, Sendable {
    case available
    case absent
    case unreadable
}

public protocol CredentialVault: Sendable {
    func accounts() async -> [Account]
    func credential(for accountID: String) async -> StoredCredential?
    func reloadLatest(accountID: String) async -> StoredCredential?
    func save(_ credential: StoredCredential, metadata: Account) async throws
    func delete(accountID: String) async

    /// Read an existing credential in direct response to a foreground user action. Only
    /// this path may present a macOS authorization prompt; background refreshes must
    /// call `credential(for:)`.
    func credentialForUserInitiatedAccess(for accountID: String) async -> StoredCredential?
    /// Persist a credential produced by an explicit user action, such as completing a
    /// login or entering an API key. This is the only write path allowed to prompt.
    func saveUserInitiated(_ credential: StoredCredential, metadata: Account) async throws
    /// Persist a token rotation produced by a user-started refresh. Like
    /// `saveUserInitiated` it may prompt, but it is not a new login: it never restores
    /// an account the user removed while the refresh was in flight.
    func saveRotationUserInitiated(_ credential: StoredCredential, metadata: Account) async throws
    func credentialState(for accountID: String) async -> StoredCredentialState
}

extension CredentialVault {
    public func credentialForUserInitiatedAccess(for accountID: String) async -> StoredCredential? {
        await credential(for: accountID)
    }

    public func saveUserInitiated(_ credential: StoredCredential, metadata: Account) async throws {
        try await save(credential, metadata: metadata)
    }

    public func saveRotationUserInitiated(_ credential: StoredCredential, metadata: Account) async throws {
        try await save(credential, metadata: metadata)
    }

    public func credentialState(for accountID: String) async -> StoredCredentialState {
        await credential(for: accountID) == nil ? .absent : .available
    }
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case writeFailed
    /// The secure store refused a user-initiated write; macOS needs the user to allow
    /// this build to access the item.
    case authorizationRequired
    /// The account was removed while this write was in flight.
    case accountRemoved
}

public actor CredentialVaultService: CredentialVault {
    private let dataStore: any CredentialDataStoring
    private let metadataRepository: any AccountMetadataRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loadedGenerations: [String: String] = [:]
    private var removalGenerations: [String: Int] = [:]
    /// Credentials decoded in this run, in memory only and only while the Keychain is the
    /// backend. A Quotio-owned credential is rewritten through this actor, so re-reading
    /// the secure store on every refresh cannot discover anything new; it only creates
    /// another opportunity for macOS to ask for authorization. Rotation paths read the
    /// persisted bytes explicitly through `reloadLatest`.
    private var sessionCredentials: [String: StoredCredential] = [:]
    /// Rotated credentials that could not be written because the stored item is
    /// unreadable by this build. A single-use refresh token must survive in memory until
    /// the user restores access, at which point it is written through the
    /// user-initiated path.
    private var pendingPersistence: [String: (credential: StoredCredential, account: Account)] = [:]

    public init(
        dataStore: any CredentialDataStoring,
        metadataRepository: any AccountMetadataRepository,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.dataStore = dataStore
        self.metadataRepository = metadataRepository
        self.encoder = encoder
        self.decoder = decoder
    }

    public func accounts() async -> [Account] {
        await metadataRepository.accounts()
    }

    public func credential(for accountID: String) async -> StoredCredential? {
        let backend = await activeBackend()
        if let cached = sessionCredentials[accountID] { return cached }
        return await readPersisted(accountID: accountID, userInitiated: false, backend: backend)
    }

    /// Exists to regain access, so a credential already authorized in this run is reused
    /// instead of asking again, and a rotation that could not be written earlier is
    /// written now.
    public func credentialForUserInitiatedAccess(for accountID: String) async -> StoredCredential? {
        let backend = await activeBackend()
        if let pending = pendingPersistence[accountID] {
            try? await saveRotationUserInitiated(pending.credential, metadata: pending.account)
            return sessionCredentials[accountID] ?? pending.credential
        }
        if let cached = sessionCredentials[accountID] { return cached }
        if let credential = await readPersisted(
            accountID: accountID,
            userInitiated: false,
            backend: backend
        ) {
            return credential
        }
        // Under the hardware vault both paths perform the same decrypt, so retrying
        // would only cost the user a second PIN entry.
        guard backend == .keychain else { return nil }
        guard let credential = await readPersisted(
            accountID: accountID,
            userInitiated: true,
            backend: backend
        ) else { return nil }
        // A one-time "Allow" lasts only for this run. Rebuild the item around the running
        // executable so access survives a relaunch; if that fails, keep the credential
        // in memory and retry on the next restore.
        if let data = try? encoder.encode(credential),
           let saved = await dataStore.saveUserInitiated(data, accountID: accountID) {
            loadedGenerations[accountID] = saved.generation
        } else if let account = await metadataRepository.accounts().first(where: { $0.id == accountID }) {
            pendingPersistence[accountID] = (credential, account)
        }
        return credential
    }

    public func credentialState(for accountID: String) async -> StoredCredentialState {
        _ = await activeBackend()
        if pendingPersistence[accountID] != nil { return .unreadable }
        if sessionCredentials[accountID] != nil { return .available }
        switch await dataStore.readResult(accountID: accountID) {
        case .success: return .available
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }

    /// Always re-reads the stored bytes, so a compare-and-swap rotation swaps against
    /// what is persisted. An unreadable store still answers from the session copy; it
    /// cannot cause a wrong rotation because compare-and-swap re-reads and fails closed.
    public func reloadLatest(accountID: String) async -> StoredCredential? {
        let backend = await activeBackend()
        return await readPersisted(accountID: accountID, userInitiated: false, backend: backend)
    }

    public func save(_ credential: StoredCredential, metadata account: Account) async throws {
        let backend = await activeBackend()
        let generation = removalGenerations[account.id, default: 0]
        guard await !metadataRepository.isRemoved(account.id),
              generation == removalGenerations[account.id, default: 0] else {
            throw CredentialVaultError.accountRemoved
        }
        let data = try encoder.encode(credential)
        let expectedGeneration = loadedGenerations[account.id]
        let saved: CredentialDataRecord?
        if let expectedGeneration {
            saved = await dataStore.compareAndSwap(
                data,
                accountID: account.id,
                expectedGeneration: expectedGeneration
            )
        } else {
            saved = await dataStore.save(data, accountID: account.id)
        }
        guard generation == removalGenerations[account.id, default: 0] else {
            throw CredentialVaultError.accountRemoved
        }
        guard let saved else {
            if backend == .keychain,
               await dataStore.readResult(accountID: account.id) == .unreadable {
                // The stored item exists but this build may not touch it. Keep the
                // rotated credential for this run instead of losing a single-use
                // refresh token, and report the account as needing access.
                sessionCredentials[account.id] = credential
                pendingPersistence[account.id] = (credential, account)
                return
            }
            if expectedGeneration != nil {
                // A rejected compare-and-swap proves the stored bytes are not the ones
                // this session believes in, so the cached copy is stale.
                sessionCredentials.removeValue(forKey: account.id)
                loadedGenerations.removeValue(forKey: account.id)
            }
            throw CredentialVaultError.writeFailed
        }
        remember(saved, credential: credential, accountID: account.id, backend: backend)
        try await metadataRepository.saveAccount(account)
    }

    public func saveRotationUserInitiated(_ credential: StoredCredential, metadata account: Account) async throws {
        let backend = await activeBackend()
        let generation = removalGenerations[account.id, default: 0]
        guard await !metadataRepository.isRemoved(account.id),
              generation == removalGenerations[account.id, default: 0] else {
            throw CredentialVaultError.accountRemoved
        }
        let data = try encoder.encode(credential)
        let saved = await dataStore.saveUserInitiated(data, accountID: account.id)
        guard generation == removalGenerations[account.id, default: 0] else {
            throw CredentialVaultError.accountRemoved
        }
        guard let saved else {
            if backend == .keychain {
                // Keep the single-use rotation in memory until access is restored.
                sessionCredentials[account.id] = credential
                pendingPersistence[account.id] = (credential, account)
                throw CredentialVaultError.authorizationRequired
            }
            throw CredentialVaultError.writeFailed
        }
        remember(saved, credential: credential, accountID: account.id, backend: backend)
        try await metadataRepository.saveAccount(account)
    }

    public func saveUserInitiated(_ credential: StoredCredential, metadata account: Account) async throws {
        let backend = await activeBackend()
        let data = try encoder.encode(credential)
        // A just-completed login is authoritative for this deterministic account ID. In
        // particular it may replace an item owned by an old ad-hoc signature that
        // background code cannot read.
        guard let saved = await dataStore.saveUserInitiated(data, accountID: account.id) else {
            throw backend == .keychain
                ? CredentialVaultError.authorizationRequired
                : CredentialVaultError.writeFailed
        }
        remember(saved, credential: credential, accountID: account.id, backend: backend)
        try await metadataRepository.setRemoved(false, accountID: account.id)
        try await metadataRepository.saveAccount(account)
    }

    public func delete(accountID: String) async {
        removalGenerations[accountID, default: 0] += 1
        try? await metadataRepository.deleteAccount(accountID)
        await dataStore.delete(accountID: accountID)
        loadedGenerations.removeValue(forKey: accountID)
        sessionCredentials.removeValue(forKey: accountID)
        pendingPersistence.removeValue(forKey: accountID)
    }

    private func remember(
        _ record: CredentialDataRecord,
        credential: StoredCredential,
        accountID: String,
        backend: CredentialStorageBackend
    ) {
        loadedGenerations[accountID] = record.generation
        pendingPersistence.removeValue(forKey: accountID)
        if backend == .keychain {
            sessionCredentials[accountID] = credential
        }
    }

    private func readPersisted(
        accountID: String,
        userInitiated: Bool,
        backend: CredentialStorageBackend
    ) async -> StoredCredential? {
        let result = userInitiated
            ? await dataStore.readUserInitiated(accountID: accountID)
            : await dataStore.readResult(accountID: accountID)
        switch result {
        case .success(let record):
            guard let credential = try? decoder.decode(StoredCredential.self, from: record.data) else {
                // Bytes that are not a credential are as unusable as an unreadable item.
                return sessionCredentials[accountID]
            }
            loadedGenerations[accountID] = record.generation
            if backend == .keychain, pendingPersistence[accountID] == nil {
                sessionCredentials[accountID] = credential
            }
            return pendingPersistence[accountID]?.credential ?? credential
        case .absent:
            // The item is provably gone, deleted here or outside Quotio.
            loadedGenerations.removeValue(forKey: accountID)
            sessionCredentials.removeValue(forKey: accountID)
            pendingPersistence.removeValue(forKey: accountID)
            return nil
        case .unreadable:
            // A copy authorized earlier in this run is the only thing that keeps the
            // account alive until the user restores access.
            return sessionCredentials[accountID]
        }
    }

    /// Discards cached plaintext as soon as the backend is not the Keychain. Turning the
    /// hardware vault on mid-run must not leave secrets in memory that the key gates.
    private func activeBackend() async -> CredentialStorageBackend {
        let backend = await dataStore.backend
        if backend != .keychain {
            // Enabling the hardware vault is a user action. Move held rotations into it
            // before dropping plaintext, or the only valid refresh token would be lost.
            for (accountID, pending) in pendingPersistence {
                if let data = try? encoder.encode(pending.credential),
                   let saved = await dataStore.save(data, accountID: accountID) {
                    loadedGenerations[accountID] = saved.generation
                    pendingPersistence.removeValue(forKey: accountID)
                }
            }
            sessionCredentials.removeAll()
            if !pendingPersistence.isEmpty {
                // Writing failed; keep only what cannot be recovered any other way.
                sessionCredentials = pendingPersistence.mapValues(\.credential)
            }
        }
        return backend
    }
}
