import Foundation
import LocalAuthentication
import QuotioApplication
import QuotioDomain
import Security
import XCTest
@testable import QuotioInfrastructure

final class AccountMarkerPersistenceTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("accounts-v1.json")
    }

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func testRemovedAccountStaysHiddenAndRestores() async throws {
        let repository = FileAccountMetadataRepository(url: url)
        let native = account("person@example.com", source: .nativeCredential)

        try await repository.setRemoved(true, accountID: native.id)
        let visible = await repository.filteringAccounts([native])
        XCTAssertTrue(visible.isEmpty)
        let excluded = await repository.excludedQuotaAccountIDs()
        XCTAssertTrue(excluded.contains(native.id))

        let restored = try await repository.restoreRemovedAccounts()
        XCTAssertEqual(restored, 1)
        let afterRestore = await repository.filteringAccounts([native])
        XCTAssertEqual(afterRestore.map(\.id), [native.id])
    }

    func testDeletingOwnedAccountLeavesRemovalMarker() async throws {
        let repository = FileAccountMetadataRepository(url: url)
        let owned = account("person@example.com", source: .quotioKeychain)
        try await repository.saveAccount(owned)

        try await repository.deleteAccount(owned.id)

        let isRemoved = await repository.isRemoved(owned.id)
        XCTAssertTrue(isRemoved, "Discovery must not bring a deleted identity back from another source")
        do {
            try await repository.saveAccount(owned)
            XCTFail("A background save must not resurrect a deleted account")
        } catch CredentialVaultError.accountRemoved {}
    }

    func testMarkersFollowProvenAliasesButNotSharedLabels() async throws {
        let repository = FileAccountMetadataRepository(url: url)
        let oldKey = account("Kiro (Google)", source: .legacyCLIProxy)
        let profileA = account("arn:aws:profile/a", source: .legacyCLIProxy)
        let profileB = account("arn:aws:profile/b", source: .legacyCLIProxy)
        let shared = account("Kiro", source: .nativeCredential)

        try await repository.setDisabled(true, accountID: oldKey.id)
        try await repository.reconcileAliases([
            profileA.id: [oldKey.id, shared.id],
            profileB.id: [shared.id],
        ])

        let visible = await repository.filteringAccounts([profileA, profileB])
        XCTAssertEqual(visible.first { $0.id == profileA.id }?.isDisabled, true)
        XCTAssertEqual(visible.first { $0.id == profileB.id }?.isDisabled, false)
    }

    func testVersionOnePayloadWithoutMarkersStillDecodes() async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"accounts":[],"disabledAccountIDs":["monitor-a"]}"#.utf8).write(to: url)
        let repository = FileAccountMetadataRepository(url: url)

        let disabled = await repository.disabledAccountIDs()
        let removed = await repository.removedAccountIDs()
        XCTAssertEqual(disabled, ["monitor-a"])
        XCTAssertTrue(removed.isEmpty)
    }

    func testMarkersWrittenByEarlierBuildArePreserved() async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"accounts":[],"disabledAccountIDs":[],"removedAccountIDs":["monitor-r"],"accountAliases":{"monitor-x":"monitor-y"}}"#.utf8
        ).write(to: url)
        let repository = FileAccountMetadataRepository(url: url)

        try await repository.setDisabled(true, accountID: "monitor-x")

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["removedAccountIDs"] as? [String], ["monitor-r"])
        XCTAssertEqual((object?["accountAliases"] as? [String: String])?["monitor-x"], "monitor-y")
        XCTAssertEqual(object?["disabledAccountIDs"] as? [String], ["monitor-y"])
    }

    func testDecryptACLDecisionRequiresTrustedApplicationWithoutPrompt() {
        XCTAssertTrue(KeychainAccessPreflight.decryptACLAllowsCurrentExecutable(
            trustedApplicationValidationResults: nil,
            promptSelector: SecKeychainPromptSelector()
        ))
        XCTAssertTrue(KeychainAccessPreflight.decryptACLAllowsCurrentExecutable(
            trustedApplicationValidationResults: [false, true],
            promptSelector: SecKeychainPromptSelector()
        ))
        XCTAssertFalse(KeychainAccessPreflight.decryptACLAllowsCurrentExecutable(
            trustedApplicationValidationResults: [false],
            promptSelector: SecKeychainPromptSelector()
        ))
        XCTAssertFalse(KeychainAccessPreflight.decryptACLAllowsCurrentExecutable(
            trustedApplicationValidationResults: [true],
            promptSelector: SecKeychainPromptSelector(rawValue: 1)
        ))
    }

    func testBackgroundQueriesCarryBothNoUIControls() {
        let query = KeychainCredentialDataStore.noUIQuery(service: "fixture", account: "account")
        XCTAssertTrue(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            KeychainNoUIQuery.uiFailPolicyForTesting()
        )
    }

    func testTestProcessesNeverReachTheRealKeychain() {
        XCTAssertTrue(KeychainTestSafety.isBlocking)
        XCTAssertTrue(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "Quotio",
            environment: ["XCTestConfigurationFilePath": "/tmp/x"],
            isXCTestLoaded: false
        ))
        XCTAssertFalse(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "Quotio",
            environment: [:],
            isXCTestLoaded: false
        ))
    }

    private func account(_ key: String, source: AccountSource) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: key.hasPrefix("arn") || key.hasPrefix("Kiro") ? "kiro" : "codex"),
            accountKey: key,
            source: source,
            capabilities: [.disable, .delete]
        )
    }
}
