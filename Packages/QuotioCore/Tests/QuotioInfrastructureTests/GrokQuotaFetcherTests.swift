import Darwin
import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class GrokQuotaFetcherTests: XCTestCase {
  private let entryKey = "https://auth.x.ai::client-a"

  private func billing(_ config: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["config": config])
  }

  private func authFile(_ contents: [String: Any]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("auth.json")
    try JSONSerialization.data(withJSONObject: contents).write(to: url)
    return url
  }

  private func entry(key: String, refresh: String, expiresAt: String? = nil) -> [String: Any] {
    var value: [String: Any] = [
      "key": key,
      "refresh_token": refresh,
      "auth_mode": "oidc",
      "oidc_issuer": "https://auth.x.ai",
      "oidc_client_id": "client-a",
      "email": "person@example.com",
    ]
    if let expiresAt { value["expires_at"] = expiresAt }
    return value
  }

  /// The live response stamps period bounds with microseconds and a `+00:00` offset.
  func testMapsWeeklyUsageCreditsAndSpendFromCents() throws {
    let data = try billing([
      "creditUsagePercent": 3,
      "currentPeriod": [
        "type": "USAGE_PERIOD_TYPE_WEEKLY",
        "start": "2026-09-14T00:00:00.123456+00:00",
        "end": "2026-09-21T00:00:00.654321+00:00",
      ],
      "onDemandCap": ["val": 2500],
      "onDemandUsed": ["val": -500],
      "prepaidBalance": ["val": 1250],
    ])

    let quota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(data, plan: "SuperGrok", displayName: "person@example.com"))

    let weekly = try XCTUnwrap(quota.models.first { $0.name == "grok-weekly" })
    XCTAssertEqual(weekly.percentage, 97)
    XCTAssertEqual(
      GrokQuotaFetcher.parseDate(weekly.resetTime),
      GrokQuotaFetcher.parseDate("2026-09-21T00:00:00Z"))
    let extra = try XCTUnwrap(quota.models.first { $0.name == "grok-extra-usage" })
    XCTAssertEqual(extra.percentage, 80)
    XCTAssertEqual(extra.presentation, .progress(used: 5, limit: 25, unit: .usd))
    let credits = try XCTUnwrap(quota.models.first { $0.name == "grok-credits" })
    XCTAssertEqual(credits.presentation, .amount(value: 12.5, unit: .usd, semantics: .balance))
    XCTAssertEqual(quota.planType, "SuperGrok")
    XCTAssertEqual(quota.accountDisplayName, "person@example.com")
  }

  func testMapsMonthlyPeriodCapWithoutSpendAndZeroCapAsDisabled() throws {
    let capped = try billing([
      "creditUsagePercent": 25,
      "currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "2030-02-01T00:00:00Z"],
      "onDemandCap": ["val": 2500],
    ])
    // proto3 omits a zero scalar, so an inactive cap arrives as an empty Cent.
    let disabled = try billing([
      "creditUsagePercent": 100,
      "currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "2030-02-01T00:00:00Z"],
      "onDemandCap": [String: Any](),
    ])

    let cappedQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(capped, plan: nil, displayName: "person"))
    let disabledQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(disabled, plan: nil, displayName: "person"))

    XCTAssertEqual(cappedQuota.models.first { $0.name == "grok-monthly" }?.percentage, 75)
    XCTAssertNil(cappedQuota.models.first { $0.name == "grok-weekly" })
    XCTAssertEqual(
      cappedQuota.models.first { $0.name == "grok-extra-usage" }?.presentation,
      .status(text: "grok-cap:$25.00"))
    XCTAssertEqual(disabledQuota.models.first { $0.name == "grok-monthly" }?.percentage, 0)
    XCTAssertEqual(
      disabledQuota.models.first { $0.name == "grok-extra-usage" }?.presentation,
      .status(text: "grok-disabled"))
  }

  func testDerivesMonthlyUsageFromLegacyCentBudgetAndUsageWithoutPeriod() throws {
    let legacy = try billing([
      "monthlyLimit": ["val": 2000],
      "used": ["val": 500],
      "billingPeriodEnd": "2026-10-01T00:00:00Z",
    ])
    let unknownPeriod = try billing(["creditUsagePercent": 40])

    let legacyQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(legacy, plan: nil, displayName: "person"))
    let usageQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(unknownPeriod, plan: nil, displayName: "person"))

    let monthly = try XCTUnwrap(legacyQuota.models.first { $0.name == "grok-monthly" })
    XCTAssertEqual(monthly.percentage, 75)
    XCTAssertEqual(
      GrokQuotaFetcher.parseDate(monthly.resetTime),
      GrokQuotaFetcher.parseDate("2026-10-01T00:00:00Z"))
    XCTAssertEqual(usageQuota.models.first { $0.name == "grok-usage" }?.percentage, 60)
  }

  /// A response without any usage figure must not read as an untouched allowance.
  func testAbsentUsageIsOmittedRatherThanReportedAsFullAllowance() throws {
    let withoutUsage = try billing([
      "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-09-21T00:00:00Z"],
      "onDemandCap": ["val": 0],
    ])

    let quota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(withoutUsage, plan: nil, displayName: "person"))

    XCTAssertNil(quota.models.first { $0.name == "grok-weekly" || $0.name == "grok-usage" })
    XCTAssertNil(GrokQuotaFetcher.mapBilling(try billing([:]), plan: nil, displayName: "person"))
    XCTAssertNil(GrokQuotaFetcher.mapBilling(Data("not json".utf8), plan: nil, displayName: "p"))
  }

  func testLoadCandidatesKeepsFirstPartySessionsAndSkipsAPIKeyAndForeignIdP() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "token-a", refresh: "refresh-a", expiresAt: "2030-01-01T00:00:00.123456Z"),
      // Legacy relay login: first-party, but without an OAuth2 refresh grant.
      "https://accounts.x.ai/sign-in": [
        "key": "legacy-token", "refresh_token": "legacy-refresh", "user_id": "user-1",
      ],
      // Externally minted token: its helper command owns rotation.
      "https://auth.x.ai::client-c": [
        "key": "token-c", "refresh_token": "helper-refresh", "auth_mode": "external",
        "oidc_issuer": "https://auth.x.ai", "oidc_client_id": "client-c",
      ],
      "xai::api_key": ["key": "api-key-value", "auth_mode": "api_key"],
      "https://login.example.com::client-b": [
        "key": "token-b", "refresh_token": "refresh-b", "auth_mode": "oidc",
        "oidc_issuer": "https://login.example.com", "oidc_client_id": "client-b",
      ],
      "invalid": ["refresh_token": "refresh-only"],
    ])

    let candidates = GrokQuotaFetcher.loadCandidates(data: data)

    XCTAssertEqual(
      candidates.map(\.entryKey),
      ["https://accounts.x.ai/sign-in", entryKey, "https://auth.x.ai::client-c"])
    let session = try XCTUnwrap(candidates.first { $0.entryKey == entryKey })
    XCTAssertEqual(session.displayName, "person@example.com")
    XCTAssertEqual(
      try XCTUnwrap(session.expiresAt).timeIntervalSince1970,
      try XCTUnwrap(GrokQuotaFetcher.parseDate("2030-01-01T00:00:00Z")).timeIntervalSince1970,
      accuracy: 1)
    XCTAssertEqual(
      GrokQuotaFetcher.refreshEndpoint(for: session)?.absoluteString,
      "https://auth.x.ai/oauth2/token")
    XCTAssertEqual(
      candidates.first { $0.entryKey == "https://accounts.x.ai/sign-in" }?.displayName, "user-1")
    for unrefreshable in ["https://accounts.x.ai/sign-in", "https://auth.x.ai::client-c"] {
      let candidate = try XCTUnwrap(candidates.first { $0.entryKey == unrefreshable })
      XCTAssertNil(GrokQuotaFetcher.refreshEndpoint(for: candidate))
    }
  }

  func testAuthPathHonoursGrokCLIEnvironment() {
    let home = URL(fileURLWithPath: "/Users/someone")
    XCTAssertEqual(
      GrokQuotaFetcher.authPath(environment: ["GROK_AUTH_PATH": "/custom/auth.json"], homeDirectory: home),
      "/custom/auth.json")
    XCTAssertEqual(
      GrokQuotaFetcher.authPath(environment: ["GROK_HOME": "/grok"], homeDirectory: home),
      "/grok/auth.json")
    XCTAssertEqual(
      GrokQuotaFetcher.authPath(environment: [:], homeDirectory: home),
      "/Users/someone/.grok/auth.json")
  }

  func testScopedFetchMapsPlanHeadersAndForbidden() async throws {
    let auth = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "token-a", refresh: "refresh-a", expiresAt: "2030-01-01T00:00:00Z"),
      "https://auth.x.ai::client-b": [
        "key": "denied", "oidc_issuer": "https://auth.x.ai", "oidc_client_id": "client-b",
      ],
    ])
    let session = GrokSession { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
      switch request.url!.path {
      case "/v1/settings": return (#"{"subscription_tier_display":"SuperGrok"}"#, 200)
      default:
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer denied" { return ("", 403) }
        return (
          #"{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-08T00:00:00Z"}}}"#,
          200)
      }
    }
    let fetcher = GrokQuotaFetcher(
      files: GrokFiles(auth), writer: GrokWriter(lockAvailable: true), session: session,
      authPath: "/auth.json", now: { Date(timeIntervalSince1970: 1_700_000_000) })

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(.init(provider: .grok, scope: .account(entryKey), mode: mode))
      XCTAssertEqual(output.credentialAccountKeys, [entryKey])
      XCTAssertEqual(output.quotas[entryKey]?.planType, "SuperGrok")
      XCTAssertEqual(output.quotas[entryKey]?.models.first?.percentage, 75)
    }
    let denied = try await fetcher.fetch(
      .init(provider: .grok, scope: .account("https://auth.x.ai::client-b"), mode: .monitor))
    XCTAssertEqual(denied.quotas["https://auth.x.ai::client-b"]?.isForbidden, true)
    XCTAssertEqual(
      denied.quotas["https://auth.x.ai::client-b"]?.accountDisplayName, "Grok https://")
  }

  /// Spending the CLI's single-use refresh token and then failing to write its
  /// successor logs the Grok CLI out, so a busy lock means no refresh at all.
  func testRefreshIsSkippedEntirelyWhenTheAuthFileLockIsUnavailable() async throws {
    let auth = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "expired", refresh: "refresh-a", expiresAt: "2020-01-01T00:00:00Z")
    ])
    let session = GrokSession { request in
      request.url!.path == "/oauth2/token"
        ? (#"{"access_token":"rotated","refresh_token":"new-refresh","expires_in":3600}"#, 200)
        : ("", 401)
    }
    let writer = GrokWriter(lockAvailable: false)
    let fetcher = GrokQuotaFetcher(
      files: GrokFiles(auth), writer: writer, session: session, authPath: "/auth.json")

    let output = try await fetcher.fetch(.init(provider: .grok, mode: .monitor))

    XCTAssertEqual(output.quotas[entryKey]?.isForbidden, true)
    XCTAssertFalse(session.paths().contains("/oauth2/token"))
    let persisted = await writer.persisted()
    XCTAssertTrue(persisted.isEmpty)
  }

  func testRefreshCallsTheTokenEndpointOnlyWhileHoldingTheLockAndPersistsUnderIt() async throws {
    let auth = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "expired", refresh: "refresh-a", expiresAt: "2020-01-01T00:00:00Z")
    ])
    let writer = GrokWriter(lockAvailable: true)
    let lock = writer.lockState
    let session = GrokSession { request in
      if request.url!.path == "/oauth2/token" {
        XCTAssertTrue(lock.isHeld, "The token endpoint must be called under auth.json.lock")
        return (#"{"access_token":"rotated","refresh_token":"new-refresh","expires_in":3600}"#, 200)
      }
      if request.value(forHTTPHeaderField: "Authorization") != "Bearer rotated" { return ("", 401) }
      return (#"{"config":{"creditUsagePercent":10}}"#, 200)
    }
    let fetcher = GrokQuotaFetcher(
      files: GrokFiles(auth), writer: writer, session: session, authPath: "/auth.json")

    let output = try await fetcher.fetch(.init(provider: .grok, mode: .monitor))

    XCTAssertEqual(output.quotas[entryKey]?.models.first?.percentage, 90)
    let persisted = await writer.persisted()
    XCTAssertEqual(persisted.map(\.accessToken), ["rotated"])
    XCTAssertEqual(persisted.map(\.heldLock), [true])
    XCTAssertEqual(session.paths().filter { $0 == "/oauth2/token" }.count, 1)
  }

  func testSiblingRotationSeenUnderTheLockIsAdoptedWithoutRefreshing() async throws {
    let stale = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "expired", refresh: "refresh-a", expiresAt: "2020-01-01T00:00:00Z")
    ])
    let rotated = try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "sibling", refresh: "sibling-refresh", expiresAt: "2030-01-01T00:00:00Z")
    ])
    let session = GrokSession { request in
      if request.url!.path == "/oauth2/token" { return ("", 500) }
      if request.value(forHTTPHeaderField: "Authorization") != "Bearer sibling" { return ("", 401) }
      return (#"{"config":{"creditUsagePercent":20}}"#, 200)
    }
    let fetcher = GrokQuotaFetcher(
      files: GrokFiles([stale, rotated]), writer: GrokWriter(lockAvailable: true),
      session: session, authPath: "/auth.json")

    let output = try await fetcher.fetch(.init(provider: .grok, mode: .monitor))

    XCTAssertEqual(output.quotas[entryKey]?.models.first?.percentage, 80)
    XCTAssertFalse(session.paths().contains("/oauth2/token"))
  }

  func testLocalWriterLockIsExclusiveAgainstAnotherHolder() async throws {
    let url = try authFile([entryKey: entry(key: "old", refresh: "old-refresh")])
    let lockPath = url.deletingLastPathComponent().appendingPathComponent("auth.json.lock").path
    let descriptor = open(lockPath, O_RDWR | O_CREAT, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

    let blocked = await LocalGrokCredentialWriter().withAuthFileLock(path: url.path) { true }
    XCTAssertNil(blocked)

    flock(descriptor, LOCK_UN)
    let acquired = await LocalGrokCredentialWriter().withAuthFileLock(path: url.path) { true }
    XCTAssertEqual(acquired, true)
  }

  func testRotationRewritesOnlyItsOwnEntryAndPreservesUnknownFields() async throws {
    var own = entry(key: "old", refresh: "old-refresh")
    own["coding_data_retention_opt_out"] = true
    let url = try authFile([
      entryKey: own,
      "https://auth.x.ai::client-b": ["key": "sibling-token", "custom": 42],
    ])
    let candidate = try XCTUnwrap(
      GrokQuotaFetcher.loadCandidates(data: Data(contentsOf: url)).first { $0.entryKey == entryKey })

    let stored = try await LocalGrokCredentialWriter().persistRotation(
      path: url.path, expected: candidate, accessToken: "new", refreshToken: "new-refresh",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertTrue(stored)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let updated = try XCTUnwrap(root[entryKey] as? [String: Any])
    XCTAssertEqual(updated["key"] as? String, "new")
    XCTAssertEqual(updated["refresh_token"] as? String, "new-refresh")
    XCTAssertEqual(
      (updated["expires_at"] as? String).flatMap(GrokQuotaFetcher.parseDate),
      Date(timeIntervalSince1970: 1_900_000_000))
    XCTAssertEqual(
      (updated["create_time"] as? String).flatMap(GrokQuotaFetcher.parseDate),
      Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(updated["coding_data_retention_opt_out"] as? Bool, true)
    XCTAssertEqual(
      (root["https://auth.x.ai::client-b"] as? [String: Any])?["key"] as? String, "sibling-token")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  /// Without `expires_in` a stale expiry would keep forcing (or suppressing) refreshes.
  func testRotationWithoutServerExpiryClearsStoredExpiry() async throws {
    let url = try authFile([
      entryKey: entry(key: "old", refresh: "old-refresh", expiresAt: "2020-01-01T00:00:00Z")
    ])
    let candidate = try XCTUnwrap(
      GrokQuotaFetcher.loadCandidates(data: Data(contentsOf: url)).first)

    let stored = try await LocalGrokCredentialWriter().persistRotation(
      path: url.path, expected: candidate, accessToken: "new", refreshToken: nil, expiresAt: nil,
      createdAt: Date())

    XCTAssertTrue(stored)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let updated = try XCTUnwrap(root[entryKey] as? [String: Any])
    XCTAssertNil(updated["expires_at"])
    XCTAssertEqual(updated["refresh_token"] as? String, "old-refresh")
  }

  func testRotationRefusesToOverwriteACredentialRotatedByAnotherProcessOrASymlink() async throws {
    let url = try authFile([entryKey: entry(key: "old", refresh: "old-refresh")])
    let candidate = try XCTUnwrap(
      GrokQuotaFetcher.loadCandidates(data: Data(contentsOf: url)).first)
    try JSONSerialization.data(withJSONObject: [
      entryKey: entry(key: "sibling-token", refresh: "sibling-refresh")
    ]).write(to: url)

    let stored = try await LocalGrokCredentialWriter().persistRotation(
      path: url.path, expected: candidate, accessToken: "ours", refreshToken: "ours-refresh",
      expiresAt: nil, createdAt: Date())

    XCTAssertFalse(stored)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual((root[entryKey] as? [String: Any])?["key"] as? String, "sibling-token")

    let link = url.deletingLastPathComponent().appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    do {
      _ = try await LocalGrokCredentialWriter().persistRotation(
        path: link.path, expected: candidate, accessToken: "bad", refreshToken: nil,
        expiresAt: nil, createdAt: Date())
      XCTFail("Expected a symbolic-link destination to be refused")
    } catch {}
  }
}

/// Serves each queued file content once, repeating the last.
private actor GrokFiles: QuotaCredentialFileReading {
  private var contents: [Data]
  init(_ data: Data) { contents = [data] }
  init(_ data: [Data]) { contents = data }
  func read(path: String) -> Data? {
    contents.count > 1 ? contents.removeFirst() : contents.first
  }
}

private final class GrokLockState: @unchecked Sendable {
  private let lock = NSLock()
  private var held = false
  var isHeld: Bool {
    get { lock.withLock { held } }
    set { lock.withLock { held = newValue } }
  }
}

private actor GrokWriter: GrokCredentialWriting {
  struct Persisted: Sendable {
    let accessToken: String
    let heldLock: Bool
  }

  nonisolated let lockState = GrokLockState()
  private let lockAvailable: Bool
  private var records: [Persisted] = []

  init(lockAvailable: Bool) { self.lockAvailable = lockAvailable }

  func withAuthFileLock<T: Sendable>(path: String, _ body: @Sendable () async -> T) async -> T? {
    guard lockAvailable else { return nil }
    lockState.isHeld = true
    let value = await body()
    lockState.isHeld = false
    return value
  }

  func persistRotation(
    path: String, expected: GrokQuotaFetcher.Candidate, accessToken: String,
    refreshToken: String?, expiresAt: Date?, createdAt: Date
  ) async throws -> Bool {
    records.append(Persisted(accessToken: accessToken, heldLock: lockState.isHeld))
    return true
  }

  func persisted() -> [Persisted] { records }
}

private final class GrokSession: QuotaHTTPSession, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private let lock = NSLock()
  private var recorded: [String] = []

  init(_ handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lock.withLock { recorded.append(request.url!.path) }
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }

  func paths() -> [String] { lock.withLock { recorded } }
}
