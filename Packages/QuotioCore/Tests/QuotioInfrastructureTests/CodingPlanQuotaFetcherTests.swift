import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class CodingPlanQuotaFetcherTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotio-coding-plan-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - Mappers

  func testKimiMapperKeepsRollingWindowBeforeWeeklyWindow() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data(
      #"""
      {
        "data": {
          "plan": "Coding Pro",
          "user": { "email": "coder@example.com" },
          "usage": { "used": 10, "limit": 100, "reset_in": 86400 },
          "limits": [
            {
              "name": "rolling",
              "detail": { "used": 35, "limit": 50, "reset_in": 18000 },
              "window": { "duration": 5, "timeUnit": "HOUR" }
            }
          ]
        }
      }
      """#.utf8)

    let quota = try XCTUnwrap(KimiQuotaMapper.map(data, now: now))

    XCTAssertEqual(quota.models.map(\.name), ["kimi-five-hour", "kimi-weekly"])
    XCTAssertEqual(quota.models.map(\.percentage), [30, 90])
    XCTAssertEqual(quota.models[0].used, 35)
    XCTAssertEqual(quota.models[0].limit, 50)
    XCTAssertEqual(quota.planType, "Coding Pro")
    XCTAssertEqual(quota.accountDisplayName, "coder@example.com")
    XCTAssertTrue(quota.models.allSatisfy { !$0.resetTime.isEmpty })
  }

  func testMiniMaxMapperUsesPercentageWhenCountsAreZero() throws {
    let data = Data(
      #"""
      {
        "model_remains": [
          {
            "model_name": "general",
            "current_interval_total_count": 0,
            "current_interval_usage_count": 0,
            "current_interval_remaining_percent": "96",
            "remains_time": 3600000,
            "current_weekly_total_count": 0,
            "current_weekly_usage_count": 0,
            "current_weekly_remaining_percent": 99,
            "weekly_remains_time": 7200000
          }
        ],
        "base_resp": { "status_code": 0, "status_msg": "success" }
      }
      """#.utf8)

    let quota = try XCTUnwrap(
      MiniMaxQuotaMapper.map(data, now: Date(timeIntervalSince1970: 1_800_000_000)))

    XCTAssertEqual(quota.models.map(\.name), ["minimax-five-hour", "minimax-weekly"])
    XCTAssertEqual(quota.models.map(\.percentage), [96, 99])
    XCTAssertEqual(quota.planType, "Token Plan")
    XCTAssertTrue(quota.models.allSatisfy { !$0.resetTime.isEmpty })
  }

  func testMiniMaxMapperPrefersCountsWhenEntitlementIsKnown() throws {
    let data = Data(
      #"""
      {
        "model_remains": [{
          "model_name": "general",
          "current_interval_total_count": 100,
          "current_interval_usage_count": 25,
          "current_interval_remaining_percent": 1
        }]
      }
      """#.utf8)

    let quota = try XCTUnwrap(MiniMaxQuotaMapper.map(data, now: Date()))
    let interval = try XCTUnwrap(quota.models.first)

    XCTAssertEqual(interval.percentage, 75)
    XCTAssertEqual(interval.used, 25)
    XCTAssertEqual(interval.limit, 100)
    XCTAssertEqual(interval.remaining, 75)
  }

  // MARK: - Local Kimi credentials

  func testKimiLegacyDiscoveryIgnoresUnrelatedProviders() {
    let credentials = KimiLocalCredentialReader.parseLegacyConfig(
      #"""
      [providers.kimi]
      type = "kimi"
      api_key = "sk-kimi-fixture"

      [providers.other]
      type = "openai"
      api_key = "sk-unrelated-fixture"
      """#,
      path: "/fixture/config.toml"
    )

    XCTAssertEqual(credentials.count, 1)
    XCTAssertEqual(credentials[0].displayName, "providers.kimi")
    XCTAssertEqual(credentials[0].sourcePath, "/fixture/config.toml")
    XCTAssertFalse(credentials[0].accountKey.contains("sk-kimi-fixture"))
  }

  func testKimiCLIIdentityHeadersIncludeStableDeviceContext() {
    let headers = KimiDeviceIdentity.headers(deviceID: "fixture-device-id", appVersion: "1.2.3")

    XCTAssertEqual(headers["X-Msh-Platform"], "kimi_code_cli")
    XCTAssertEqual(headers["X-Msh-Device-Id"], "fixture-device-id")
    XCTAssertEqual(headers["X-Msh-Version"], "1.2.3")
    XCTAssertFalse(headers["X-Msh-Device-Name", default: ""].isEmpty)
    XCTAssertTrue(headers["X-Msh-Device-Model", default: ""].contains("macOS"))
    XCTAssertFalse(headers["X-Msh-Os-Version", default: ""].isEmpty)
  }

  func testExpiredKimiCLITokenIsStillDiscoveredAndReportedWithoutARequest() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let files = FakeFileReader(files: [
      cliCredentialPath: Data(
        #"{"access_token":"expired-token","expires_at":\#(now.timeIntervalSince1970 - 3600)}"#.utf8)
    ])
    let session = ScriptedSession { _ in .status(200, Self.kimiBody) }
    let fetcher = makeKimiFetcher(files: files, session: session, now: now)

    let discovered = await KimiLocalCredentialReader(homeDirectory: home, files: files).accounts()
    XCTAssertEqual(discovered.map(\.accountKey), [KimiLocalCredentialReader.cliAccountKey])

    let output = try await fetcher.fetch(.init(provider: .kimi, mode: .localProxy))
    let quota = try XCTUnwrap(output.quotas[KimiLocalCredentialReader.cliAccountKey])
    XCTAssertTrue(quota.isForbidden)
    XCTAssertEqual(quota.tokenExpiresAt, now.addingTimeInterval(-3600))
    XCTAssertEqual(output.credentialAccountKeys, [KimiLocalCredentialReader.cliAccountKey])
    let requests = await session.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testKimiCLIRequestPrefersTheCLIDeviceID() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let files = FakeFileReader(files: [
      cliCredentialPath: Data(
        #"{"access_token":"cli-token","expires_at":\#(now.timeIntervalSince1970 + 3600)}"#.utf8),
      home.appendingPathComponent(".kimi-code/device_id").path: Data("cli-device\n".utf8),
    ])
    let session = ScriptedSession { _ in .status(200, Self.kimiBody) }
    let fetcher = makeKimiFetcher(files: files, session: session, now: now)

    let output = try await fetcher.fetch(.init(provider: .kimi, mode: .monitor))

    XCTAssertEqual(output.quotas["Kimi Code"]?.models.map(\.name), ["kimi-five-hour"])
    let request = try await XCTUnwrapAsync(await session.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Msh-Device-Id"), "cli-device")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
  }

  func testKimiDeviceIDFallbackIsAPersistedInstallIDNotDerivedFromTheToken() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = "token-without-device-file"
    let files = FakeFileReader(files: [
      cliCredentialPath: Data(
        #"{"access_token":"\#(token)","expires_at":\#(now.timeIntervalSince1970 + 3600)}"#.utf8)
    ])
    let identityURL = directory.appendingPathComponent("support/kimi-device-id")
    let session = ScriptedSession { _ in .status(200, Self.kimiBody) }
    let fetcher = makeKimiFetcher(
      files: files, session: session, now: now,
      identity: KimiDeviceIdentity(url: identityURL, makeIdentifier: { "random-install-id" }))

    _ = try await fetcher.fetch(.init(provider: .kimi, mode: .monitor))

    let request = try await XCTUnwrapAsync(await session.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Msh-Device-Id"), "random-install-id")
    XCTAssertEqual(try String(contentsOf: identityURL, encoding: .utf8), "random-install-id")
    let reloaded = await KimiDeviceIdentity(url: identityURL, makeIdentifier: { "other" })
      .installIdentifier()
    XCTAssertEqual(reloaded, "random-install-id")

    let defaultIdentity = await KimiDeviceIdentity(
      url: directory.appendingPathComponent("default-id")
    ).deviceID(preferring: nil)
    XCTAssertFalse(defaultIdentity.isEmpty)
    XCTAssertFalse(defaultIdentity.contains(token))
  }

  func testKimiAuthFilesAreReadThroughTheRepositoryWithTheirDeviceID() async throws {
    let authDirectory = directory.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
    try Data(
      #"{"type":"kimi","email":"kimi@example.com","access_token":"file-token","device_id":"file-device"}"#
        .utf8
    ).write(to: authDirectory.appendingPathComponent("kimi-kimi@example.com.json"))
    let repository = FileAuthFileRepository(
      authDirectory: authDirectory,
      awsSSOCacheDirectory: directory.appendingPathComponent("sso"))
    let descriptors = await repository.scanAllAuthFiles()
    XCTAssertEqual(descriptors.map(\.providerID.rawValue), ["kimi"])

    let session = ScriptedSession { _ in .status(200, Self.kimiBody) }
    let fetcher = makeKimiFetcher(
      files: FakeFileReader(files: [:]), session: session, authFiles: repository)
    let output = try await fetcher.fetch(.init(provider: .kimi, mode: .localProxy))

    XCTAssertEqual(Set(output.quotas.keys), ["kimi@example.com"])
    let request = try await XCTUnwrapAsync(await session.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer file-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Msh-Device-Id"), "file-device")
  }

  // MARK: - Credential access

  func testKimiScopedRefreshUsesInteractiveCredentialOnlyWhenAllowed() async throws {
    let account = vaultAccount(.kimi, "Personal")
    let vault = InteractiveVault(account: account, userInitiatedKey: "fixture-kimi-key")
    let session = ScriptedSession { _ in .status(200, Self.kimiBody) }
    let fetcher = makeKimiFetcher(
      files: FakeFileReader(files: [:]), session: session, vault: vault)

    let background = try await fetcher.fetch(
      .init(provider: .kimi, scope: .account("Personal"), mode: .monitor))
    XCTAssertTrue(background.quotas.isEmpty)
    let backgroundReads = await vault.userInitiatedReads
    XCTAssertEqual(backgroundReads, 0)

    let providerWide = try await fetcher.fetch(
      .init(provider: .kimi, mode: .monitor, allowsUserInteraction: true))
    XCTAssertTrue(providerWide.quotas.isEmpty)
    let providerWideReads = await vault.userInitiatedReads
    XCTAssertEqual(providerWideReads, 0)

    let foreground = try await fetcher.fetch(
      .init(
        provider: .kimi, scope: .account("Personal"), mode: .monitor,
        allowsUserInteraction: true))
    XCTAssertNotNil(foreground.quotas["Personal"])
    let foregroundReads = await vault.userInitiatedReads
    XCTAssertEqual(foregroundReads, 1)
    let request = try await XCTUnwrapAsync(await session.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-kimi-key")
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Msh-Device-Id"))
  }

  func testUnreadableVaultItemKeepsTheAccountWithoutPrompting() async throws {
    let account = vaultAccount(.minimax, "Work")
    let vault = InteractiveVault(account: account, userInitiatedKey: nil, state: .unreadable)
    let fetcher = MiniMaxQuotaFetcher(
      vault: vault, metadata: FakeMetadata(),
      session: ScriptedSession { _ in .status(200, Self.miniMaxBody) })

    let output = try await fetcher.fetch(.init(provider: .minimax, mode: .monitor))

    XCTAssertTrue(output.quotas.isEmpty)
    XCTAssertEqual(output.credentialAccountKeys, ["Work"])
    XCTAssertEqual(output.credentialAvailability, .present)
    let reads = await vault.userInitiatedReads
    XCTAssertEqual(reads, 0)
  }

  // MARK: - Regional endpoints

  func testMiniMaxRemembersTheRegionThatAnsweredAndTriesItFirst() async throws {
    let account = vaultAccount(.minimax, "Work")
    let session = ScriptedSession { request in
      request.url == MiniMaxQuotaFetcher.defaultEndpoints[1]
        ? .status(200, Self.miniMaxBody) : .status(401, "{}")
    }
    let fetcher = MiniMaxQuotaFetcher(
      vault: InteractiveVault(account: account, storedKey: "sk-cp-fixture"),
      metadata: FakeMetadata(), session: session)

    let first = try await fetcher.fetch(.init(provider: .minimax, mode: .monitor))
    XCTAssertEqual(first.quotas["Work"]?.models.map(\.percentage), [75])
    let second = try await fetcher.fetch(.init(provider: .minimax, mode: .monitor))
    XCTAssertEqual(second.quotas["Work"]?.isForbidden, false)

    let urls = await session.requests().map(\.url)
    XCTAssertEqual(
      urls,
      [
        MiniMaxQuotaFetcher.defaultEndpoints[0], MiniMaxQuotaFetcher.defaultEndpoints[1],
        MiniMaxQuotaFetcher.defaultEndpoints[1],
      ])
  }

  func testForbiddenOnlyWhenEveryRegionRefusesTheKey() async throws {
    let account = vaultAccount(.minimax, "Work")
    func fetch(_ handler: @escaping ScriptedSession.Handler) async throws -> QuotaProviderOutput {
      try await MiniMaxQuotaFetcher(
        vault: InteractiveVault(account: account, storedKey: "sk-cp-fixture"),
        metadata: FakeMetadata(), session: ScriptedSession(handler: handler)
      ).fetch(.init(provider: .minimax, mode: .monitor))
    }

    let networkThenRefused = try await fetch { request in
      request.url == MiniMaxQuotaFetcher.defaultEndpoints[0] ? .networkError : .status(401, "{}")
    }
    XCTAssertNil(networkThenRefused.quotas["Work"])
    XCTAssertEqual(networkThenRefused.credentialAccountKeys, ["Work"])

    let serverErrorThenRefused = try await fetch { request in
      request.url == MiniMaxQuotaFetcher.defaultEndpoints[0]
        ? .status(503, "busy") : .status(403, "{}")
    }
    XCTAssertNil(serverErrorThenRefused.quotas["Work"])

    let refusedEverywhere = try await fetch { request in
      request.url == MiniMaxQuotaFetcher.defaultEndpoints[0]
        ? .status(401, "{}")
        : .status(200, #"{"base_resp":{"status_code":1004,"status_msg":"invalid key"}}"#)
    }
    XCTAssertEqual(refusedEverywhere.quotas["Work"]?.isForbidden, true)

    let nonPlanKey = try await fetch { _ in
      .status(200, #"{"base_resp":{"status_code":2049,"status_msg":"not a plan key"}}"#)
    }
    XCTAssertEqual(nonPlanKey.quotas["Work"]?.isForbidden, true)
  }

  func testKimiReportsFailureRatherThanForbiddenWhenOneRegionIsUnreachable() async throws {
    let account = vaultAccount(.kimi, "Personal")
    let session = ScriptedSession { request in
      request.url == KimiQuotaFetcher.defaultEndpoints[0] ? .networkError : .status(401, "{}")
    }
    let fetcher = makeKimiFetcher(
      files: FakeFileReader(files: [:]), session: session,
      vault: InteractiveVault(account: account, storedKey: "sk-kimi-fixture"))

    let output = try await fetcher.fetch(.init(provider: .kimi, mode: .monitor))

    XCTAssertNil(output.quotas["Personal"])
    XCTAssertEqual(output.credentialAccountKeys, ["Personal"])
  }

  func testMiniMaxIsMonitorOnlyAndHonorsDisabledAccounts() async throws {
    let account = vaultAccount(.minimax, "Work")
    let session = ScriptedSession { _ in .status(200, Self.miniMaxBody) }
    let vault = InteractiveVault(account: account, storedKey: "sk-cp-fixture")
    let local = try await MiniMaxQuotaFetcher(
      vault: vault, metadata: FakeMetadata(), session: session
    ).fetch(.init(provider: .minimax, mode: .localProxy))
    XCTAssertEqual(local.credentialAvailability, .missing)

    let disabled = try await MiniMaxQuotaFetcher(
      vault: vault, metadata: FakeMetadata(disabled: [account.id]), session: session
    ).fetch(.init(provider: .minimax, mode: .monitor))
    XCTAssertTrue(disabled.quotas.isEmpty)
    XCTAssertEqual(disabled.credentialAvailability, .missing)
    let requests = await session.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  // MARK: - Fixtures

  private static let kimiBody = #"""
    {"limits":[{"detail":{"used":1,"limit":4},"window":{"duration":300,"timeUnit":"MINUTE"}}]}
    """#
  private static let miniMaxBody = #"""
    {"model_remains":[{"model_name":"general","current_interval_total_count":4,"current_interval_usage_count":1}],"base_resp":{"status_code":0}}
    """#

  private var home: URL { directory.appendingPathComponent("home", isDirectory: true) }
  private var cliCredentialPath: String {
    home.appendingPathComponent(KimiLocalCredentialReader.cliCredentialPath).path
  }

  private func makeKimiFetcher(
    files: FakeFileReader,
    session: ScriptedSession,
    now: Date = Date(),
    vault: (any CredentialVault)? = nil,
    authFiles: (any AuthFileRepository)? = nil,
    identity: KimiDeviceIdentity? = nil
  ) -> KimiQuotaFetcher {
    KimiQuotaFetcher(
      vault: vault ?? InteractiveVault(account: nil),
      metadata: FakeMetadata(),
      authFiles: authFiles ?? EmptyAuthFiles(),
      deviceIdentity: identity
        ?? KimiDeviceIdentity(url: directory.appendingPathComponent("kimi-device-id")),
      files: files,
      homeDirectory: home,
      session: session,
      appVersion: "test",
      now: { now }
    )
  }

  private func vaultAccount(_ provider: QuotaProvider, _ key: String) -> Account {
    Account.make(
      providerID: .init(rawValue: provider.rawValue), accountKey: key, source: .quotioKeychain)
  }
}

private func XCTUnwrapAsync<T>(
  _ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
  let resolved = try await value()
  return try XCTUnwrap(resolved, file: file, line: line)
}

private actor ScriptedSession: QuotaHTTPSession {
  enum Reply: Sendable {
    case status(Int, String)
    case networkError
  }
  typealias Handler = @Sendable (URLRequest) -> Reply

  private let handler: Handler
  private var recorded: [URLRequest] = []

  init(handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    switch handler(request) {
    case .networkError:
      throw URLError(.cannotConnectToHost)
    case .status(let status, let body):
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  func requests() -> [URLRequest] { recorded }
}

private actor FakeFileReader: QuotaCredentialFileReading {
  private let files: [String: Data]
  init(files: [String: Data]) { self.files = files }
  func read(path: String) async -> Data? { files[path] }
}

private actor EmptyAuthFiles: AuthFileRepository {
  func scanAllAuthFiles() async -> [AuthFileDescriptor] { [] }
  func readCredential(from file: AuthFileDescriptor) async -> AuthFileCredential? { nil }
  func uploadAuthFile(name: String, content: Data) async throws {}
  func readAuthFileForImport(from url: URL) async throws -> Data { Data() }
  func writeDownloadedAuthFile(_ content: Data, to url: URL) async throws {}
  func downloadAuthFile(name: String) async throws -> Data { Data() }
}

/// Declares every `CredentialVault` requirement as `async` so calls on this concrete type
/// never fall back to the protocol-extension defaults.
private actor InteractiveVault: CredentialVault {
  private let account: Account?
  private let storedKey: String?
  private let userInitiatedKey: String?
  private let state: StoredCredentialState
  private(set) var userInitiatedReads = 0

  init(
    account: Account?,
    storedKey: String? = nil,
    userInitiatedKey: String? = nil,
    state: StoredCredentialState = .absent
  ) {
    self.account = account
    self.storedKey = storedKey
    self.userInitiatedKey = userInitiatedKey
    self.state = state
  }

  func accounts() async -> [Account] { account.map { [$0] } ?? [] }

  func credential(for accountID: String) async -> StoredCredential? {
    guard accountID == account?.id else { return nil }
    return storedKey.map(Self.credential)
  }

  func credentialForUserInitiatedAccess(for accountID: String) async -> StoredCredential? {
    userInitiatedReads += 1
    guard accountID == account?.id else { return nil }
    return (userInitiatedKey ?? storedKey).map(Self.credential)
  }

  func credentialState(for accountID: String) async -> StoredCredentialState {
    storedKey == nil ? state : .available
  }

  func reloadLatest(accountID: String) async -> StoredCredential? {
    await credential(for: accountID)
  }

  func save(_ credential: StoredCredential, metadata: Account) async throws {}
  func saveUserInitiated(_ credential: StoredCredential, metadata: Account) async throws {}
  func delete(accountID: String) async {}

  private static func credential(_ key: String) -> StoredCredential {
    StoredCredential(
      accessToken: key, refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:]
    )
  }
}

private actor FakeMetadata: AccountMetadataRepository {
  private let disabled: Set<String>
  init(disabled: Set<String> = []) { self.disabled = disabled }
  func accounts() async -> [Account] { [] }
  func disabledAccountIDs() async -> Set<String> { disabled }
  func saveAccount(_ account: Account) async throws {}
  func deleteAccount(_ accountID: String) async throws {}
  func setDisabled(_ disabled: Bool, accountID: String) async throws {}
}
