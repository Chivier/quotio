import Darwin
import Foundation
import QuotioApplication
import QuotioDomain

public struct ClaudeQuotaCredential: Equatable, Sendable {
  public let accountKey: String
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?
  /// Whether Quotio may spend this credential's refresh token.
  ///
  /// `false` for credentials the Claude Code CLI or Claude Desktop own: their
  /// refresh tokens are single-use and the CLI marks one it did not spend itself
  /// as dead, so renewing on its behalf can sign the user out. See
  /// ``ClaudeCredentialOwnership``.
  public let allowsRefresh: Bool
  /// The vault account ID of a login Quotio owns; rotations go to the vault only.
  public let ownedAccountID: String?
  /// `false` for a Quotio-owned account whose stored item exists but cannot be read
  /// without user interaction. It keeps the row visible and lets a rotation the
  /// fetcher still holds in memory serve it.
  public let isReadable: Bool

  public init(
    accountKey: String, accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
    allowsRefresh: Bool = true, ownedAccountID: String? = nil, isReadable: Bool = true
  ) {
    self.accountKey = accountKey
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.allowsRefresh = allowsRefresh
    self.ownedAccountID = ownedAccountID
    self.isReadable = isReadable
  }

  /// Keeps one credential per account without letting an external read-only
  /// credential hide a refreshable credential owned by Quotio.
  static func uniqueByAccountKey(_ credentials: [Self], now: Date = Date()) -> [Self] {
    let externalRefreshTokens = Set(
      credentials.compactMap { credential in
        credential.allowsRefresh ? nil : credential.refreshToken
      })
    var positions: [String: Int] = [:]
    var result: [Self] = []

    for original in credentials {
      var credential = original
      // A copied CLI token is still CLI-owned, regardless of its file location
      // or account key. Keep it readable for scoped requests, but never refresh it.
      if credential.allowsRefresh, let refreshToken = credential.refreshToken,
        externalRefreshTokens.contains(refreshToken)
      {
        credential = Self(
          accountKey: credential.accountKey,
          accessToken: credential.accessToken,
          refreshToken: credential.refreshToken,
          expiresAt: credential.expiresAt,
          allowsRefresh: false,
          ownedAccountID: credential.ownedAccountID
        )
      }
      if let index = positions[credential.accountKey] {
        let selected = result[index]
        let selectedCanRefresh = selected.allowsRefresh && selected.refreshToken != nil
        let credentialCanRefresh = credential.allowsRefresh && credential.refreshToken != nil
        let selectedIsUsable = selected.expiresAt.map { $0 > now } ?? true
        let credentialIsUsable = credential.expiresAt.map { $0 > now } ?? true
        if (credentialCanRefresh && !selectedCanRefresh)
          || (!selectedCanRefresh && credentialIsUsable && !selectedIsUsable) {
          result[index] = credential
        }
      } else {
        positions[credential.accountKey] = result.count
        result.append(credential)
      }
    }
    return result
  }
}

public protocol ClaudeQuotaCredentialLoading: Sendable {
  func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential]
  /// Credentials for one fetch. A user-started single-account request may use the
  /// prompting vault read; every other request must stay prompt-free.
  func credentials(for request: QuotaFetchRequest) async -> [ClaudeQuotaCredential]
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async
  /// Writes a rotated credential back to its owner and reports whether it was
  /// stored. A `false` result means the caller still holds the only copy.
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool
}

extension ClaudeQuotaCredentialLoading {
  public func credentials(for request: QuotaFetchRequest) async -> [ClaudeQuotaCredential] {
    await credentials(for: request.mode)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {}

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    await persist(refresh, replacing: expectedRefreshToken, for: credential, mode: request.mode)
    return true
  }
}

public struct LocalClaudeQuotaCredentialLoader: ClaudeQuotaCredentialLoading {
  public static let legacyDirectory = "~/.cli-proxy-api"
  public static let nativePath = "~/.claude/.credentials.json"

