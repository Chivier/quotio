import Foundation
import QuotioApplication
import XCTest
@testable import QuotioInfrastructure

final class BundledCredentialDataStoreTests: XCTestCase {
    func testLegacyItemsMoveIntoTheBundle() async throws {
        let inner = ItemStore()
        await inner.put(Data("a".utf8), "account-a")
        let store = BundledCredentialDataStore(inner: inner)

        let read = await store.readResult(accountID: "account-a")

        guard case .success(let record) = read else { return XCTFail("Expected the legacy item") }
        XCTAssertEqual(record.data, Data("a".utf8))
        let legacy = await inner.has("account-a")
        let bundle = await inner.has(BundledCredentialDataStore.bundleAccountID)
        XCTAssertFalse(legacy, "The per-account item is removed once it is in the bundle")
        XCTAssertTrue(bundle)
    }

    func testOneAuthorizationUnlocksEveryAccount() async throws {
        let inner = ItemStore()
        let seed = BundledCredentialDataStore(inner: inner)
        _ = await seed.save(Data("a".utf8), accountID: "account-a")
        _ = await seed.save(Data("b".utf8), accountID: "account-b")
        await inner.setUnreadable(true)

        let store = BundledCredentialDataStore(inner: inner)
        let before = await store.readResult(accountID: "account-b")
        XCTAssertEqual(before, .unreadable)

        _ = await store.readUserInitiated(accountID: "account-a")
        let after = await store.readResult(accountID: "account-b")
        let prompts = await inner.userInitiatedReads
        guard case .success(let record) = after else { return XCTFail("Expected access to every account") }
        XCTAssertEqual(record.data, Data("b".utf8))
        XCTAssertEqual(prompts, 1)
    }

    func testUnreadableBundleIsNeverOverwritten() async throws {
        let inner = ItemStore()
        let seed = BundledCredentialDataStore(inner: inner)
        _ = await seed.save(Data("a".utf8), accountID: "account-a")
        await inner.setUnreadable(true)

        let store = BundledCredentialDataStore(inner: inner)
        let saved = await store.save(Data("b".utf8), accountID: "account-b")

        XCTAssertNil(saved)
        await inner.setUnreadable(false)
        let kept = await BundledCredentialDataStore(inner: inner).readResult(accountID: "account-a")
        guard case .success(let record) = kept else { return XCTFail("The other credential must survive") }
        XCTAssertEqual(record.data, Data("a".utf8))
    }

    func testCompareAndSwapRejectsAStaleGeneration() async throws {
        let store = BundledCredentialDataStore(inner: ItemStore())
        let saved = await store.save(Data("a".utf8), accountID: "account-a")
        let first = try XCTUnwrap(saved)
        _ = await store.save(Data("newer".utf8), accountID: "account-a")

        let swapped = await store.compareAndSwap(
            Data("stale".utf8),
            accountID: "account-a",
            expectedGeneration: first.generation
        )
        XCTAssertNil(swapped)
    }

    func testDeleteRemovesOnlyThatAccount() async throws {
        let store = BundledCredentialDataStore(inner: ItemStore())
        _ = await store.save(Data("a".utf8), accountID: "account-a")
        _ = await store.save(Data("b".utf8), accountID: "account-b")

        await store.delete(accountID: "account-a")

        let deleted = await store.readResult(accountID: "account-a")
        let kept = await store.readResult(accountID: "account-b")
        XCTAssertEqual(deleted, .absent)
        guard case .success = kept else { return XCTFail("Expected the other account to remain") }
    }
}

/// Stands in for the Keychain: items can become unreadable to prompt-free reads, as
/// they do after a rebuild changes the app's signature.
private actor ItemStore: CredentialDataStoring {
    private var items: [String: Data] = [:]
    private var unreadable = false
    private(set) var userInitiatedReads = 0

    func put(_ data: Data, _ id: String) { items[id] = data }
    func has(_ id: String) -> Bool { items[id] != nil }
    func setUnreadable(_ value: Bool) { unreadable = value }

    func read(accountID: String) async -> CredentialDataRecord? {
        guard case .success(let record) = await readResult(accountID: accountID) else { return nil }
        return record
    }

    func readResult(accountID: String) async -> CredentialReadResult {
        guard let data = items[accountID] else { return .absent }
        return unreadable ? .unreadable : .success(record(data))
    }

    func readUserInitiated(accountID: String) async -> CredentialReadResult {
        userInitiatedReads += 1
        guard let data = items[accountID] else { return .absent }
        return .success(record(data))
    }

    func save(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        guard !(unreadable && items[accountID] != nil) else { return nil }
        items[accountID] = data
        return record(data)
    }

    func saveUserInitiated(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        items[accountID] = data
        return record(data)
    }

    func compareAndSwap(_ data: Data, accountID: String, expectedGeneration: String) async -> CredentialDataRecord? {
        guard case .success(let current) = await readResult(accountID: accountID),
              current.generation == expectedGeneration else { return nil }
        items[accountID] = data
        return record(data)
    }

    func delete(accountID: String) async {
        items.removeValue(forKey: accountID)
    }

    private func record(_ data: Data) -> CredentialDataRecord {
        CredentialDataRecord(data: data, generation: data.base64EncodedString())
    }
}
