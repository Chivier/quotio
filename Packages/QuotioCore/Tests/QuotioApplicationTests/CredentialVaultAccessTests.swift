import Foundation
import XCTest
@testable import QuotioApplication
import QuotioDomain

/// Covers the vault states that decide whether a user sees a working account, an
/// explicit "restore access" action, or a silently vanished account.
final class CredentialVaultAccessTests: XCTestCase {
    private let account = Account.make(
        providerID: AccountProviderID(rawValue: "codex"),
        accountKey: "person@example.com",
        source: .quotioKeychain,
        capabilities: [.disable, .delete]
    )

    func testUnreadableItemIsReportedInsteadOfAbsent() async throws {
        let store = AccessControlledDataStore()
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        try await vault.save(credential("first", refresh: "r1"), metadata: account)

        let fresh = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        await store.setPromptFreeReadsFail(true)

        let state = await fresh.credentialState(for: account.id)
        let loaded = await fresh.credential(for: account.id)
        XCTAssertEqual(state, .unreadable)
        XCTAssertNil(loaded)
    }

    func testUserInitiatedAccessRecoversUnreadableItemOnce() async throws {
        let store = AccessControlledDataStore()
        let seed = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        try await seed.save(credential("first", refresh: "r1"), metadata: account)
        await store.setPromptFreeReadsFail(true)
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())

        let recovered = await vault.credentialForUserInitiatedAccess(for: account.id)
        let again = await vault.credential(for: account.id)
        let userInitiatedReads = await store.userInitiatedReads