  private let environment: [String: String]
  private let legacyDirectory: String

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
    self.legacyDirectory = Self.legacyDirectory
  }

  init(environment: [String: String], legacyDirectory: String) {
    self.environment = environment
    self.legacyDirectory = legacyDirectory
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    let credentials = credentialPaths().compactMap { path in
      Self.load(path: path, environment: environment)
    }
    return ClaudeQuotaCredential.uniqueByAccountKey(credentials)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    _ = writeBack(refresh, replacing: expectedRefreshToken, for: credential)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    writeBack(refresh, replacing: expectedRefreshToken, for: credential)
  }

  private func writeBack(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential
  ) -> Bool {
    credentialPaths().contains { path in
      Self.persist(
        refresh,
        replacing: expectedRefreshToken,
        for: credential,
        path: path,
        environment: environment
      )
    }
  }

  private func credentialPaths() -> [String] {
    var paths: [String] = []
    let nativeBase = ClaudeCredentialOwnership.configDirectory(environment: environment)
    paths.append((nativeBase as NSString).appendingPathComponent(".credentials.json"))

    let directory = NSString(string: legacyDirectory).expandingTildeInPath
    let legacy = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    paths.append(
      contentsOf: legacy.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
        .sorted().map { (directory as NSString).appendingPathComponent($0) })
    return paths
  }

  public static func load(path: String, allowsRefresh: Bool = true) -> ClaudeQuotaCredential? {
    guard let file = SecureClaudeCredentialFile(path: path), let data = file.read() else {
      return nil
    }
    return load(data: data, allowsRefresh: allowsRefresh)
  }

  private static func load(
    path: String,
    environment: [String: String]
  ) -> ClaudeQuotaCredential? {
    guard let file = SecureClaudeCredentialFile(path: path), let data = file.read() else {
      return nil
    }
    let ownership = ClaudeCredentialOwnership.forOpenedAuthFile(
      at: file.path, referenceCount: file.referenceCount, environment: environment)
    return load(data: data, allowsRefresh: ownership.allowsRefresh)
  }

  public static func load(
    data: Data, fallbackAccountKey: String = "Claude Code", allowsRefresh: Bool = true
  )
    -> ClaudeQuotaCredential?
  {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let oauth = json["claudeAiOauth"] as? [String: Any]
    guard
      let access = nonEmpty((json["access_token"] as? String) ?? (oauth?["accessToken"] as? String))
    else { return nil }
    let key =
      nonEmpty((json["email"] as? String) ?? (oauth?["email"] as? String)) ?? fallbackAccountKey
    let refresh = nonEmpty(
      (json["refresh_token"] as? String) ?? (oauth?["refreshToken"] as? String))
    let expiry: Date?
    if let milliseconds = (oauth?["expiresAt"] as? NSNumber)?.doubleValue {
      expiry = Date(timeIntervalSince1970: milliseconds / 1_000)
    } else {
      expiry = (json["expired"] as? String).flatMap(parseDate)
    }
    return ClaudeQuotaCredential(
      accountKey: key, accessToken: access, refreshToken: refresh, expiresAt: expiry,
      allowsRefresh: allowsRefresh)
  }

  static func updatedData(
    _ data: Data,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if var oauth = json["claudeAiOauth"] as? [String: Any] {
      guard oauth["refreshToken"] as? String == expectedRefreshToken else { return nil }
      oauth["accessToken"] = refresh.accessToken
      oauth["refreshToken"] = refresh.refreshToken ?? expectedRefreshToken
      if let expiresAt = refresh.expiresAt {
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1_000)
      }
      json["claudeAiOauth"] = oauth
    } else {
      guard json["refresh_token"] as? String == expectedRefreshToken else { return nil }
      json["access_token"] = refresh.accessToken
      json["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
      if let expiresAt = refresh.expiresAt {
        json["expired"] = ISO8601DateFormatter().string(from: expiresAt)
      }
    }
    return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  }

  private static func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    path: String,
    environment: [String: String]
  ) -> Bool {
    guard let file = SecureClaudeCredentialFile(path: path),
      ClaudeCredentialOwnership.forOpenedAuthFile(
        at: file.path, referenceCount: file.referenceCount, environment: environment
      ).allowsRefresh,
      let currentData = file.read(),
      let current = load(data: currentData),
      current.accountKey == credential.accountKey,
      current.refreshToken == expectedRefreshToken,
      let updated = updatedData(
        currentData,
        refresh: refresh,
        replacing: expectedRefreshToken
      )
    else { return false }
    return file.replaceAtomically(with: updated)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

/// Opens every path component with `O_NOFOLLOW`, then keeps the verified parent
/// directory and file descriptors for the full read/replace operation.
final class SecureClaudeCredentialFile {
  let path: String
  let referenceCount: UInt64

  private let parentDescriptor: Int32
  private let descriptor: Int32
  private let name: String
  private let device: dev_t
  private let inode: ino_t

  init?(path: String) {
    let standardized = ClaudeCredentialOwnership.canonicalPath(path)
    let components = URL(fileURLWithPath: standardized).pathComponents.dropFirst()
    guard let name = components.last, name != ".", name != ".." else { return nil }

    var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { return nil }
    for component in components.dropLast() {
      let next = component.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      Darwin.close(parent)
      guard next >= 0 else { return nil }
      parent = next
    }

    let file = name.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard file >= 0 else {
      Darwin.close(parent)
      return nil
    }
    var status = stat()
    guard Darwin.fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(file)
      Darwin.close(parent)
      return nil
    }

    self.path = standardized
    self.referenceCount = UInt64(status.st_nlink)
    self.parentDescriptor = parent
    self.descriptor = file
    self.name = name
    self.device = status.st_dev
    self.inode = status.st_ino
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parentDescriptor)
  }

  func read() -> Data? {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try? handle.readToEnd() ?? Data()
  }

  func replaceAtomically(with data: Data) -> Bool {
    var current = stat()
    let unchanged = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) == 0
    }
    guard unchanged, current.st_mode & S_IFMT == S_IFREG,
      current.st_dev == device, current.st_ino == inode
    else { return false }

    let temporaryName = ".\(name).\(UUID().uuidString).tmp"
    let temporary = temporaryName.withCString {
      Darwin.openat(
        parentDescriptor, $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
      )
    }
    guard temporary >= 0 else { return false }

    var succeeded = data.withUnsafeBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return true }
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(temporary, base.advanced(by: written), buffer.count - written)
        if count <= 0 {
          if errno == EINTR { continue }
          return false
        }
        written += count
      }
      return Darwin.fsync(temporary) == 0
    }
    if Darwin.close(temporary) != 0 { succeeded = false }

    if succeeded {
      succeeded = temporaryName.withCString { source in
        name.withCString { destination in
          Darwin.renameat(parentDescriptor, source, parentDescriptor, destination) == 0
        }
      }
    }
    if !succeeded {
      temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
    }
    return succeeded
  }
}

