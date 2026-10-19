import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class CodexQuotaFetcherTests: XCTestCase {
  static let usage = #"{"rate_limit":{"primary_window":{"used_percent":10}}}"#
  static let rotation =
    #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#

  func testDeactivatedWorkspace403NeverSpendsTheRefreshToken() async throws {
    let session = CodexScriptedSession { _ in ("", 403) }
    let loader = CodexFixedLoader([
      .init(
        accountKey: "a@b.c • 07e99801", accessToken: "token", refreshToken: "single-use",
        accountID: "account-1", source: .quotio(accountID: "owned"), displayName: "a@b.c")
    ])

    let output = try await CodexQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas["a@b.c • 07e99801"]?.isForbidden, true)
    XCTAssertEqual(output.quotas["a@b.c • 07e99801"]?.accountDisplayName, "a@b.c")
    XCTAssertFalse(session.paths().contains(CodexQuotaFetcher.tokenURL.path))
    let persisted = await loader.persistCount()
    XCTAssertEqual(persisted, 0)
  }

  func testCodexCLICredentialIsNeverRefreshedAndAsksForACLILogin() async throws {
    let expired = Self.jwt(["exp": 1, "email": "cli@example.com"])
    let session = CodexScriptedSession { request in
      request.url?.path == CodexQuotaFetcher.tokenURL.path ? (Self.rotation, 200) : ("", 401)
    }
    let loader = CodexFixedLoader([
      .init(
        accountKey: "cli@example.com", accessToken: expired, refreshToken: "cli-refresh",
        source: .codexCLI, displayName: "cli@example.com", expiresAt: Date(timeIntervalSince1970: 1))
    ])

    let output = try await CodexQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .codex, mode: .monitor, force: true))

    XCTAssertEqual(output.quotas["cli@example.com"]?.isForbidden, true)
    XCTAssertEqual(session.paths(), [CodexQuotaFetcher.usageURL.path])
    let persisted = await loader.persistCount()
    XCTAssertEqual(persisted, 0)
  }

  func testRotatedTokenServesFollowUpRequestsWhenItsOwnerRefusesTheWrite() async throws {
    let session = CodexScriptedSession { request in
      if request.url?.path == CodexQuotaFetcher.tokenURL.path { return (Self.rotation, 200) }
      guard request.url == CodexQuotaFetcher.usageURL else { return ("", 404) }
      return request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated"
        ? (Self.usage, 200) : ("", 401)
    }
    let loader = CodexFixedLoader(
      [.init(accountKey: "legacy", accessToken: "old", refreshToken: "old-refresh")],
      persistSucceeds: false)
    let fetcher = CodexQuotaFetcher(credentials: loader, session: session)

    let first = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))
    let second = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(first.quotas["legacy"]?.models.first?.percentage, 90)
    XCTAssertEqual(second.quotas["legacy"]?.models.first?.percentage, 90)
    // The spent refresh token is never offered again; the rotation is re-persisted.
    XCTAssertEqual(session.paths().filter { $0 == CodexQuotaFetcher.tokenURL.path }.count, 1)
    let persisted = await loader.persistCount()
    XCTAssertEqual(persisted, 2)
    XCTAssertEqual(
      session.authorizations(for: CodexQuotaFetcher.usageURL),
      ["Bearer old", "Bearer rotated", "Bearer rotated"])
  }

  func testOwnedLoginRefreshesBeforeExpiryAndPersistsThroughTheVault() async throws {
    let account = Self.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(accounts: [account], readable: [
      account.id: StoredCredential(
        accessToken: "old", refreshToken: "old-refresh",
        idToken: Self.jwt(["email": "a@b.c"]), accountID: "account-1",
        expiresAt: Date().addingTimeInterval(60), extra: [:])
    ])
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexFixedLoader([]), vault: vault, metadata: CodexTestMetadata(),
      external: CodexTestKeychain(nil))
    let session = CodexScriptedSession { request in
      request.url?.path == CodexQuotaFetcher.tokenURL.path ? (Self.rotation, 200) : (Self.usage, 200)
    }
    let fetcher = CodexQuotaFetcher(credentials: loader, session: session)

    let output = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas.keys.sorted(), ["a@b.c • 07e99801"])
    XCTAssertEqual(output.quotas["a@b.c • 07e99801"]?.accountDisplayName, "a@b.c")
    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.credential.accessToken), ["rotated"])
    XCTAssertEqual(saves.map(\.credential.refreshToken), ["rotated-refresh"])
    XCTAssertEqual(saves.map(\.userInitiated), [false])
    XCTAssertEqual(session.authorizations(for: CodexQuotaFetcher.usageURL), ["Bearer rotated"])
  }

  func testUserStartedRefreshPersistsRotationThroughTheUserInitiatedPath() async throws {
    let account = Self.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(accounts: [account], readable: [
      account.id: StoredCredential(
        accessToken: "old", refreshToken: "old-refresh", idToken: nil, accountID: "account-1",
        expiresAt: Date().addingTimeInterval(-10), extra: [:])
    ])
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexFixedLoader([]), vault: vault, metadata: CodexTestMetadata(),
      external: CodexTestKeychain(nil))
    let session = CodexScriptedSession { request in
      request.url?.path == CodexQuotaFetcher.tokenURL.path ? (Self.rotation, 200) : (Self.usage, 200)
    }

    _ = try await CodexQuotaFetcher(credentials: loader, session: session).fetch(.init(
      provider: .codex, scope: .account("a@b.c • 07e99801"), mode: .monitor,
      allowsUserInteraction: true))

    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.userInitiated), [true])
  }

  func testOneEmailInTwoWorkspacesStaysTwoRowsWithoutAnAmbiguousAlias() async throws {
    let personal = Self.ownedAccount(key: "a@b.c • eed01d5b", email: "a@b.c")
    let team = Self.ownedAccount(key: "a@b.c • d782057d", email: "a@b.c")
    let vault = CodexTestVault(accounts: [personal, team], readable: [
      personal.id: StoredCredential(
        accessToken: "personal", refreshToken: nil, idToken: nil,
        accountID: "workspace-personal", expiresAt: nil, extra: [:]),
      team.id: StoredCredential(
        accessToken: "team", refreshToken: nil, idToken: nil,
        accountID: "workspace-team", expiresAt: nil, extra: [:]),
    ])
    let cliLogin = try XCTUnwrap(LocalCodexQuotaCredentialLoader.loadNative(
      data: Self.nativeAuth(email: "a@b.c", accountID: "workspace-team", access: "cli")))
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexFixedLoader([cliLogin]), vault: vault, metadata: CodexTestMetadata(),
      external: CodexTestKeychain(nil))

    let output = try await CodexQuotaFetcher(
      credentials: loader, session: CodexScriptedSession { _ in (Self.usage, 200) }
    ).fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas.keys.sorted(), ["a@b.c • d782057d", "a@b.c • eed01d5b"])
    XCTAssertEqual(Set(output.quotas.values.compactMap(\.accountDisplayName)), ["a@b.c"])
    XCTAssertNil(output.accountAliases["a@b.c"], "One email naming two workspaces proves nothing")
  }

  func testNativeLoginMigratesItsEmailOnlyRowWhenTheEmailIsUnambiguous() throws {
    let native = try XCTUnwrap(LocalCodexQuotaCredentialLoader.loadNative(
      data: Self.nativeAuth(email: "someone@mail.com", accountID: "account-1", access: "cli")))

    XCTAssertEqual(native.accountKey, "someone@mail.com • 07e99801")
    XCTAssertEqual(native.displayName, "someone@mail.com")
    XCTAssertEqual(native.source, .codexCLI)
    XCTAssertEqual(
      CodexQuotaFetcher.accountAliases([native]),
      ["someone@mail.com": "someone@mail.com • 07e99801"])
  }

  func testScopedRequestForAnOwnedLoginIsNeverAnsweredByAnotherSource() async throws {
    let account = Self.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(
      accounts: [account],
      readable: [:],
      userInitiated: [
        account.id: StoredCredential(
          accessToken: "owned", refreshToken: nil, idToken: nil, accountID: "account-1",
          expiresAt: nil, extra: [:])
      ])
    let keychain = CodexTestKeychain(ExternalCredentialRecord(
      data: Self.nativeAuth(email: "a@b.c", accountID: "account-1", access: "cli"),
      account: "Codex Auth"))
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexFixedLoader([]), vault: vault, metadata: CodexTestMetadata(), external: keychain)
    let session = CodexScriptedSession { _ in (Self.usage, 200) }
    let fetcher = CodexQuotaFetcher(credentials: loader, session: session)

    let background = try await fetcher.fetch(
      .init(provider: .codex, scope: .account("a@b.c • 07e99801"), mode: .monitor))
    XCTAssertTrue(background.quotas.isEmpty)
    XCTAssertTrue(session.paths().isEmpty)

    let provider = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))
    XCTAssertEqual(provider.quotas.keys.sorted(), ["a@b.c • 07e99801"])
    XCTAssertEqual(session.authorizations(for: CodexQuotaFetcher.usageURL), ["Bearer cli"])

    let foreground = try await fetcher.fetch(.init(
      provider: .codex, scope: .account("a@b.c • 07e99801"), mode: .monitor,
      allowsUserInteraction: true))
    XCTAssertEqual(foreground.quotas.keys.sorted(), ["a@b.c • 07e99801"])
    XCTAssertEqual(
      session.authorizations(for: CodexQuotaFetcher.usageURL), ["Bearer cli", "Bearer owned"])
  }

  func testCodexCLIKeychainAndFilesAreNeverWritten() async throws {
    let keychain = CodexTestKeychain(ExternalCredentialRecord(
      data: Self.nativeAuth(email: "a@b.c", accountID: "account-1", access: "cli"),
      account: "Codex Auth"))
    let local = CodexFixedLoader([])
    let loader = CompositeCodexQuotaCredentialLoader(
      local: local, vault: CodexTestVault(accounts: [], readable: [:]),
      metadata: CodexTestMetadata(), external: keychain)
    let loaded = await loader.credentials(for: .monitor)
    let credential = try XCTUnwrap(loaded.first)

    let stored = await loader.persist(
      QuotaTokenRefresh(accessToken: "new", refreshToken: "new-refresh", expiresAt: nil),
      replacing: "refresh", for: credential,
      request: .init(provider: .codex, mode: .monitor))

    XCTAssertEqual(credential.source, .codexCLI)
    XCTAssertFalse(stored)
    let swaps = await keychain.swapCount()
    let localWrites = await local.persistCount()
    XCTAssertEqual(swaps, 0)
    XCTAssertEqual(localWrites, 0)
  }

  // MARK: - Fixtures

  static func ownedAccount(key: String, email: String) -> Account {
    Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
      accountKey: key, displayName: email, source: .quotioKeychain,
      credentialReference: "keychain")
  }

  static func nativeAuth(email: String, accountID: String, access: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": access,
        "refresh_token": "cli-refresh",
        "account_id": accountID,
        "id_token": jwt(["email": email]),
      ]
    ])
  }

  static func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
  }
}

