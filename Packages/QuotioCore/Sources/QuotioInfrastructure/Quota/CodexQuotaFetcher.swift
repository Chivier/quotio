import Foundation
import QuotioApplication
import QuotioDomain

/// Who owns a Codex credential, and therefore whether Quotio may spend its refresh token.
public enum CodexCredentialSource: Equatable, Sendable {
  /// A CLIProxyAPI auth file (`~/.cli-proxy-api/codex-*.json`). Its refresh lineage
  /// belongs to the proxy Quotio manages, so it may be refreshed and written back.
  case cliProxy
  /// Owned by the Codex CLI (`~/.codex/auth.json`, `$CODEX_HOME/auth.json`,
  /// `~/.config/codex/auth.json`, the `Codex Auth` keychain item). Read-only: OpenAI
  /// refresh tokens are single-use, so renewing on the CLI's behalf signs it out.
  case codexCLI
  /// A login Quotio completed and stores in its own vault under this account ID.
  case quotio(accountID: String)

  public var allowsRefresh: Bool { self != .codexCLI }

  public var ownedAccountID: String? {
    if case .quotio(let accountID) = self { return accountID }
    return nil
  }
}

public struct CodexQuotaCredential: Equatable, Sendable {
  public let accountKey: String
  public let aliases: Set<String>
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let accountID: String?
  public let source: CodexCredentialSource
  /// The email the user recognizes; the canonical key may carry a workspace suffix.
  public let displayName: String?
  public let expiresAt: Date?

  public init(
    accountKey: String, aliases: Set<String> = [], accessToken: String,
    refreshToken: String? = nil, idToken: String? = nil,
    accountID: String? = nil, source: CodexCredentialSource = .cliProxy,
    displayName: String? = nil, expiresAt: Date? = nil
  ) {
    self.accountKey = accountKey
    self.aliases = aliases
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.accountID = accountID
    self.source = source
    self.displayName = displayName
    self.expiresAt = expiresAt
  }

  func replacing(
    accountKey: String? = nil, aliases: Set<String>? = nil, source: CodexCredentialSource? = nil
  ) -> CodexQuotaCredential {
    CodexQuotaCredential(
      accountKey: accountKey ?? self.accountKey, aliases: aliases ?? self.aliases,
      accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
      accountID: accountID, source: source ?? self.source, displayName: displayName,
      expiresAt: expiresAt)
  }

  func applying(_ refresh: QuotaTokenRefresh) -> CodexQuotaCredential {
    CodexQuotaCredential(
      accountKey: accountKey, aliases: aliases, accessToken: refresh.accessToken,
      refreshToken: refresh.refreshToken ?? refreshToken, idToken: refresh.idToken ?? idToken,
      accountID: accountID, source: source, displayName: displayName,
      expiresAt: refresh.expiresAt ?? expiresAt)
  }
}

public protocol CodexQuotaCredentialLoading: Sendable {
  func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential]
  /// Credentials for one fetch. A user-started single-account request may use the
  /// prompting vault read; every other request must stay prompt-free.
  func credentials(for request: QuotaFetchRequest) async -> [CodexQuotaCredential]
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async
  /// Writes a rotated credential back to its owner and reports whether it was
  /// stored. A `false` result means the caller still holds the only copy.
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool
}

extension CodexQuotaCredentialLoading {
  public func credentials(for request: QuotaFetchRequest) async -> [CodexQuotaCredential] {
    await credentials(for: request.mode)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {}

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    await persist(refresh, replacing: expectedRefreshToken, for: credential, mode: request.mode)
    return true
  }
}