        XCTAssertEqual(recovered?.accessToken, "first")
        XCTAssertEqual(again?.accessToken, "first")
        XCTAssertEqual(userInitiatedReads, 1, "An authorized copy must be reused, not asked for again")
    }

    func testRotationIsKeptWhenStoredItemBecomesUnreadable() async throws {
        let store = AccessControlledDataStore()
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        try await vault.save(credential("first", refresh: "r1"), metadata: account)
        _ = await vault.credential(for: account.id)
        await store.setPromptFreeReadsFail(true)

        // A background refresh spent r1 and received r2. Losing r2 would lock the
        // account out until the user signs in again.
        try await vault.save(credential("second", refresh: "r2"), metadata: account)

        let current = await vault.credential(for: account.id)
        let latest = await vault.reloadLatest(accountID: account.id)
        let state = await vault.credentialState(for: account.id)
        XCTAssertEqual(current?.refreshToken, "r2")
        XCTAssertEqual(latest?.refreshToken, "r2")
        XCTAssertEqual(state, .unreadable, "The user must still be asked to restore access")

        let restored = await vault.credentialForUserInitiatedAccess(for: account.id)
        let persisted = await store.storedRefreshToken(accountID: account.id)
        let stateAfterRestore = await vault.credentialState(for: account.id)
        XCTAssertEqual(restored?.refreshToken, "r2")
        XCTAssertEqual(persisted, "r2", "Restoring access writes the pending rotation")
        XCTAssertEqual(stateAfterRestore, .available)
    }

    func testGenuineConcurrentRotationStillFailsClosed() async throws {
        let store = AccessControlledDataStore()
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        try await vault.save(credential("first", refresh: "r1"), metadata: account)
        _ = await vault.credential(for: account.id)
        await store.replaceExternally(credential("external", refresh: "rx"), accountID: account.id)

        do {
            try await vault.save(credential("stale", refresh: "r2"), metadata: account)
            XCTFail("A stale compare-and-swap must not overwrite a newer credential")
        } catch CredentialVaultError.writeFailed {}

        let persisted = await store.storedRefreshToken(accountID: account.id)
        XCTAssertEqual(persisted, "rx")
    }

    func testBackgroundSaveCannotResurrectRemovedAccount() async throws {
        let metadata = MemoryMetadata()
        let vault = CredentialVaultService(dataStore: AccessControlledDataStore(), metadataRepository: metadata)
        try await metadata.setRemoved(true, accountID: account.id)

        do {
            try await vault.save(credential("first", refresh: nil), metadata: account)
            XCTFail("Expected removed account to reject a background write")
        } catch CredentialVaultError.accountRemoved {}

        try await vault.saveUserInitiated(credential("login", refresh: nil), metadata: account)
        let removed = await metadata.isRemoved(account.id)
        XCTAssertFalse(removed, "Signing in again restores a removed account")
    }

    func testUserInitiatedWriteFailureAsksForAuthorization() async {
        let store = AccessControlledDataStore()
        await store.setWritesFail(true)
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())

        do {
            try await vault.saveUserInitiated(credential("login", refresh: nil), metadata: account)
            XCTFail("Expected authorization error")
        } catch CredentialVaultError.authorizationRequired {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testProtectedVaultNeverCachesPlaintext() async throws {
        let store = AccessControlledDataStore()
        let vault = CredentialVaultService(dataStore: store, metadataRepository: MemoryMetadata())
        try await vault.save(credential("first", refresh: nil), metadata: account)
        await store.setBackend(.protectedVault)
        await store.setPromptFreeReadsFail(true)

        let loaded = await vault.credential(for: account.id)
        XCTAssertNil(loaded, "A hardware-gated secret must not be answered from memory")
    }

    private func credential(_ access: String, refresh: String?) -> StoredCredential {
        StoredCredential(
            accessToken: access,
            refreshToken: refresh,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
    }
}

private actor AccessControlledDataStore: CredentialDataStoring {
    private var records: [String: Data] = [:]
    private var promptFreeReadsFail = false
    private var writesFail = false
    private var currentBackend: CredentialStorageBackend = .keychain
    private(set) var userInitiatedReads = 0

    var backend: CredentialStorageBackend { currentBackend }

    func setPromptFreeReadsFail(_ value: Bool) { promptFreeReadsFail = value }
    func setWritesFail(_ value: Bool) { writesFail = value }
    func setBackend(_ value: CredentialStorageBackend) { currentBackend = value }

    func replaceExternally(_ credential: StoredCredential, accountID: String) {
        records[accountID] = try? JSONEncoder().encode(credential)
    }

    func storedRefreshToken(accountID: String) -> String? {
        records[accountID].flatMap { try? JSONDecoder().decode(StoredCredential.self, from: $0) }?.refreshToken
    }

    func read(accountID: String) -> CredentialDataRecord? {
        guard case .success(let record) = readResult(accountID: accountID) else { return nil }
        return record
    }

    func readResult(accountID: String) -> CredentialReadResult {
        guard let data = records[accountID] else { return .absent }
        guard !promptFreeReadsFail else { return .unreadable }
        return .success(record(data))
    }

    func readUserInitiated(accountID: String) -> CredentialReadResult {
        userInitiatedReads += 1
        guard let data = records[accountID] else { return .absent }
        guard currentBackend == .keychain || !promptFreeReadsFail else { return .unreadable }
        return .success(record(data))
    }

    func save(_ data: Data, accountID: String) -> CredentialDataRecord? {
        guard !writesFail, !(promptFreeReadsFail && records[accountID] != nil) else { return nil }
        records[accountID] = data
        return record(data)
    }

    func saveUserInitiated(_ data: Data, accountID: String) -> CredentialDataRecord? {
        guard !writesFail else { return nil }
        records[accountID] = data
        promptFreeReadsFail = false
        return record(data)
    }

    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) -> CredentialDataRecord? {
        guard case .success(let current) = readResult(accountID: accountID),
              current.generation == expectedGeneration else { return nil }
        records[accountID] = data
        return record(data)
    }

    func delete(accountID: String) {
        records.removeValue(forKey: accountID)
    }

    private func record(_ data: Data) -> CredentialDataRecord {
        CredentialDataRecord(data: data, generation: data.base64EncodedString())
    }
}

private actor MemoryMetadata: AccountMetadataRepository {
    private var stored: [Account] = []
    private var disabled: Set<String> = []
    private var removed: Set<String> = []

    func accounts() -> [Account] { stored.filter { !removed.contains($0.id) } }
    func disabledAccountIDs() -> Set<String> { disabled }
    func removedAccountIDs() async -> Set<String> { removed }
    func isRemoved(_ accountID: String) async -> Bool { removed.contains(accountID) }

    func saveAccount(_ account: Account) throws {
        guard !removed.contains(account.id) else { throw CredentialVaultError.accountRemoved }
        stored.removeAll { $0.id == account.id }
        stored.append(account)
    }

    func deleteAccount(_ accountID: String) {
        stored.removeAll { $0.id == accountID }
        removed.insert(accountID)
    }

    func setDisabled(_ isDisabled: Bool, accountID: String) {
        if isDisabled { disabled.insert(accountID) } else { disabled.remove(accountID) }
    }

    func setRemoved(_ isRemoved: Bool, accountID: String) async throws {
        if isRemoved { removed.insert(accountID) } else { removed.remove(accountID) }
    }
}
