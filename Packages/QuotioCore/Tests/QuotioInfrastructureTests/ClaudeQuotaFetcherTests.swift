import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class ClaudeQuotaFetcherTests: XCTestCase {
  static let usage = #"{"five_hour":{"utilization":25}}"#
  static let rotation =
    #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#

  func testPermissionDenied403NeverSpendsTheRefreshToken() async throws {
    let session = CodexScriptedSession { _ in ("", 403) }
    let loader = ClaudeFixedLoader([
      .init(accountKey: "a@b.c", accessToken: "token", refreshToken: "single-use")
    ])

    let output = try await ClaudeQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .claude, mode: .monitor))

    XCTAssertEqual(output.quotas["a@b.c"]?.isForbidden, true)
    XCTAssertEqual(session.paths(), [ClaudeQuotaFetcher.usageURL.path])
  }

  func testForbiddenKeepsTheLastSuccessfulValues() async throws {
    let session = CodexScriptedSession { request in
      request.value(forHTTPHeaderField: "Authorization") == "Bearer good"
        ? (Self.usage, 200) : ("", 403)
    }
    let loader = ClaudeSequenceLoader([
      [.init(accountKey: "a@b.c", accessToken: "good")],
      [.init(accountKey: "a@b.c", accessToken: "revoked")],
    ])
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    _ = try await fetcher.fetch(.init(provider: .claude, mode: .monitor))
    let denied = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))

    XCTAssertEqual(denied.quotas["a@b.c"]?.isForbidden, true)
    XCTAssertEqual(denied.quotas["a@b.c"]?.models.first?.percentage, 75)
  }

  func testRotatedTokenServesFollowUpRequestsWhenItsOwnerRefusesTheWrite() async throws {
    let session = CodexScriptedSession { request in
      if request.url?.path == ClaudeQuotaFetcher.tokenURL.path { return (Self.rotation, 200) }
      return request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated"
        ? (Self.usage, 200) : ("", 401)
    }
    let loader = ClaudeFixedLoader(
      [.init(accountKey: "a@b.c", accessToken: "old", refreshToken: "old-refresh")],
      persistSucceeds: false)
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    let first = try await fetcher.fetch(.init(provider: .claude, mode: .monitor))
    let second = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))

    XCTAssertEqual(first.quotas["a@b.c"]?.models.first?.percentage, 75)
    XCTAssertEqual(second.quotas["a@b.c"]?.models.first?.percentage, 75)
    XCTAssertEqual(session.paths().filter { $0 == ClaudeQuotaFetcher.tokenURL.path }.count, 1)
    XCTAssertEqual(
      session.authorizations(for: ClaudeQuotaFetcher.usageURL),
      ["Bearer old", "Bearer rotated", "Bearer rotated"])
    let persisted = await loader.persistCount()
    XCTAssertEqual(persisted, 2)
  }

  func testPendingRotationServesAnOwnedAccountWhoseVaultItemBecameUnreadable() async throws {
    let session = CodexScriptedSession { request in
      if request.url?.path == ClaudeQuotaFetcher.tokenURL.path { return (Self.rotation, 200) }
      return request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated"
        ? (Self.usage, 200) : ("", 401)
    }
    let loader = ClaudeSequenceLoader(
      [
        [.init(accountKey: "a@b.c", accessToken: "old", refreshToken: "old-refresh", ownedAccountID: "owned")],
        [.init(accountKey: "a@b.c", accessToken: "", ownedAccountID: "owned", isReadable: false)],
      ],
      persistSucceeds: false)
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    _ = try await fetcher.fetch(.init(provider: .claude, mode: .monitor))
    let unreadable = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))

    XCTAssertEqual(unreadable.quotas["a@b.c"]?.models.first?.percentage, 75)
    XCTAssertEqual(unreadable.credentialAccountKeys, ["a@b.c"])
    XCTAssertEqual(session.authorizations(for: ClaudeQuotaFetcher.usageURL).last, "Bearer rotated")
    XCTAssertEqual(session.paths().filter { $0 == ClaudeQuotaFetcher.tokenURL.path }.count, 1)
  }

  func testConcurrentFetchesSpendOneRefreshToken() async throws {
    let session = SlowRefreshSession()
    let loader = ClaudeFixedLoader([
      .init(accountKey: "a@b.c", accessToken: "old", refreshToken: "old-refresh")
    ])
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    async let first = fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))
    async let second = fetcher.fetch(
      .init(provider: .claude, scope: .account("a@b.c"), mode: .monitor, force: true))
    let outputs = try await [first, second]

    XCTAssertEqual(outputs.compactMap { $0.quotas["a@b.c"]?.models.first?.percentage }, [75, 75])
    let refreshes = await session.refreshCount()
    XCTAssertEqual(refreshes, 1)
  }

  func testUserStartedRefreshMayUnlockAnOwnedAccountAndPersistsThroughThePromptingPath() async throws {
    let account = Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.claude.rawValue),
      accountKey: "a@b.c", source: .quotioKeychain)
    let vault = CodexTestVault(
      accounts: [account], readable: [:],
      userInitiated: [
        account.id: StoredCredential(
          accessToken: "old", refreshToken: "old-refresh", idToken: nil, accountID: nil,
          expiresAt: Date().addingTimeInterval(10), extra: [:])
      ])
    let loader = CompositeClaudeQuotaCredentialLoader(
      local: ClaudeFixedLoader([]), vault: vault, metadata: CodexTestMetadata(),
      external: CodexTestKeychain(nil), desktop: nil)

    let background = await loader.credentials(for: .monitor)
    XCTAssertEqual(background.map(\.isReadable), [false])
    XCTAssertEqual(background.map(\.ownedAccountID), [account.id])

    let session = CodexScriptedSession { request in
      request.url?.path == ClaudeQuotaFetcher.tokenURL.path ? (Self.rotation, 200) : (Self.usage, 200)
    }
    let output = try await ClaudeQuotaFetcher(credentials: loader, session: session).fetch(.init(
      provider: .claude, scope: .account("a@b.c"), mode: .monitor, force: true,
      allowsUserInteraction: true))

    XCTAssertEqual(output.quotas["a@b.c"]?.models.first?.percentage, 75)
    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.userInitiated), [true])
    XCTAssertEqual(saves.map(\.credential.accessToken), ["rotated"])
  }

  func testOwnedRotationIsWrittenToTheVaultOnlyNeverToASameNamedFile() async throws {
    let account = Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.claude.rawValue),
      accountKey: "a@b.c", source: .quotioKeychain)
    let vault = CodexTestVault(accounts: [account], readable: [
      account.id: StoredCredential(
        accessToken: "old", refreshToken: "old-refresh", idToken: nil, accountID: nil,
        expiresAt: nil, extra: [:])
    ])
    let local = ClaudeFixedLoader([])
    let loader = CompositeClaudeQuotaCredentialLoader(
      local: local, vault: vault, metadata: CodexTestMetadata(),
      external: CodexTestKeychain(nil), desktop: nil)
    let loaded = await loader.credentials(for: .monitor)
    let owned = try XCTUnwrap(loaded.first)
    let file = ClaudeQuotaCredential(accountKey: "a@b.c", accessToken: "file", refreshToken: "old-refresh")
    let refresh = QuotaTokenRefresh(accessToken: "new", refreshToken: "new-refresh", expiresAt: nil)

    let ownedStored = await loader.persist(
      refresh, replacing: "old-refresh", for: owned, request: .init(provider: .claude, mode: .monitor))
    _ = await loader.persist(
      refresh, replacing: "old-refresh", for: file, request: .init(provider: .claude, mode: .monitor))

    XCTAssertTrue(ownedStored)
    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.credential.refreshToken), ["new-refresh"])
    let localWrites = await local.persistCount()
    XCTAssertEqual(localWrites, 1)
  }
}