public struct LocalCodexQuotaCredentialLoader: CodexQuotaCredentialLoading {
  private let environment: [String: String]
  private let legacyDirectoryOverride: String?
  private let nativePathsOverride: [String]?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
    self.legacyDirectoryOverride = nil
    self.nativePathsOverride = nil
  }

  init(legacyDirectory: String, nativePaths: [String]) {
    self.environment = [:]
    self.legacyDirectoryOverride = legacyDirectory
    self.nativePathsOverride = nativePaths
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] {
    credentialSources(for: mode).map(\.credential)
  }

  /// Only CLIProxyAPI files are ever written. Codex CLI files are read-only.
  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    _ = writeBack(refresh, replacing: expectedRefreshToken, for: credential, mode: mode)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    writeBack(refresh, replacing: expectedRefreshToken, for: credential, mode: request.mode)
  }

  private func writeBack(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) -> Bool {
    guard credential.source == .cliProxy else { return false }
    for source in credentialSources(for: mode)
    where source.credential.accountKey == credential.accountKey && !source.isNative {
      guard let data = Self.updatedData(
        path: source.path,
        isNative: false,
        refresh: refresh,
        replacing: expectedRefreshToken
      ) else { return false }
      do {
        try SecureAtomicFileWriter.write(data, to: URL(fileURLWithPath: source.path))
        return true
      } catch {
        return false
      }
    }
    return false
  }

  private func credentialSources(for mode: QuotaOperatingMode) -> [(
    path: String, isNative: Bool, credential: CodexQuotaCredential
  )] {
    let legacyDirectory = legacyDirectoryOverride
      ?? NSString(string: "~/.cli-proxy-api").expandingTildeInPath
    let legacyFiles =
      ((try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory)) ?? [])
      .filter { $0.hasPrefix("codex-") && $0.hasSuffix(".json") }.sorted()
    var values = legacyFiles.compactMap { filename -> (
      path: String, isNative: Bool, credential: CodexQuotaCredential
    )? in
      let path = (legacyDirectory as NSString).appendingPathComponent(filename)
      return Self.loadLegacy(path: path, filename: filename).map { (path, false, $0) }
    }
    guard mode == .monitor else { return values }

    let paths: [String]
    if let nativePathsOverride {
      paths = nativePathsOverride
    } else {
      paths = Self.nativeAuthPaths(
        environment: environment,
        homeDirectory: URL(fileURLWithPath: NSHomeDirectory()))
    }
    let aliases = Self.uniqueLegacyAliases(values.map(\.credential))
    for path in paths {
      guard var credential = Self.loadNative(path: path) else { continue }
      credential = Self.applyingLegacyAlias(credential, aliases: aliases)
      if let existing = values.firstIndex(where: {
        CodexAccountKey.keysMatch($0.credential.accountKey, credential.accountKey)
      }) {
        if !values[existing].isNative {
          values[existing] = (path, true, credential)
        }
      } else {
        values.append((path, true, credential))
      }
    }
    return values
  }

  /// `$CODEX_HOME/auth.json`, `~/.config/codex/auth.json`, `~/.codex/auth.json`.
  public static func nativeAuthPaths(environment: [String: String], homeDirectory: URL) -> [String] {
    var paths: [String] = []
    if let home = nonEmpty(environment["CODEX_HOME"]) {
      paths.append(
        (NSString(string: home).expandingTildeInPath as NSString)
          .appendingPathComponent("auth.json"))
    }
    paths.append(homeDirectory.appendingPathComponent(".config/codex/auth.json").path)
    paths.append(homeDirectory.appendingPathComponent(".codex/auth.json").path)
    return paths
  }

  /// A Codex CLI login whose ChatGPT account has exactly one CLIProxyAPI file keeps
  /// that file's key, so the proxy row and the CLI row stay one account.
  static func applyingLegacyAlias(
    _ credential: CodexQuotaCredential, aliases: [String: String]
  ) -> CodexQuotaCredential {
    guard let accountID = credential.accountID, let alias = aliases[accountID],
      alias != credential.accountKey
    else { return credential }
    return credential.replacing(
      accountKey: alias,
      aliases: credential.aliases.union([credential.accountKey]).subtracting([alias]))
  }

  public static func loadLegacy(path: String, filename: String) -> CodexQuotaCredential? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let key = String(filename.dropFirst("codex-".count).dropLast(".json".count))
    return loadLegacy(data: data, accountKey: key)
  }

  public static func loadLegacy(data: Data, accountKey: String) -> CodexQuotaCredential? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = nonEmpty(json["access_token"] as? String)
    else { return nil }
    let idToken = nonEmpty(json["id_token"] as? String)
    let decoded = claims(idToken)
    return CodexQuotaCredential(
      accountKey: accountKey, accessToken: access,
      refreshToken: nonEmpty(json["refresh_token"] as? String), idToken: idToken,
      accountID: nonEmpty(json["account_id"] as? String) ?? decoded["accountID"],
      source: .cliProxy,
      displayName: nonEmpty(json["email"] as? String) ?? decoded["email"],
      expiresAt: (json["expired"] as? String).flatMap(parseDate))
  }

  public static func loadNative(path: String) -> CodexQuotaCredential? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return loadNative(data: data)
  }

  /// Keyed by `CodexAccountKey`; the key older builds used (the email alone) stays
  /// an alias so cached rows and markers migrate.
  public static func loadNative(data: Data, fallbackAccountKey: String = "Codex User")
    -> CodexQuotaCredential?
  {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = json["tokens"] as? [String: Any],
      let access = nonEmpty(tokens["access_token"] as? String)
    else { return nil }
    let idToken = nonEmpty(tokens["id_token"] as? String)
    let decoded = claims(idToken)
    let accountID = nonEmpty(tokens["account_id"] as? String) ?? decoded["accountID"]
    let email = decoded["email"]
    let key = CodexAccountKey.canonical(
      email: email, accountID: accountID, fallback: fallbackAccountKey)
    let previousKey = email ?? accountID ?? fallbackAccountKey
    return CodexQuotaCredential(
      accountKey: key, aliases: previousKey == key ? [] : [previousKey], accessToken: access,
      refreshToken: nonEmpty(tokens["refresh_token"] as? String), idToken: idToken,
      accountID: accountID, source: .codexCLI, displayName: email)
  }

  static func updatedData(
    _ data: Data,
    isNative: Bool,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if isNative {
      guard var tokens = json["tokens"] as? [String: Any],
        tokens["refresh_token"] as? String == expectedRefreshToken
      else { return nil }
      tokens["access_token"] = refresh.accessToken
      tokens["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      if let idToken = refresh.idToken { tokens["id_token"] = idToken }
      json["tokens"] = tokens
      json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    } else {
      guard json["refresh_token"] as? String == expectedRefreshToken else { return nil }
      json["access_token"] = refresh.accessToken
      json["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      if let idToken = refresh.idToken { json["id_token"] = idToken }
      if let expiresAt = refresh.expiresAt {
        json["expired"] = ISO8601DateFormatter().string(from: expiresAt)
      }
    }
    return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  }

  private static func updatedData(
    path: String,
    isNative: Bool,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return updatedData(
      data,
      isNative: isNative,
      refresh: refresh,
      replacing: expectedRefreshToken
    )
  }

  /// Account ID → key, only for CLIProxyAPI files whose account ID maps to one key.
  public static func uniqueLegacyAliases(_ credentials: [CodexQuotaCredential]) -> [String: String]
  {
    let grouped = Dictionary(
      grouping: credentials.compactMap { value in
        value.source == .cliProxy ? value.accountID.map { ($0, value.accountKey) } : nil
      },
      by: \.0)
    return grouped.compactMapValues { entries in
      let keys = Set(entries.map(\.1))
      return keys.count == 1 ? keys.first : nil
    }
  }

  static func claims(_ token: String?) -> [String: String] {
    guard let json = payload(token) else { return [:] }
    let auth = json["https://api.openai.com/auth"] as? [String: Any]
    return [
      "email": nonEmpty(json["email"] as? String),
      "plan": nonEmpty(auth?["chatgpt_plan_type"] as? String),
      "accountID": nonEmpty(auth?["chatgpt_account_id"] as? String),
    ].compactMapValues { $0 }
  }

  /// Whether a JWT access token's `exp` claim has passed. Opaque tokens are never
  /// treated as expired.
  static func isExpired(_ token: String, now: Date) -> Bool {
    guard let exp = (payload(token)?["exp"] as? NSNumber)?.doubleValue else { return false }
    return Date(timeIntervalSince1970: exp) <= now
  }

  private static func payload(_ token: String?) -> [String: Any]? {
    guard let token else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public actor CodexQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.codex
  public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
  public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private let credentials: any CodexQuotaCredentialLoading
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date
  /// Actor reentrancy must never spend one single-use refresh token twice.
  private var inFlight: [String: Task<ProviderQuota?, Never>] = [:]
  /// Rotations whose write-back failed, keyed by account key. The rotated token is
  /// the only valid one, so it is used and re-persisted until its owner accepts it.
  private var pendingRefreshes: [String: (original: String, refreshed: QuotaTokenRefresh)] = [:]

  private enum RefreshFailure: Error {
    /// The token endpoint rejected the refresh token; only a new login helps.
    case rejected
    case unavailable
  }

  public init(
    credentials: any CodexQuotaCredentialLoading = LocalCodexQuotaCredentialLoader(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.credentials = credentials
    self.session = session
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let available = await credentials.credentials(for: request)
    let loaded = available.filter { Self.includes($0, scope: request.scope) }
    var quotas: [String: ProviderQuota] = [:]
    for credential in loaded {
      if let quota = await deduplicatedQuota(credential, request: request) {
        quotas[credential.accountKey] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: loaded.isEmpty ? .missing : .present,
      credentialAccountKeys: Set(loaded.map(\.accountKey)),
      accountAliases: Self.accountAliases(available)
    )
  }

  /// Old keys that name exactly one current credential. An email shared by two
  /// workspaces proves nothing, and a key that is itself current is never an alias.
  nonisolated static func accountAliases(_ credentials: [CodexQuotaCredential]) -> [String: String] {
    let currentKeys = Set(credentials.map { $0.accountKey.lowercased() })
    var targets: [String: Set<String>] = [:]
    for credential in credentials {
      for alias in credential.aliases
      where !CodexAccountKey.keysMatch(alias, credential.accountKey) {
        targets[alias, default: []].insert(credential.accountKey)
      }
    }
    return targets.reduce(into: [:]) { result, entry in
      guard entry.value.count == 1, let key = entry.value.first,
        !currentKeys.contains(entry.key.lowercased())
      else { return }
      result[entry.key] = key
    }
  }

  public nonisolated static func mapUsage(
    _ data: Data, planFallback: String? = nil, now: Date = Date()
  ) throws -> ProviderQuota {
    let response = try JSONDecoder().decode(Response.self, from: data)
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    var metrics: [QuotaMetric] = []
    var kinds = Set<String>()
    func append(_ window: Window, name: String) {
      guard kinds.insert(name).inserted else { return }
      let reset = window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ?? window.resetAfter.map { now.addingTimeInterval(TimeInterval($0)) }
      metrics.append(.init(
        name: name, percentage: 100 - window.usedPercent,
        resetTime: reset.map { ISO8601DateFormatter().string(from: $0) } ?? ""))
    }
    func name(for window: Window, session: String, weekly: String, fallback: String) -> String {
      window.windowSeconds.map {
        $0 >= 518_400 ? weekly : ($0 <= 86_400 ? session : fallback)
      } ?? (window.resetAfter.map { $0 > 86_400 ? weekly : fallback } ?? fallback)
    }
    for (window, fallback) in [
      (response.rateLimit?.primary, "codex-session"),
      (response.rateLimit?.secondary, "codex-weekly"),
    ] {
      guard let window else { continue }
      append(window, name: name(
        for: window, session: "codex-session", weekly: "codex-weekly", fallback: fallback))
    }
    for limit in response.additional ?? [] {
      let spark = [limit.name, limit.feature].compactMap { $0?.lowercased() }.contains {
        $0.contains("spark")
      }
      if spark {
        for (window, fallback) in [
          (limit.rateLimit?.primary, "codex-spark"),
          (limit.rateLimit?.secondary, "codex-spark-weekly"),
        ] {
          guard let window else { continue }
          append(window, name: name(
            for: window, session: "codex-spark", weekly: "codex-spark-weekly", fallback: fallback))
        }
      } else if let source = nonEmpty(limit.feature) ?? nonEmpty(limit.name) {
        let slug = source.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }
          .joined().split(separator: "-").joined(separator: "-")
        guard !slug.isEmpty else { continue }
        let sessionName = "codex-" + slug
        let weeklyName = sessionName + "-weekly"
        for (window, fallback) in [
          (limit.rateLimit?.primary, sessionName),
          (limit.rateLimit?.secondary, weeklyName),
        ] {
          guard let window else { continue }
          append(window, name: name(
            for: window, session: sessionName, weekly: weeklyName, fallback: fallback))
        }
      }
    }
    return ProviderQuota(
      models: metrics, lastUpdated: now, isForbidden: response.rateLimit?.reached ?? false,
      planType: response.plan ?? planFallback,
      analytics: analytics(from: json))
  }


  private func deduplicatedQuota(
    _ credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ProviderQuota? {
    let key = credential.accountKey.lowercased()
    if let task = inFlight[key] { return await task.value }
    let task = Task { await self.fetchQuota(credential, request: request) }
    inFlight[key] = task
    let quota = await task.value
    inFlight.removeValue(forKey: key)
    return quota
  }

  /// Quota for one Codex credential.
  ///
  /// Only HTTP 401 means the access token is no longer accepted. A 403 reports a
  /// deactivated workspace or a block, which a refresh cannot fix, and spending a
  /// single-use refresh token there only risks losing the login. Codex CLI
  /// credentials are never refreshed at all; the CLI renews them itself, so a 401
  /// asks the user to sign in to the Codex CLI again.
  private func fetchQuota(
    _ original: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ProviderQuota? {
    var credential = await applyingPendingRefresh(to: original, request: request)
    if credential.source.ownedAccountID != nil, needsProactiveRefresh(credential),
      let refreshToken = credential.refreshToken,
      let refreshed = try? await refresh(refreshToken)
    {
      // A failed proactive refresh leaves a token that may still be accepted.
      credential = await adopt(refreshed, replacing: refreshToken, for: credential, request: request)
    }

    do {
      return try await requestQuota(token: credential.accessToken, credential: credential)
    } catch InfrastructureQuotaFetchError.httpError(401) {
      guard credential.source.allowsRefresh else { return forbidden(credential) }
      var latest = credential
      if let reloaded = await credentials.credentials(for: request).first(where: {
        $0.accountKey == credential.accountKey
      }) {
        latest = await applyingPendingRefresh(to: reloaded, request: request)
      }
      if latest.accessToken != credential.accessToken,
        let quota = try? await requestQuota(token: latest.accessToken, credential: latest)
      {
        return quota
      }
      guard let refreshToken = latest.refreshToken else { return forbidden(latest) }
      let refreshed: QuotaTokenRefresh
      do {
        refreshed = try await refresh(refreshToken)
      } catch RefreshFailure.rejected {
        return forbidden(latest)
      } catch {
        return nil
      }
      let renewed = await adopt(refreshed, replacing: refreshToken, for: latest, request: request)
      do {
        return try await requestQuota(token: renewed.accessToken, credential: renewed)
      } catch InfrastructureQuotaFetchError.httpError(let status) where status == 401 || status == 403 {
        return forbidden(renewed)
      } catch {
        return nil
      }
    } catch InfrastructureQuotaFetchError.httpError(403) {
      return forbidden(credential)
    } catch {
      return nil
    }
  }

  private func needsProactiveRefresh(_ credential: CodexQuotaCredential) -> Bool {
    if let expiresAt = credential.expiresAt {
      return expiresAt.timeIntervalSince(now()) < 300
    }
    return LocalCodexQuotaCredentialLoader.isExpired(credential.accessToken, now: now())
  }

  /// Persists a rotation and always returns the rotated credential: the old refresh
  /// token is spent, so the new one must serve this request even if its owner
  /// refused the write. A refused write is retried on the next fetch.
  private func adopt(
    _ refreshed: QuotaTokenRefresh,
    replacing refreshToken: String,
    for credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> CodexQuotaCredential {
    let stored = await credentials.persist(
      refreshed, replacing: refreshToken, for: credential, request: request)
    let key = credential.accountKey.lowercased()
    if stored {
      pendingRefreshes.removeValue(forKey: key)
    } else {
      pendingRefreshes[key] = (refreshToken, refreshed)
    }
    return credential.applying(refreshed)
  }

  private func applyingPendingRefresh(
    to credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> CodexQuotaCredential {
    let key = credential.accountKey.lowercased()
    guard let pending = pendingRefreshes[key] else { return credential }
    // A new login or another client's rotation always takes precedence.
    guard credential.refreshToken == pending.original else {
      pendingRefreshes.removeValue(forKey: key)
      return credential
    }
    if await credentials.persist(
      pending.refreshed, replacing: pending.original, for: credential, request: request)
    {
      pendingRefreshes.removeValue(forKey: key)
    }
    return credential.applying(pending.refreshed)
  }

  private func forbidden(_ credential: CodexQuotaCredential) -> ProviderQuota {
    ProviderQuota(
      lastUpdated: now(), isForbidden: true,
      accountDisplayName: Self.displayName(for: credential))
  }

  private nonisolated static func displayName(for credential: CodexQuotaCredential) -> String? {
    credential.displayName ?? LocalCodexQuotaCredentialLoader.claims(credential.idToken)["email"]
  }

  private func requestQuota(token: String, credential: CodexQuotaCredential) async throws
    -> ProviderQuota
  {
    var request = URLRequest(url: Self.usageURL)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let accountID = credential.accountID, !accountID.isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    let updatedAt = now()
    var quota = try Self.mapUsage(
      data, planFallback: LocalCodexQuotaCredentialLoader.claims(credential.idToken)["plan"],
      now: updatedAt)
    quota.accountDisplayName = Self.displayName(for: credential)
    if let analytics = try? await CodexResetCreditInventoryFetcher(
      session: session,
      now: { updatedAt }
    ).fetch(accessToken: token, accountID: credential.accountID) {
      quota.analytics = CodexResetCreditInventoryFetcher.merge(analytics, into: quota.analytics)
    }
    if let analytics = try? await CodexProfileAnalyticsFetcher(
      session: session,
      now: { updatedAt }
    ).fetch(accessToken: token, accountID: credential.accountID) {
      quota.analytics = quota.analytics?.merging(analytics) ?? analytics
    }
    return quota
  }

  private func refresh(_ refreshToken: String) async throws -> QuotaTokenRefresh {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      [
        "grant_type=refresh_token",
        "client_id=" + Self.form(Self.clientID),
        "refresh_token=" + Self.form(refreshToken),
      ].joined(separator: "&").utf8)
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else { throw RefreshFailure.unavailable }
    if http.statusCode == 400 || http.statusCode == 401 { throw RefreshFailure.rejected }
    guard 200...299 ~= http.statusCode,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = json["access_token"] as? String
    else {
      throw RefreshFailure.unavailable
    }
    let expiry = (json["expires_in"] as? NSNumber).map {
      now().addingTimeInterval($0.doubleValue)
    }
    return QuotaTokenRefresh(
      accessToken: accessToken,
      refreshToken: json["refresh_token"] as? String,
      idToken: json["id_token"] as? String,
      expiresAt: expiry
    )
  }

  private nonisolated static func form(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private nonisolated static func includes(
    _ credential: CodexQuotaCredential, scope: QuotaFetchScope
  ) -> Bool {
    let keys = credential.aliases.union([credential.accountKey])
    switch scope {
    case .provider:
      return true
    case .account(let value):
      return keys.contains { CodexAccountKey.keysMatch($0, value) }
    case .importedAccounts(let values):
      return keys.contains { key in values.contains { CodexAccountKey.keysMatch($0, key) } }
    }
  }

  private nonisolated static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private nonisolated static func analytics(from json: [String: Any]?) -> QuotaAnalytics? {
    guard let json else { return nil }
    var rows: [QuotaAnalyticsRow] = []
    if let credits = json["credits"] as? [String: Any],
      let balance = number(credits["balance"])
        ?? ((credits["has_credits"] as? Bool) == false ? 0 : nil)
    {
      let creditCount = Int(max(0, balance).rounded(.down))
      rows.append(
        QuotaAnalyticsRow(
          id: "codex-extra-usage",
          title: "Extra Usage",
          value: "\(formatDollars(Double(creditCount) * 0.04)) - \(creditCount) credits"))
    }
    if let resets = json["rate_limit_reset_credits"] as? [String: Any],
      let count = number(resets["available_count"]), count >= 0
    {
      rows.append(
        QuotaAnalyticsRow(
          id: "codex-rate-limit-resets",
          title: "Rate Limit Resets",
          value: "\(Int(count.rounded(.down))) available"))
    }
    return rows.isEmpty ? nil : QuotaAnalytics(rows: rows)
  }

  private nonisolated static func number(_ value: Any?) -> Double? {
    switch value {
    case let value as Double: value
    case let value as Int: Double(value)
    case let value as String: Double(value)
    default: nil
    }
  }

  private nonisolated static func formatDollars(_ value: Double) -> String {
    if value >= 1_000 {
      return String(format: "$%.1fK", value / 1_000)
    }
    return String(format: "$%.2f", value)
  }

  private struct Response: Decodable {
    let plan: String?
    let rateLimit: Limit?
    let additional: [Additional]?

    enum CodingKeys: String, CodingKey {
      case plan = "plan_type"
      case rateLimit = "rate_limit"
      case additional = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      plan = try? values.decode(String.self, forKey: .plan)
      rateLimit = try? values.decode(Limit.self, forKey: .rateLimit)
      additional = try? values.decode([LossyAdditional].self, forKey: .additional)
        .compactMap(\.value)
    }
  }
  private struct Limit: Decodable {
    let reached: Bool?
    let primary: Window?
    let secondary: Window?
    enum CodingKeys: String, CodingKey {
      case reached = "limit_reached"
      case primary = "primary_window"
      case secondary = "secondary_window"
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      reached = try? values.decode(Bool.self, forKey: .reached)
      primary = try? values.decode(Window.self, forKey: .primary)
      secondary = try? values.decode(Window.self, forKey: .secondary)
    }
  }
  private struct Additional: Decodable {
    let name: String?
    let feature: String?
    let rateLimit: Limit?
    enum CodingKeys: String, CodingKey {
      case name = "limit_name"
      case feature = "metered_feature"
      case rateLimit = "rate_limit"
    }
  }
  private struct LossyAdditional: Decodable {
    let value: Additional?

    init(from decoder: Decoder) throws {
      value = try? Additional(from: decoder)
    }
  }
  private struct Window: Decodable {
    let usedPercent: Double
    let resetAt: Int?
    let resetAfter: Int?
    let windowSeconds: Int?
    enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case resetAt = "reset_at"
      case resetAfter = "reset_after_seconds"
      case windowSeconds = "limit_window_seconds"
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      usedPercent = max(0, min(100, try Self.numeric(values, .usedPercent)))
      resetAt = try? Self.number(values, .resetAt)
      resetAfter = try? Self.number(values, .resetAfter)
      windowSeconds = try? Self.number(values, .windowSeconds)
    }
    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys)
      throws -> Int
    {
      if let value = Int(exactly: try numeric(values, key).rounded()) { return value }
      throw DecodingError.dataCorruptedError(
        forKey: key, in: values, debugDescription: "Expected a bounded number")
    }
    private static func numeric(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys)
      throws -> Double
    {
      let value = (try? values.decode(Double.self, forKey: key))
        ?? (try? values.decode(String.self, forKey: key)).flatMap(Double.init)
      if let value, value.isFinite { return value }
      throw DecodingError.dataCorruptedError(
        forKey: key, in: values, debugDescription: "Expected number")
    }
  }
}
