import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class KiroAccountIdentityTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".cli-proxy-api"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".aws/sso/cache"), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func write(_ object: [String: Any], to relativePath: String) throws {
    try JSONSerialization.data(withJSONObject: object)
      .write(to: home.appendingPathComponent(relativePath))
  }

  func testLocalCredentialsUseCanonicalKeysAndKeepOldKeysAsAliases() async throws {
    try write(
      ["type": "kiro", "access_token": "google", "provider": "Google"],
      to: ".cli-proxy-api/kiro-google-1.json")
    try write(
      [
        "accessToken": "native", "email": "dev@example.com",
        "profileArn": "arn:aws:codewhisperer:us-east-1:1:profile/A",
      ],
      to: ".aws/sso/cache/kiro-auth-token.json")

    let credentials = await LocalKiroQuotaCredentialSource(homeDirectory: home.path).credentials()
    let byToken = Dictionary(uniqueKeysWithValues: credentials.map { ($0.accessToken, $0) })

    XCTAssertEqual(byToken["google"]?.accountKey, "kiro-google-1")
    XCTAssertEqual(byToken["google"]?.aliases, ["Kiro (Google)"])
    XCTAssertEqual(byToken["native"]?.accountKey, "arn:aws:codewhisperer:us-east-1:1:profile/A")
    XCTAssertEqual(byToken["native"]?.aliases, ["dev@example.com", "kiro-auth-token"])
  }

  func testFetcherPublishesUnambiguousAliasesAndAnswersScopedRequestsForOldKeys() async throws {
    let source = KiroFixedSource([
      KiroQuotaCredential(
        accessToken: "a", region: "us-east-1", accountKey: "kiro-google-1",
        aliases: ["Kiro (Google)", "shared@example.com"]),
      KiroQuotaCredential(
        accessToken: "b", region: "us-east-1", accountKey: "kiro-google-2",
        aliases: ["shared@example.com"]),
    ])
    let session = CodexScriptedSession { _ in
      (#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":10,"usageLimit":100}]}"#, 200)
    }
    let fetcher = KiroQuotaFetcher(
      vault: CodexTestVault(accounts: [], readable: [:]), metadata: CodexTestMetadata(),
      credentials: source, session: session, machineIdentifier: { _ in "machine" })

    let output = try await fetcher.fetch(
      .init(provider: .kiro, scope: .account("Kiro (Google)"), mode: .monitor))

    XCTAssertEqual(output.quotas.keys.sorted(), ["kiro-google-1"])
    XCTAssertEqual(output.accountAliases, ["Kiro (Google)": "kiro-google-1"])
  }

  func testUsageWithoutLimitsIsNotFabricatedAsAFullAllowance() async throws {
    let source = KiroFixedSource([
      KiroQuotaCredential(accessToken: "a", region: "us-east-1", accountKey: "dev@example.com")
    ])
    let session = CodexScriptedSession { _ in
      (#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":0,"usageLimit":0,"freeTrialInfo":{"freeTrialStatus":"ACTIVE","usageLimit":0}}]}"#, 200)
    }
    let fetcher = KiroQuotaFetcher(
      vault: CodexTestVault(accounts: [], readable: [:]), metadata: CodexTestMetadata(),
      credentials: source, session: session, machineIdentifier: { _ in "machine" })

    let output = try await fetcher.fetch(.init(provider: .kiro, mode: .monitor))

    XCTAssertEqual(output.quotas["dev@example.com"]?.models, [])
    XCTAssertEqual(output.quotas["dev@example.com"]?.isForbidden, false)
  }

  func testFailedProactiveRefreshStillAsksTheUsageEndpoint() async throws {
    let source = KiroFixedSource([
      KiroQuotaCredential(
        accessToken: "still-valid", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(30),
        clientID: "client", clientSecret: "secret", region: "us-east-1",
        accountKey: "dev@example.com")
    ])
    let session = CodexScriptedSession { request in
      request.url?.host == "oidc.us-east-1.amazonaws.com"
        ? ("", 500)
        : (#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":25,"usageLimit":100}]}"#, 200)
    }
    let fetcher = KiroQuotaFetcher(
      vault: CodexTestVault(accounts: [], readable: [:]), metadata: CodexTestMetadata(),
      credentials: source, session: session, machineIdentifier: { _ in "machine" })

    let output = try await fetcher.fetch(.init(provider: .kiro, mode: .monitor))

    let quota = try XCTUnwrap(output.quotas["dev@example.com"])
    XCTAssertFalse(quota.isForbidden)
    XCTAssertEqual(quota.models.first?.percentage, 75)
  }

  func testAuthFileScanKeysKiroByProfileAndKeepsSyntheticKeysAsAliases() async throws {
    let directory = home.appendingPathComponent(".cli-proxy-api")
    try write(
      ["type": "kiro", "access_token": "a", "provider": "Google"],
      to: ".cli-proxy-api/kiro-google-1.json")
    try write(
      ["type": "kiro", "access_token": "b", "email": "dev@example.com", "profile_arn": "arn:profile/B"],
      to: ".cli-proxy-api/kiro-b.json")

    let files = await FileAuthFileRepository(authDirectory: directory).scanAllAuthFiles()
    let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0) })

    XCTAssertEqual(byName["kiro-google-1.json"]?.menuBarAccountKey, "kiro-google-1")
    XCTAssertNil(byName["kiro-google-1.json"]?.email)
    XCTAssertEqual(byName["kiro-google-1.json"]?.legacyIdentityKeys, ["Kiro (Google)"])
    XCTAssertEqual(byName["kiro-b.json"]?.menuBarAccountKey, "arn:profile/B")
    XCTAssertEqual(byName["kiro-b.json"]?.legacyIdentityKeys, ["dev@example.com", "kiro-b"])
  }

  func testDiscoveryReconcilesProvenAliasesAndHonoursRemovalMarkers() async throws {
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    try write(
      [
        "tokens": [
          "access_token": "cli",
          "account_id": "account-1",
          "id_token": CodexQuotaFetcherTests.jwt(["email": "someone@mail.com"]),
        ]
      ],
      to: ".codex/auth.json")
    let kiroFile = AuthFileDescriptor(
      id: "kiro", providerID: AccountProviderID(rawValue: QuotaProvider.kiro.rawValue),
      email: nil, login: nil, expired: nil, accountType: nil,
      filePath: home.appendingPathComponent(".cli-proxy-api/kiro-google-1.json").path,
      source: .cliProxyApi, filename: "kiro-google-1.json",
      legacyIdentityKeys: ["Kiro (Google)"])
    let removedFile = AuthFileDescriptor(
      id: "removed", providerID: AccountProviderID(rawValue: QuotaProvider.kiro.rawValue),
      email: "gone@example.com", login: nil, expired: nil, accountType: nil,
      filePath: home.appendingPathComponent(".cli-proxy-api/kiro-gone.json").path,
      source: .cliProxyApi, filename: "kiro-gone.json")
    let removedID = LocalAccountDiscovery.legacyAccount(removedFile).id
    let metadata = RecordingDiscoveryMetadata(removed: [removedID])
    let discovery = LocalAccountDiscovery(
      vault: CodexTestVault(accounts: [], readable: [:]),
      authFileRepository: FixedAuthFiles([kiroFile, removedFile]),
      metadataRepository: metadata,
      externalCredentials: CodexTestKeychain(nil),
      environment: [:],
      homeDirectory: home,
      factoryCredentials: NoFactoryCredential(),
      kiroCredentials: LocalKiroQuotaCredentialSource(homeDirectory: home.path),
      quotaFiles: LocalQuotaCredentialFileReader(),
      devinDatabase: NoDevinDatabase(),
      claudeDesktop: ClaudeDesktopCredentialReader(
        appSupportPath: home.appendingPathComponent("Claude").path,
        externalCredentials: CodexTestKeychain(nil)),
      antigravityDatabase: AntigravitySwitchDatabase(
        databaseURL: home.appendingPathComponent("state.vscdb"))
    )

    let accounts = await discovery.discoverAccounts()

    let codex = try XCTUnwrap(accounts.first { $0.providerID.rawValue == QuotaProvider.codex.rawValue })
    XCTAssertEqual(codex.accountKey, "someone@mail.com • 07e99801")
    XCTAssertEqual(codex.displayName, "someone@mail.com")
    XCTAssertFalse(accounts.contains { $0.id == removedID })
    let kiro = try XCTUnwrap(accounts.first { $0.providerID.rawValue == QuotaProvider.kiro.rawValue })
    XCTAssertEqual(kiro.accountKey, "kiro-google-1")

    let reconciled = await metadata.reconciledAliases()
    let codexAlias = AccountIdentity.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
      accountKey: "someone@mail.com"
    ).id
    let kiroAlias = AccountIdentity.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.kiro.rawValue),
      accountKey: "Kiro (Google)"
    ).id
    XCTAssertEqual(reconciled[codex.id], [codexAlias])
    XCTAssertEqual(reconciled[kiro.id], [kiroAlias])
  }
}

