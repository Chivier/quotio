import CryptoKit
import Foundation
import QuotioApplication

/// Keeps every Quotio-owned account credential in one secure item.
///
/// macOS authorizes Keychain access per item and per code signature. With one item per
/// account, every new build asked once for every account; with one bundle item, one
/// authorization unlocks all of them. Items written by earlier builds, one per account,
/// are moved into the bundle the first time they are read and then deleted.
///
/// The bundle is never overwritten while it cannot be read: that would drop every other
/// account's credential.
public actor BundledCredentialDataStore: CredentialDataStoring {
    public static let bundleAccountID = "quotio-credential-bundle-v1"

    private struct Payload: Codable {
        var version = 1
        var entries: [String: Data] = [:]
    }

    private enum BundleState {
        /// `record` is nil when no bundle item exists yet.
        case loaded(record: CredentialDataRecord?, entries: [String: Data])
        case unreadable
    }

    private let inner: any CredentialDataStoring
    private var cache: (record: CredentialDataRecord?, entries: [String: Data])?

    public init(inner: any CredentialDataStoring) {
        self.inner = inner
    }

    public var backend: CredentialStorageBackend {
        get async { await inner.backend }
    }

    public func read(accountID: String) async -> CredentialDataRecord? {
        guard case .success(let record) = await readResult(accountID: accountID) else { return nil }
        return record
    }

    public func readResult(accountID: String) async -> CredentialReadResult {
        await read(accountID: accountID, userInitiated: false)
    }

    public func readUserInitiated(accountID: String) async -> CredentialReadResult {
        await read(accountID: accountID, userInitiated: true)
    }

    public func save(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        await write(accountID: accountID, userInitiated: false) { $0[accountID] = data }
            ? Self.record(data) : nil
    }

    public func saveUserInitiated(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        await write(accountID: accountID, userInitiated: true) { $0[accountID] = data }
            ? Self.record(data) : nil
    }

    public func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) async -> CredentialDataRecord? {
        // Swap against what is stored, not against this actor's cache.
        cache = nil
        guard case .success(let current) = await readResult(accountID: accountID),
              current.generation == expectedGeneration else { return nil }
        return await save(data, accountID: accountID)
    }

    public func delete(accountID: String) async {
        _ = await write(accountID: accountID, userInitiated: false) { $0.removeValue(forKey: accountID) }
        // Remove a copy left by an earlier build as well.
        await inner.delete(accountID: accountID)
    }

    // MARK: - Bundle access

    private func read(accountID: String, userInitiated: Bool) async -> CredentialReadResult {
        let state = await loadBundle(userInitiated: userInitiated)
        if case .loaded(_, let entries) = state, let data = entries[accountID] {
            return .success(Self.record(data))
        }

        let legacy = userInitiated
            ? await inner.readUserInitiated(accountID: accountID)
            : await inner.readResult(accountID: accountID)
        switch (legacy, state) {
        case (.success(let record), .loaded):
            await migrateLegacy(record.data, accountID: accountID, userInitiated: userInitiated)
            return .success(Self.record(record.data))
        case (.success(let record), .unreadable):
            return .success(Self.record(record.data))
        case (.absent, .unreadable):
            // The credential may be inside the bundle this build cannot open.
            return .unreadable
        case (_, .loaded):
            return legacy
        case (.unreadable, .unreadable):
            return .unreadable
        }
    }

    private func loadBundle(userInitiated: Bool) async -> BundleState {
        if let cache { return .loaded(record: cache.record, entries: cache.entries) }
        let result = userInitiated
            ? await inner.readUserInitiated(accountID: Self.bundleAccountID)
            : await inner.readResult(accountID: Self.bundleAccountID)
        switch result {
        case .success(let record):
            guard let payload = try? JSONDecoder().decode(Payload.self, from: record.data) else {
                return .unreadable
            }
            cache = (record, payload.entries)
            return .loaded(record: record, entries: payload.entries)
        case .absent:
            cache = (nil, [:])
            return .loaded(record: nil, entries: [:])
        case .unreadable:
            return .unreadable
        }
    }

    private func write(
        accountID: String,
        userInitiated: Bool,
        _ change: (inout [String: Data]) -> Void
    ) async -> Bool {
        guard case .loaded(let record, var entries) = await loadBundle(userInitiated: userInitiated) else {
            return false
        }
        change(&entries)
        guard let data = try? JSONEncoder().encode(Payload(entries: entries)) else { return false }
        let saved: CredentialDataRecord?
        if userInitiated {
            // May rebuild a bundle item owned by an earlier build's signature.
            saved = await inner.saveUserInitiated(data, accountID: Self.bundleAccountID)
        } else if let record {
            saved = await inner.compareAndSwap(
                data,
                accountID: Self.bundleAccountID,
                expectedGeneration: record.generation
            )
        } else {
            saved = await inner.save(data, accountID: Self.bundleAccountID)
        }
        guard let saved else {
            cache = nil
            return false
        }
        cache = (saved, entries)
        return true
    }

    private func migrateLegacy(_ data: Data, accountID: String, userInitiated: Bool) async {
        guard await write(accountID: accountID, userInitiated: userInitiated, { $0[accountID] = data }) else {
            return
        }
        await inner.delete(accountID: accountID)
    }

    private nonisolated static func record(_ data: Data) -> CredentialDataRecord {
        let generation = SHA256.hash(data: Data(data.base64EncodedString().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(20)
            .description
        return CredentialDataRecord(data: data, generation: generation)
    }
}
