import CoreFoundation
import Darwin
import Foundation
import QuotioApplication
import QuotioDomain

/// Rewrites rotated Grok CLI credentials under the CLI's own `auth.json.lock`.
public protocol GrokCredentialWriting: Sendable {
  /// Runs `body` while holding `auth.json.lock`, the advisory lock every `grok`
  /// process takes before rewriting `auth.json`. Returns `nil` without running `body`
  /// when the lock is held elsewhere.
  func withAuthFileLock<T: Sendable>(
    path: String,
    _ body: @Sendable () async -> T
  ) async -> T?

  /// Writes the rotated tokens into the entry they came from. Returns `false` when
  /// the stored entry no longer holds `expected`'s tokens, i.e. a sibling `grok`
  /// process already rotated it. Callers hold the auth-file lock.
  func persistRotation(
    path: String,
    expected: GrokQuotaFetcher.Candidate,
    accessToken: String,
    refreshToken: String?,
    expiresAt: Date?,
    createdAt: Date
  ) async throws -> Bool
}

public struct LocalGrokCredentialWriter: GrokCredentialWriting {
  public init() {}

  /// Takes the lock without blocking: a rotation racing the CLI is abandoned, never
  /// queued behind it. The lock file is never unlinked, and the `PID:UNIX_TS` holder
  /// stamp keeps waiting `grok` processes from judging the lock stale.
  public func withAuthFileLock<T: Sendable>(
    path: String,
    _ body: @Sendable () async -> T
  ) async -> T? {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let lockPath = url.deletingLastPathComponent().appendingPathComponent("auth.json.lock").path
    let descriptor = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
    defer { flock(descriptor, LOCK_UN) }
    let stamp = Data("\(getpid()):\(Int(Date().timeIntervalSince1970))".utf8)
    _ = ftruncate(descriptor, 0)
    _ = lseek(descriptor, 0, SEEK_SET)
    _ = stamp.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    return await body()
  }

  public func persistRotation(
    path: String,
    expected: GrokQuotaFetcher.Candidate,
    accessToken: String,
    refreshToken: String?,
    expiresAt: Date?,
    createdAt: Date
  ) async throws -> Bool {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
      throw InfrastructureQuotaFetchError.forbidden
    }
    guard let data = try? Data(contentsOf: url),
      var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var entry = root[expected.entryKey] as? [String: Any]
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    guard GrokQuotaFetcher.trimmed(entry["key"] as? String) == expected.accessToken,
      GrokQuotaFetcher.trimmed(entry["refresh_token"] as? String) == expected.refreshToken
    else { return false }

    entry["key"] = accessToken
    if let refreshToken { entry["refresh_token"] = refreshToken }
    if let expiresAt {
      entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
    } else {
      // Without `expires_in` the CLI ages the credential from `create_time`.
      entry.removeValue(forKey: "expires_at")
    }
    entry["create_time"] = ISO8601DateFormatter().string(from: createdAt)
    root[expected.entryKey] = entry
    let updated = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try SecureAtomicFileWriter.write(updated, to: url)
    return true
  }
}