actor CodexFixedLoader: CodexQuotaCredentialLoading {
  private let values: [CodexQuotaCredential]
  private let persistSucceeds: Bool
  private var persisted = 0

  init(_ values: [CodexQuotaCredential], persistSucceeds: Bool = true) {
    self.values = values
    self.persistSucceeds = persistSucceeds
  }

  func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] { values }

  func persist(
    _ refresh: QuotaTokenRefresh, replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential, request: QuotaFetchRequest
  ) async -> Bool {
    persisted += 1
    return persistSucceeds
  }

  func persistCount() -> Int { persisted }
}

actor CodexTestVault: CredentialVault {
  struct Save: Sendable {
    let credential: StoredCredential
    let userInitiated: Bool
    let account: Account
  }

  private var stored: [Account]
  private var readable: [String: StoredCredential]
  private let userInitiated: [String: StoredCredential]
  private var deniedUserInitiatedSaves: Int
  private var recorded: [Save] = []

  init(
    accounts: [Account], readable: [String: StoredCredential],
    userInitiated: [String: StoredCredential] = [:],
    deniedUserInitiatedSaves: Int = 0
  ) {
    stored = accounts
    self.readable = readable
    self.userInitiated = userInitiated
    self.deniedUserInitiatedSaves = deniedUserInitiatedSaves
  }

  func accounts() async -> [Account] { stored }
  func credential(for accountID: String) async -> StoredCredential? { readable[accountID] }
  func reloadLatest(accountID: String) async -> StoredCredential? { readable[accountID] }
  func credentialForUserInitiatedAccess(for accountID: String) async -> StoredCredential? {
    readable[accountID] ?? userInitiated[accountID]
  }
  func credentialState(for accountID: String) async -> StoredCredentialState {
    if readable[accountID] != nil { return .available }
    return userInitiated[accountID] == nil ? .absent : .unreadable
  }
  func save(_ credential: StoredCredential, metadata: Account) async throws {
    recorded.append(Save(credential: credential, userInitiated: false, account: metadata))
    store(credential, metadata)
  }
  func saveRotationUserInitiated(_ credential: StoredCredential, metadata: Account) async throws {
    try await saveUserInitiated(credential, metadata: metadata)
  }

  func saveUserInitiated(_ credential: StoredCredential, metadata: Account) async throws {
    if deniedUserInitiatedSaves > 0 {
      deniedUserInitiatedSaves -= 1
      throw CredentialVaultError.authorizationRequired
    }
    recorded.append(Save(credential: credential, userInitiated: true, account: metadata))
    store(credential, metadata)
  }
  private func store(_ credential: StoredCredential, _ account: Account) {
    readable[account.id] = credential
    stored.removeAll { $0.id == account.id }
    stored.append(account)
  }
  func delete(accountID: String) async {}

  func saves() -> [Save] { recorded }
}