private actor KiroFixedSource: KiroQuotaCredentialSourcing {
  let values: [KiroQuotaCredential]
  init(_ values: [KiroQuotaCredential]) { self.values = values }
  func credentials() async -> [KiroQuotaCredential] { values }
  func reload(path: String) async -> KiroQuotaCredential? { nil }
  func persist(
    path: String, expectedRefreshToken: String, accessToken: String, refreshToken: String?,
    expiresAt: Date
  ) async {}
}

private actor RecordingDiscoveryMetadata: AccountMetadataRepository {
  private let removed: Set<String>
  private var aliases: [String: Set<String>] = [:]

  init(removed: Set<String>) { self.removed = removed }

  func accounts() async -> [Account] { [] }
  func disabledAccountIDs() async -> Set<String> { [] }
  func saveAccount(_ account: Account) async throws {}
  func deleteAccount(_ accountID: String) async throws {}
  func setDisabled(_ disabled: Bool, accountID: String) async throws {}
  func reconcileAliases(_ aliasesByIdentity: [String: Set<String>]) async throws {
    aliases = aliasesByIdentity
  }
  func filteringAccounts(_ accounts: [Account]) async -> [Account] {
    accounts.filter { !removed.contains($0.id) }
  }

  func reconciledAliases() -> [String: Set<String>] { aliases }
}

private actor FixedAuthFiles: AuthFileRepository {
  private let files: [AuthFileDescriptor]
  init(_ files: [AuthFileDescriptor]) { self.files = files }
  func scanAllAuthFiles() async -> [AuthFileDescriptor] { files }
  func readCredential(from file: AuthFileDescriptor) async -> AuthFileCredential? { nil }
  func uploadAuthFile(name: String, content: Data) async throws {}
  func readAuthFileForImport(from url: URL) async throws -> Data { Data() }
  func writeDownloadedAuthFile(_ content: Data, to url: URL) async throws {}
  func downloadAuthFile(name: String) async throws -> Data { Data() }
}

private struct NoFactoryCredential: FactoryDroidCredentialLoading {
  func load() async -> FactoryDroidCredential? { nil }
}

private struct NoDevinDatabase: DevinCredentialDatabaseReading {
  func credential(path: String) -> DevinCredential? { nil }
}