public actor ClaudeQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.claude
  public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  public static let refreshScope =
    "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  private let credentials: any ClaudeQuotaCredentialLoading
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date
  private var cache: [String: (quota: ProviderQuota, date: Date)] = [:]
  /// Actor reentrancy must never spend one single-use refresh token twice.
  private var inFlight: [String: Task<ProviderQuota?, Never>] = [:]
  /// Rotations whose write-back failed, keyed by account key. The rotated token is
  /// the only valid one, so it serves the account and is re-persisted until its
  /// owner accepts it.
  private var pendingRefreshes: [String: PendingRefresh] = [:]

  private struct PendingRefresh: Sendable {
    let original: String
    let refresh: QuotaTokenRefresh
    let credential: ClaudeQuotaCredential
  }

  private enum RefreshFailure: Error {
    /// The token endpoint rejected the refresh token; only a new login helps.
    case rejected
    case unavailable
  }

  public init(
    credentials: any ClaudeQuotaCredentialLoading = LocalClaudeQuotaCredentialLoader(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.credentials = credentials
    self.session = session
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let loaded = await credentials.credentials(for: request).filter {
      Self.includes($0.accountKey, scope: request.scope)
    }
    var quotas: [String: ProviderQuota] = [:]
    for credential in loaded {
      if !request.force, let cached = cache[credential.accountKey],
        now().timeIntervalSince(cached.date) < 300
      {
        quotas[credential.accountKey] = cached.quota
        continue
      }
      if let quota = await deduplicatedQuota(credential, request: request) {
        quotas[credential.accountKey] = quota
        if !quota.isForbidden { cache[credential.accountKey] = (quota, now()) }
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: loaded.isEmpty ? .missing : .present,
      credentialAccountKeys: Set(loaded.map(\.accountKey))
    )
  }

  public nonisolated static func mapUsage(_ data: Data, now: Date = Date()) -> ProviderQuota? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["type"] as? String != "error"
    else { return nil }
    let definitions = [
      ("five_hour", "five-hour-session"),
      ("seven_day", "seven-day-weekly"),
      ("seven_day_sonnet", "seven-day-sonnet"),
      ("seven_day_opus", "seven-day-opus"),
      ("seven_day_oauth_apps", "seven-day-oauth-apps"),
    ]
    func metric(_ value: Any?, name: String, percentKey: String = "utilization") -> QuotaMetric? {
      guard let value = value as? [String: Any],
        let used = (value[percentKey] as? NSNumber)?.doubleValue, used.isFinite
      else { return nil }
      return QuotaMetric(
        name: name, percentage: max(0, min(100, 100 - used)),
        resetTime: value["resets_at"] as? String ?? "")
    }
    var metrics = definitions.compactMap { source, name in metric(json[source], name: name) }
    // These aliases describe the same allowance; take the first usable window.
    for key in ["seven_day_routines", "seven_day_claude_routines", "claude_routines",
                "routines", "routine", "seven_day_cowork", "cowork"] {
      if let window = metric(json[key], name: "seven-day-routines") {
        metrics.append(window)
        break
      }
    }
    var names = Set(metrics.map(\.name))
    for limit in json["limits"] as? [[String: Any]] ?? [] {
      guard limit["kind"] as? String == "weekly_scoped",
        limit["is_active"] as? Bool != false,
        let scope = limit["scope"] as? [String: Any],
        let model = scope["model"] as? [String: Any],
        let displayName = model["display_name"] as? String,
        displayName.count <= 128,
        !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { continue }
      let slug = displayName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }
        .joined().split(separator: "-").joined(separator: "-")
      guard !slug.isEmpty,
        let window = metric(limit, name: "seven-day-model-" + slug, percentKey: "percent"),
        names.insert(window.name).inserted
      else { continue }
      metrics.append(window)
    }
    if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
      let usedPercent = (extra["utilization"] as? NSNumber)?.doubleValue
    {
      let used = (extra["used_credits"] as? NSNumber)?.doubleValue
      let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue
      metrics.append(
        QuotaMetric(
          name: "extra-usage",
          percentage: max(0, min(100, 100 - usedPercent)),
          resetTime: "",
          presentation: used.flatMap { value in
            limit.map { .progress(used: value, limit: $0, unit: .credits) }
          },
          used: used.map(Int.init),
          limit: limit.map(Int.init)
        ))
    }
    return metrics.isEmpty ? nil : ProviderQuota(models: metrics, lastUpdated: now)
  }

  private func deduplicatedQuota(
    _ credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ProviderQuota? {
    let key = credential.accountKey
    if let task = inFlight[key] { return await task.value }
    let task = Task { await self.fetchQuota(credential, request: request) }
    inFlight[key] = task
    let quota = await task.value
    inFlight.removeValue(forKey: key)
    return quota
  }

  /// Quota for one Claude credential.
  ///
  /// A credential Quotio does not own is read-only: its refresh token is never
  /// spent and it is never written back. `claude` serializes token refresh behind
  /// a cross-process lock and marks a refresh token it did not spend itself as
  /// dead on `invalid_grant`, so renewing on its behalf can sign the user out of
  /// Claude Code. An expired access token there simply yields no fresh quota
  /// until the CLI renews it itself, which is the correct outcome for an observer.
  ///
  /// Only HTTP 401 means the access token expired. A 403 is a permission answer
  /// that a refresh cannot change, so it never spends a refresh token.
  private func fetchQuota(
    _ original: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ProviderQuota? {
    guard var credential = await applyingPendingRefresh(to: original, request: request) else {
      return cache[original.accountKey]?.quota
    }
    var didRefresh = false
    if credential.allowsRefresh, let expiry = credential.expiresAt,
      expiry.timeIntervalSince(now()) < 60,
      let refresh = credential.refreshToken
    {
      didRefresh = true
      // A failed proactive refresh does not invalidate a still-usable access token.
      if let refreshed = try? await refreshToken(refresh) {
        credential = await adopt(refreshed, replacing: refresh, for: credential, request: request)
      }
    }
    var response = try? await usage(token: credential.accessToken)
    if credential.allowsRefresh, response?.1.statusCode == 401 {
      if let reloaded = await credentials.credentials(for: request).first(where: {
        $0.accountKey == credential.accountKey && $0.isReadable
      }), reloaded.allowsRefresh,
        let latest = await applyingPendingRefresh(to: reloaded, request: request),
        latest.accessToken != credential.accessToken
      {
        credential = latest
        response = try? await usage(token: credential.accessToken)
      }
      if response?.1.statusCode == 401, !didRefresh, let refresh = credential.refreshToken {
        do {
          let refreshed = try await refreshToken(refresh)
          credential = await adopt(refreshed, replacing: refresh, for: credential, request: request)
          response = try? await usage(token: credential.accessToken)
        } catch RefreshFailure.rejected {
          return forbidden(credential)
        } catch {
          return cache[credential.accountKey]?.quota
        }
      }
    }
    guard let (data, http) = response else { return cache[credential.accountKey]?.quota }
    if http.statusCode == 401 || http.statusCode == 403 {
      // A credential we may not renew has no re-authentication story in Quotio:
      // the CLI refreshes it on its own schedule. Reporting `isForbidden` would
      // ask the user to sign in to Quotio for a credential Quotio does not
      // manage, so fall back to cached data instead.
      guard credential.allowsRefresh else { return cache[credential.accountKey]?.quota }
      return forbidden(credential)
    }
    guard 200...299 ~= http.statusCode else { return cache[credential.accountKey]?.quota }
    return Self.mapUsage(data, now: now()) ?? cache[credential.accountKey]?.quota
  }

  /// Keeps the last successful values, flagged as needing a new login.
  private func forbidden(_ credential: ClaudeQuotaCredential) -> ProviderQuota {
    var quota = cache[credential.accountKey]?.quota ?? ProviderQuota(lastUpdated: now())
    quota.isForbidden = true
    return quota
  }

  /// Persists a rotation and always returns the rotated credential: the old refresh
  /// token is spent, so the new one must serve this request even if its owner
  /// refused the write. A refused write is retried on the next fetch.
  private func adopt(
    _ refreshed: QuotaTokenRefresh,
    replacing refreshToken: String,
    for credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ClaudeQuotaCredential {
    let rotated = Self.applying(refreshed, to: credential)
    if await credentials.persist(
      refreshed, replacing: refreshToken, for: credential, request: request)
    {
      pendingRefreshes.removeValue(forKey: credential.accountKey)
    } else {
      pendingRefreshes[credential.accountKey] = PendingRefresh(
        original: refreshToken, refresh: refreshed, credential: rotated)
    }
    return rotated
  }

  /// The credential to use for `loaded`, preferring a rotation that could not be
  /// written yet. `nil` when an unreadable owned account has nothing in memory.
  private func applyingPendingRefresh(
    to loaded: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> ClaudeQuotaCredential? {
    guard let pending = pendingRefreshes[loaded.accountKey] else {
      return loaded.isReadable ? loaded : nil
    }
    // A new login or another client's rotation always takes precedence.
    if loaded.isReadable, loaded.refreshToken != pending.original {
      pendingRefreshes.removeValue(forKey: loaded.accountKey)
      return loaded
    }
    let target = loaded.isReadable ? loaded : pending.credential
    if await credentials.persist(
      pending.refresh, replacing: pending.original, for: target, request: request)
    {
      pendingRefreshes.removeValue(forKey: loaded.accountKey)
    }
    return pending.credential
  }

  private func usage(token: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: Self.usageURL)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return (data, http)
  }

  private func refreshToken(_ refresh: String) async throws -> QuotaTokenRefresh {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "grant_type": "refresh_token", "refresh_token": refresh,
      "client_id": Self.clientID, "scope": Self.refreshScope,
    ])
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else { throw RefreshFailure.unavailable }
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if http.statusCode == 401
      || (http.statusCode == 400 && json?["error"] as? String == "invalid_grant")
    {
      throw RefreshFailure.rejected
    }
    guard 200...299 ~= http.statusCode, let access = json?["access_token"] as? String else {
      throw RefreshFailure.unavailable
    }
    let expiry = (json?["expires_in"] as? NSNumber).map {
      now().addingTimeInterval($0.doubleValue)
    }
    return QuotaTokenRefresh(
      accessToken: access,
      refreshToken: json?["refresh_token"] as? String,
      expiresAt: expiry
    )
  }

  private nonisolated static func applying(
    _ refresh: QuotaTokenRefresh,
    to credential: ClaudeQuotaCredential
  ) -> ClaudeQuotaCredential {
    ClaudeQuotaCredential(
      accountKey: credential.accountKey,
      accessToken: refresh.accessToken,
      refreshToken: refresh.refreshToken ?? credential.refreshToken,
      expiresAt: refresh.expiresAt ?? credential.expiresAt,
      allowsRefresh: credential.allowsRefresh,
      ownedAccountID: credential.ownedAccountID
    )
  }

  private nonisolated static func includes(_ key: String, scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