actor CodexTestMetadata: AccountMetadataRepository {
  func accounts() async -> [Account] { [] }
  func disabledAccountIDs() async -> Set<String> { [] }
  func saveAccount(_ account: Account) async throws {}
  func deleteAccount(_ accountID: String) async throws {}
  func setDisabled(_ disabled: Bool, accountID: String) async throws {}
}

actor CodexTestKeychain: ExternalCredentialReading {
  private let record: ExternalCredentialRecord?
  private var swaps = 0

  init(_ record: ExternalCredentialRecord?) { self.record = record }

  func read(service: String, account: String?) async -> ExternalCredentialRecord? { record }
  func compareAndSwap(
    service: String, account: String, expectedData: Data, newData: Data
  ) async -> Bool {
    swaps += 1
    return true
  }
  func swapCount() -> Int { swaps }
}

final class CodexScriptedSession: QuotaHTTPSession, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private let lock = NSLock()
  private var recorded: [URLRequest] = []

  init(_ handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lock.withLock { recorded.append(request) }
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }

  func paths() -> [String] { lock.withLock { recorded.compactMap { $0.url?.path } } }

  func authorizations(for url: URL) -> [String] {
    lock.withLock {
      recorded.filter { $0.url == url }.compactMap {
        $0.value(forHTTPHeaderField: "Authorization")
      }
    }
  }
}