actor ClaudeFixedLoader: ClaudeQuotaCredentialLoading {
  private let values: [ClaudeQuotaCredential]
  private let persistSucceeds: Bool
  private var persisted = 0

  init(_ values: [ClaudeQuotaCredential], persistSucceeds: Bool = true) {
    self.values = values
    self.persistSucceeds = persistSucceeds
  }

  func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] { values }

  func persist(
    _ refresh: QuotaTokenRefresh, replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential, request: QuotaFetchRequest
  ) async -> Bool {
    persisted += 1
    return persistSucceeds
  }

  func persistCount() -> Int { persisted }
}

/// Answers each `credentials` call with the next batch, repeating the last.
actor ClaudeSequenceLoader: ClaudeQuotaCredentialLoading {
  private var batches: [[ClaudeQuotaCredential]]
  private let persistSucceeds: Bool
  private var calls = 0

  init(_ batches: [[ClaudeQuotaCredential]], persistSucceeds: Bool = true) {
    self.batches = batches
    self.persistSucceeds = persistSucceeds
  }

  func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    defer { calls += 1 }
    return batches[min(calls, batches.count - 1)]
  }

  func persist(
    _ refresh: QuotaTokenRefresh, replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential, request: QuotaFetchRequest
  ) async -> Bool { persistSucceeds }
}

private actor SlowRefreshSession: QuotaHTTPSession {
  private var refreshes = 0

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let body: String
    let status: Int
    if request.url?.path == ClaudeQuotaFetcher.tokenURL.path {
      refreshes += 1
      try await Task.sleep(for: .milliseconds(50))
      (body, status) = (ClaudeQuotaFetcherTests.rotation, 200)
    } else if request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated" {
      (body, status) = (ClaudeQuotaFetcherTests.usage, 200)
    } else {
      (body, status) = ("", 401)
    }
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }

  func refreshCount() -> Int { refreshes }
}