public actor GrokQuotaFetcher: QuotaFetching {
  public struct Candidate: Sendable, Equatable {
    public let entryKey: String
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    /// `oidc_client_id`, or the scope-key suffix. `nil` when the file never recorded
    /// one, which makes the credential unrefreshable rather than refreshable against
    /// a guessed client.
    public let clientID: String?
    public let expiresAt: Date?
    public let email: String?
    public let userID: String?
    public let authMode: String?
    public let issuer: String
    public let principalType: String?
    public let principalID: String?

    public init(
      entryKey: String, accessToken: String, refreshToken: String? = nil, idToken: String? = nil,
      clientID: String? = nil, expiresAt: Date? = nil, email: String? = nil, userID: String? = nil,
      authMode: String? = nil, issuer: String = GrokQuotaFetcher.xaiIssuer,
      principalType: String? = nil, principalID: String? = nil
    ) {
      self.entryKey = entryKey
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.idToken = idToken
      self.clientID = clientID
      self.expiresAt = expiresAt
      self.email = email
      self.userID = userID
      self.authMode = authMode
      self.issuer = issuer
      self.principalType = principalType
      self.principalID = principalID
    }

    public var displayName: String {
      email ?? GrokQuotaFetcher.jwtClaim(idToken, "email") as? String ?? userID
        ?? "Grok " + String(entryKey.prefix(8))
    }

    func rotated(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date?)
      -> Candidate
    {
      Candidate(
        entryKey: entryKey, accessToken: accessToken, refreshToken: refreshToken,
        idToken: idToken, clientID: clientID, expiresAt: expiresAt, email: email,
        userID: userID, authMode: authMode, issuer: issuer, principalType: principalType,
        principalID: principalID)
    }
  }

  public static let authPath = "~/.grok/auth.json"
  public static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
  /// The issuer whose credentials the CLI treats as first-party xAI auth. Billing is
  /// gated on it, and only it may ever see a refresh token from this file.
  public static let xaiIssuer = "https://auth.x.ai"
  /// Pre-OIDC relay login scope: first-party, but without an OAuth refresh grant.
  public static let legacyScope = "https://accounts.x.ai/sign-in"
  /// Bare API-key scope; those credentials cannot read Grok Build billing at all.
  public static let apiKeyScope = "xai::api_key"
  public static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"
  public static let monthlyPeriodType = "USAGE_PERIOD_TYPE_MONTHLY"

  public nonisolated let provider = QuotaProvider.grok
  private let files: any QuotaCredentialFileReading
  private let writer: any GrokCredentialWriting
  private let session: any QuotaHTTPSession
  private let authPath: String
  private let billingURL: URL
  private let settingsURL: URL
  private let now: @Sendable () -> Date
  /// Rotations the CLI file could not take, keyed by entry. The spent refresh token is
  /// single-use, so the replacement must outlive the request until it is written.
  private var heldRotations: [String: (spentRefreshToken: String?, rotated: Candidate)] = [:]

  public init(
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    writer: any GrokCredentialWriting = LocalGrokCredentialWriter(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    authPath: String = GrokQuotaFetcher.authPath(
      environment: ProcessInfo.processInfo.environment),
    billingURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
    settingsURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.files = files
    self.writer = writer
    self.session = session
    self.authPath = authPath
    self.billingURL = billingURL
    self.settingsURL = settingsURL
    self.now = now
  }

  /// `GROK_AUTH_PATH`, else `$GROK_HOME/auth.json`, else `~/.grok/auth.json`, as the
  /// Grok CLI resolves it.
  public nonisolated static func authPath(
    environment: [String: String],
    homeDirectory: URL? = nil
  ) -> String {
    if let override = trimmed(environment["GROK_AUTH_PATH"]) { return override }
    if let home = trimmed(environment["GROK_HOME"]) {
      return (home as NSString).appendingPathComponent("auth.json")
    }
    if let homeDirectory {
      return homeDirectory.appendingPathComponent(".grok/auth.json").path
    }
    return authPath
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard let data = await files.read(path: authPath) else {
      return .init(
        quotas: [:], credentialAvailability: .missing, credentialAccountKeys: []
      )
    }
    let candidates = Self.loadCandidates(data: data).filter {
      Self.includes($0.entryKey, in: request.scope)
    }.map(resolvingHeldRotation)
    var quotas: [String: ProviderQuota] = [:]
    for candidate in candidates {
      if let quota = await fetchQuota(candidate) { quotas[candidate.entryKey] = quota }
    }
    return .init(
      quotas: quotas,
      credentialAvailability: candidates.isEmpty ? .missing : .present,
      credentialAccountKeys: Set(candidates.map(\.entryKey))
    )
  }

  /// Every first-party Grok CLI login in `auth.json`, one per entry. API-key entries
  /// cannot read Grok Build billing, and a customer-IdP or unknown-issuer credential
  /// is skipped rather than presented to xAI.
  public nonisolated static func loadCandidates(data: Data) -> [Candidate] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    return root.compactMap { key, raw in
      guard let entry = raw as? [String: Any], let token = trimmed(entry["key"] as? String) else {
        return nil
      }
      let authMode = trimmed(entry["auth_mode"] as? String)?.lowercased()
      guard authMode != "api_key", key != apiKeyScope,
        let issuer = issuer(entry: entry, entryKey: key),
        issuer == xaiIssuer || issuer == legacyScope
      else { return nil }
      return Candidate(
        entryKey: key, accessToken: token,
        refreshToken: trimmed(entry["refresh_token"] as? String),
        idToken: trimmed(entry["id_token"] as? String),
        clientID: trimmed(entry["oidc_client_id"] as? String)
          ?? clientID(entryKey: key, issuer: issuer),
        expiresAt: expiry(entry, token: token),
        email: trimmed(entry["email"] as? String),
        userID: trimmed(entry["user_id"] as? String),
        authMode: authMode,
        issuer: issuer,
        principalType: trimmed(entry["principal_type"] as? String),
        principalID: trimmed(entry["principal_id"] as? String))
    }.sorted { $0.entryKey < $1.entryKey }
  }

  /// The IdP token endpoint for this credential, or `nil` when it must never be
  /// refreshed here: an externally minted token (its helper command owns rotation),
  /// a legacy relay login without a refresh grant, or a credential with no client.
  public nonisolated static func refreshEndpoint(for candidate: Candidate) -> URL? {
    guard candidate.authMode != "external",
      candidate.refreshToken != nil,
      candidate.clientID != nil,
      candidate.issuer == xaiIssuer
    else { return nil }
    return URL(string: candidate.issuer + "/oauth2/token")
  }

  public nonisolated static func mapBilling(
    _ data: Data, plan: String?, displayName: String, now: Date = Date()
  ) -> ProviderQuota? {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let config = body["config"] as? [String: Any]
    else { return nil }

    let period = config["currentPeriod"] as? [String: Any]
    let periodType = period?["type"] as? String
    let reset = (period?["end"] as? String).flatMap(parseDate)
      ?? (config["billingPeriodEnd"] as? String).flatMap(parseDate)
    let resetTime = reset.map { ISO8601DateFormatter().string(from: $0) } ?? ""
    var metrics: [QuotaMetric] = []
    var usage = number(config["creditUsagePercent"])
    var legacyMonthly = false
    // Legacy billing shape: derive the percentage from the cent amounts.
    if usage == nil, let limit = cents(config["monthlyLimit"]), limit > 0,
      let used = cents(config["used"]), used >= 0
    {
      usage = used / limit * 100
      legacyMonthly = true
    }
    if let usage, usage >= 0 {
      let name: String
      switch periodType {
      case weeklyPeriodType: name = "grok-weekly"
      case monthlyPeriodType: name = "grok-monthly"
      default: name = legacyMonthly ? "grok-monthly" : "grok-usage"
      }
      metrics.append(
        .init(name: name, percentage: min(100, max(0, 100 - usage)), resetTime: resetTime))
    }

    // Every Cent value is USD cents. An absent cap is unknown, not a disabled cap.
    if let cap = cents(config["onDemandCap"]), cap >= 0 {
      // Billing stores spend as negative cents, so magnitudes are what count.
      let used = cents(config["onDemandUsed"]).map(abs)
      if cap > 0, let used {
        metrics.append(
          .init(
            name: "grok-extra-usage", percentage: min(100, max(0, (cap - used) / cap * 100)),
            resetTime: resetTime,
            presentation: .progress(used: used / 100, limit: cap / 100, unit: .usd)))
      } else {
        let status = cap > 0 ? "grok-cap:" + String(format: "$%.2f", cap / 100) : "grok-disabled"
        metrics.append(
          .init(
            name: "grok-extra-usage", percentage: -1, resetTime: resetTime,
            presentation: .status(text: status)))
      }
    }
    if let prepaid = cents(config["prepaidBalance"]).map(abs), prepaid > 0 {
      metrics.append(
        .init(
          name: "grok-credits", percentage: -1, resetTime: "",
          presentation: .amount(value: prepaid / 100, unit: .usd, semantics: .balance)))
    }
    guard !metrics.isEmpty else { return nil }
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: displayName)
  }

  private func fetchQuota(_ original: Candidate) async -> ProviderQuota? {
    var candidate = original
    var refreshed = false
    if let expiry = candidate.expiresAt, expiry.timeIntervalSince(now()) <= 300 {
      refreshed = true
      if let newer = await refresh(candidate) { candidate = newer }
    }
    var billing = try? await get(billingURL, token: candidate.accessToken)
    if let status = billing?.1.statusCode, status == 401 || status == 403, !refreshed,
      let newer = await refresh(candidate)
    {
      candidate = newer
      billing = try? await get(billingURL, token: candidate.accessToken)
    }
    guard let (data, response) = billing else { return nil }
    if response.statusCode == 401 || response.statusCode == 403 {
      return ProviderQuota(
        lastUpdated: now(), isForbidden: true, accountDisplayName: candidate.displayName)
    }
    guard 200...299 ~= response.statusCode else { return nil }
    var plan: String?
    if let (settings, response) = try? await get(settingsURL, token: candidate.accessToken),
      200...299 ~= response.statusCode,
      let json = try? JSONSerialization.jsonObject(with: settings) as? [String: Any]
    {
      plan = Self.trimmed(json["subscription_tier_display"] as? String)
        ?? Self.trimmed(json["subscription_tier"] as? String)
    }
    return Self.mapBilling(data, plan: plan, displayName: candidate.displayName, now: now())
  }

  private func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Quotio", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return (data, http)
  }

  /// Renews a Grok CLI credential only while holding the CLI's auth-file lock.
  ///
  /// The refresh token is single-use and shared with the CLI. Spending it and then
  /// failing to write the successor logs the CLI out, so the lock is taken before
  /// the token endpoint is called, and no refresh happens when the lock is busy.
  private func refresh(_ candidate: Candidate) async -> Candidate? {
    guard Self.refreshEndpoint(for: candidate) != nil else { return nil }
    let path = authPath
    let outcome = await writer.withAuthFileLock(path: path) { [self] in
      await self.refreshHoldingLock(candidate, path: path)
    }
    return outcome ?? nil
  }

  /// Uses a held rotation while the file still carries the token it replaced.
  private func resolvingHeldRotation(_ candidate: Candidate) -> Candidate {
    guard let held = heldRotations[candidate.entryKey] else { return candidate }
    guard candidate.refreshToken == held.spentRefreshToken else {
      // The file moved on (a new login or a successful write); drop the stale copy.
      heldRotations.removeValue(forKey: candidate.entryKey)
      return candidate
    }
    return held.rotated
  }

  private func refreshHoldingLock(_ candidate: Candidate, path: String) async -> Candidate? {
    // Under the lock, the file is the truth: a sibling may have rotated already.
    guard let data = await files.read(path: path),
      let current = Self.loadCandidates(data: data).first(where: {
        $0.entryKey == candidate.entryKey
      })
    else { return nil }
    if let held = heldRotations[current.entryKey], current.refreshToken == held.spentRefreshToken {
      // Never spend the already-used token again; retry writing the replacement.
      let stored = try? await writer.persistRotation(
        path: path, expected: current, accessToken: held.rotated.accessToken,
        refreshToken: held.rotated.refreshToken, expiresAt: held.rotated.expiresAt,
        createdAt: now())
      if stored == true { heldRotations.removeValue(forKey: current.entryKey) }
      return held.rotated
    }
    guard current.accessToken == candidate.accessToken,
      current.refreshToken == candidate.refreshToken
    else { return current }
    guard let endpoint = Self.refreshEndpoint(for: current),
      let refreshToken = current.refreshToken, let clientID = current.clientID
    else { return nil }

    var fields = [
      ("grant_type", "refresh_token"),
      ("client_id", clientID),
      ("refresh_token", refreshToken),
    ]
    // The IdP re-issues a team token only when the principal is restated.
    if let principalType = current.principalType { fields.append(("principal_type", principalType)) }
    if let principalID = current.principalID { fields.append(("principal_id", principalID)) }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = Data(fields.map { "\($0.0)=\(Self.form($0.1))" }.joined(separator: "&").utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (body, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let access = Self.trimmed(json["access_token"] as? String)
    else { return nil }

    let rotatedRefresh = Self.trimmed(json["refresh_token"] as? String)
    let expiry = Self.number(json["expires_in"]).map { now().addingTimeInterval($0) }
    let stored = try? await writer.persistRotation(
      path: path, expected: current, accessToken: access, refreshToken: rotatedRefresh,
      expiresAt: expiry, createdAt: now())
    if stored == false,
      let latest = await files.read(path: path),
      let sibling = Self.loadCandidates(data: latest).first(where: {
        $0.entryKey == candidate.entryKey
      })
    {
      return sibling
    }
    let rotated = current.rotated(
      accessToken: access, refreshToken: rotatedRefresh ?? refreshToken,
      idToken: Self.trimmed(json["id_token"] as? String) ?? current.idToken, expiresAt: expiry)
    if stored == nil {
      heldRotations[current.entryKey] = (refreshToken, rotated)
    }
    return rotated
  }

  nonisolated static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  /// `oidc_issuer`, else the scope key's issuer prefix (`<issuer>::<client_id>`).
  private nonisolated static func issuer(entry: [String: Any], entryKey: String) -> String? {
    if let recorded = trimmed(entry["oidc_issuer"] as? String) {
      return normalizedIssuer(recorded)
    }
    if entryKey == legacyScope { return legacyScope }
    guard let separator = entryKey.range(of: "::", options: .backwards) else { return nil }
    return trimmed(String(entryKey[entryKey.startIndex..<separator.lowerBound]))
      .map(normalizedIssuer)
  }

  private nonisolated static func normalizedIssuer(_ value: String) -> String {
    var issuer = value
    while issuer.hasSuffix("/") { issuer.removeLast() }
    return issuer
  }

  private nonisolated static func clientID(entryKey: String, issuer: String) -> String? {
    guard let separator = entryKey.range(of: "::", options: .backwards),
      normalizedIssuer(String(entryKey[entryKey.startIndex..<separator.lowerBound])) == issuer
    else { return nil }
    return trimmed(String(entryKey[separator.upperBound...]))
  }

  nonisolated static func number(_ value: Any?) -> Double? {
    let result: Double?
    switch value {
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
      result = value.doubleValue
    case let value as String: result = Double(value)
    default: result = nil
    }
    guard let result, result.isFinite else { return nil }
    return result
  }

  private nonisolated static func cents(_ value: Any?) -> Double? {
    guard let object = value as? [String: Any] else { return nil }
    // proto3 omits a zero-valued scalar inside a present Cent message.
    return object["val"] == nil ? 0 : number(object["val"])
  }

  nonisolated static func parseDate(_ value: String) -> Date? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private nonisolated static func expiry(_ entry: [String: Any], token: String) -> Date? {
    for key in ["expires_at", "expires"] {
      if let value = entry[key] as? String, let date = parseDate(value) { return date }
    }
    return number(jwtClaim(token, "exp")).map { Date(timeIntervalSince1970: $0) }
  }

  fileprivate nonisolated static func jwtClaim(_ token: String?, _ claim: String) -> Any? {
    guard let token else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json[claim]
  }

  private nonisolated static func form(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=")))
      ?? value
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
