//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude auth files in ~/.cli-proxy-api/
//  Calls Anthropic OAuth API for usage data
//

import Foundation

/// API fetch result type
nonisolated enum ClaudeAPIResult: Sendable {
    case success(ClaudeCodeQuotaInfo)
    case authenticationError  // Token expired or invalid - needs re-authentication
    case permissionError  // A 403 does not imply that the access token expired
    case otherError
}

/// Quota data from Claude Code OAuth API
nonisolated struct ClaudeCodeQuotaInfo: Sendable {
    /// Usage quotas from OAuth API
    let fiveHour: QuotaUsage?
    let sevenDay: QuotaUsage?
    let sevenDaySonnet: QuotaUsage?
    let sevenDayOpus: QuotaUsage?
    let extraUsage: ExtraUsage?

    struct QuotaUsage: Sendable {
        let utilization: Double  // Percentage used (0-100)
        let resetsAt: String  // ISO8601 date string

        /// Remaining percentage (100 - utilization), clamped to 0-100
        var remaining: Double {
            max(0, min(100, 100 - utilization))
        }
    }

    struct ExtraUsage: Sendable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?

        /// Remaining percentage for extra usage, clamped to 0-100
        var remaining: Double? {
            guard let util = utilization else { return nil }
            return max(0, min(100, 100 - util))
        }
    }
}

/// Fetches quota from Claude auth files using OAuth API
actor ClaudeCodeQuotaFetcher {

    /// Auth directory for CLI Proxy API
    private let authDir = "~/.cli-proxy-api"

    /// Anthropic OAuth usage API endpoint
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// Anthropic OAuth token refresh endpoint
    private let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// URLSession for network requests
    private var session: URLSession
    private let vault: MonitorCredentialStore

    /// Cache for quota data to reduce API calls
    private var quotaCache: [String: CachedQuota] = [:]

    private enum CredentialSource: Sendable {
        case owned(MonitorAccount)
        case file(String)
        case keychain(String)

        var id: String {
            switch self {
            case .owned(let account): "owned:" + account.id
            case .file(let path): "file:" + path
            case .keychain(let account): "keychain:" + account
            }
        }
    }

    private struct CredentialSnapshot: Sendable {
        var credential: MonitorOAuthCredential
        let data: Data?

        func hasSameTokens(as other: CredentialSnapshot) -> Bool {
            credential.accessToken == other.credential.accessToken
                && credential.refreshToken == other.credential.refreshToken
        }
    }

    private struct PendingRefresh {
        let original: CredentialSnapshot
        let refreshed: CredentialSnapshot
    }

    private enum RefreshError: Error { case authenticationRequired }

    // Actor reentrancy must not consume a rotating refresh token twice.
    private var inFlight: [String: Task<ProviderQuotaData?, Never>] = [:]
    // Retain a rotated token if its credential store is temporarily unwritable.
    private var pendingRefreshes: [String: PendingRefresh] = [:]

    /// Cache TTL: 5 minutes
    private let cacheTTL: TimeInterval = 300

    init(vault: MonitorCredentialStore = MonitorCredentialVault.shared, session: URLSession? = nil) {
        self.vault = vault
        self.session =
            session
            ?? URLSession(
                configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
            )
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    private struct CachedQuota {
        let data: ProviderQuotaData
        let timestamp: Date

        func isValid(ttl: TimeInterval) -> Bool {
            !data.isForbidden && Date().timeIntervalSince(timestamp) < ttl
        }
    }

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.QuotaUsage? {
        guard let json = json else { return nil }

        // Handle both Int and Double for utilization
        let utilization: Double
        if let doubleVal = json["utilization"] as? Double {
            utilization = doubleVal
        } else if let intVal = json["utilization"] as? Int {
            utilization = Double(intVal)
        } else {
            return nil
        }

        // resets_at can be null
        let resetsAt = json["resets_at"] as? String ?? ""

        return ClaudeCodeQuotaInfo.QuotaUsage(utilization: utilization, resetsAt: resetsAt)
    }

    /// Parse extra usage object from JSON
    private func parseExtraUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.ExtraUsage? {
        guard let json = json else { return nil }

        let isEnabled = json["is_enabled"] as? Bool ?? false

        // Only parse if enabled
        guard isEnabled else { return nil }

        let monthlyLimit = json["monthly_limit"] as? Double
        let usedCredits = json["used_credits"] as? Double
        let utilization = json["utilization"] as? Double

        return ClaudeCodeQuotaInfo.ExtraUsage(
            isEnabled: isEnabled,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: utilization
        )
    }

    private func credentialSnapshot(data: Data) -> CredentialSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = json["claudeAiOauth"] as? [String: Any]
        guard let accessToken = (oauth?["accessToken"] as? String) ?? (json["access_token"] as? String),
            !accessToken.isEmpty
        else { return nil }
        let expiresAt: Date?
        if let milliseconds = oauth?["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if let expiry = json["expired"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry)
        } else {
            expiresAt = nil
        }
        return CredentialSnapshot(
            credential: MonitorOAuthCredential(
                accessToken: accessToken,
                refreshToken: (oauth?["refreshToken"] as? String) ?? (json["refresh_token"] as? String),
                expiresAt: expiresAt,
                extra: [:]
            ),
            data: data
        )
    }

    private func loadCredential(from source: CredentialSource) async -> CredentialSnapshot? {
        switch source {
        case .owned(let account):
            guard let credential = await vault.reloadLatest(accountID: account.id) else { return nil }
            return CredentialSnapshot(credential: credential, data: nil)
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return credentialSnapshot(data: data)
        case .keychain(let account):
            guard let record = KeychainHelper.readExternalCredentialRecord(service: "Claude Code-credentials", account: account) else {
                return nil
            }
            return credentialSnapshot(data: record.data)
        }
    }

    private func persistRefresh(
        _ refreshed: CredentialSnapshot,
        replacing original: CredentialSnapshot,
        source: CredentialSource
    ) async -> Bool {
        guard let latest = await loadCredential(from: source), latest.hasSameTokens(as: original) else { return false }
        do {
            switch source {
            case .owned(let account):
                try await vault.save(refreshed.credential, metadata: account)
            case .file(let path):
                guard let data = updatedAuthData(latest.data, credential: refreshed.credential) else { return false }
                try SecureAtomicFileWriter.write(data, to: URL(fileURLWithPath: path))
            case .keychain(let account):
                guard let originalData = latest.data,
                    let data = updatedAuthData(originalData, credential: refreshed.credential)
                else { return false }
                return KeychainHelper.compareAndSwapExternalCredential(
                    service: "Claude Code-credentials", account: account,
                    expectedData: originalData, newData: data
                )
            }
            return true
        } catch {
            NSLog("[ClaudeQuota] Could not persist refreshed credential; retaining it for this session")
            return false
        }
    }

    private func latestCredential(from source: CredentialSource) async -> CredentialSnapshot? {
        guard let latest = await loadCredential(from: source) else { return nil }
        guard let pending = pendingRefreshes[source.id] else { return latest }
        // A new login or another client's rotation always takes precedence.
        guard latest.hasSameTokens(as: pending.original) else {
            pendingRefreshes.removeValue(forKey: source.id)
            return latest
        }
        if await persistRefresh(pending.refreshed, replacing: pending.original, source: source) {
            pendingRefreshes.removeValue(forKey: source.id)
        }
        return pending.refreshed
    }

    private func renewCredential(_ original: CredentialSnapshot, source: CredentialSource) async throws -> CredentialSnapshot {
        guard let refreshToken = original.credential.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.authenticationRequired
        }
        do {
            let tokens = try await refreshAccessToken(refreshToken: refreshToken)
            var refreshed = original
            refreshed.credential.accessToken = tokens.accessToken
            refreshed.credential.refreshToken = tokens.refreshToken ?? refreshToken
            refreshed.credential.expiresAt = tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            // If a previous write failed, storage still holds the earlier generation.
            let stored = pendingRefreshes[source.id]?.original ?? original
            pendingRefreshes[source.id] = PendingRefresh(original: stored, refreshed: refreshed)
            if await persistRefresh(refreshed, replacing: stored, source: source) {
                pendingRefreshes.removeValue(forKey: source.id)
                return refreshed
            }
            return await latestCredential(from: source) ?? refreshed
        } catch {
            if let latest = await latestCredential(from: source), !latest.hasSameTokens(as: original) {
                return latest
            }
            throw error
        }
    }

    private func fetchQuota(source: CredentialSource, email: String, forceRefresh: Bool) async -> ProviderQuotaData? {
        if let task = inFlight[source.id] { return await task.value }
        let task = Task { await self.fetchCredentialQuota(source: source, email: email, forceRefresh: forceRefresh) }
        inFlight[source.id] = task
        defer { inFlight.removeValue(forKey: source.id) }
        return await task.value
    }

    private func fetchCredentialQuota(source: CredentialSource, email: String, forceRefresh: Bool) async -> ProviderQuotaData? {
        guard var snapshot = await latestCredential(from: source) else { return nil }
        if !forceRefresh, let cached = quotaCache[email], cached.isValid(ttl: cacheTTL) { return cached.data }

        var didRefresh = false
        if snapshot.credential.expiresAt.map({ $0.timeIntervalSinceNow < 60 }) == true,
            snapshot.credential.refreshToken?.isEmpty == false
        {
            didRefresh = true
            do {
                snapshot = try await renewCredential(snapshot, source: source)
            } catch {
                // A failed proactive refresh does not invalidate a still-usable access token.
                let response = await fetchUsageFromAPI(accessToken: snapshot.credential.accessToken)
                if case .authenticationError = response {
                    return quotaResult(error is RefreshError ? .authenticationError : .otherError, email: email)
                }
                return quotaResult(response, email: email)
            }
        }

        var response = await fetchUsageFromAPI(accessToken: snapshot.credential.accessToken)
        if case .authenticationError = response {
            if let latest = await latestCredential(from: source), !latest.hasSameTokens(as: snapshot) {
                snapshot = latest
                response = await fetchUsageFromAPI(accessToken: snapshot.credential.accessToken)
            }
            if case .authenticationError = response, !didRefresh {
                do {
                    snapshot = try await renewCredential(snapshot, source: source)
                    response = await fetchUsageFromAPI(accessToken: snapshot.credential.accessToken)
                } catch {
                    response = error is RefreshError ? .authenticationError : .otherError
                }
            }
        }
        return quotaResult(response, email: email)
    }

    private func quotaResult(_ result: ClaudeAPIResult, email: String) -> ProviderQuotaData? {
        switch result {
        case .success(let info):
            guard let quota = quotaData(from: info) else { return quotaCache[email]?.data }
            quotaCache[email] = CachedQuota(data: quota, timestamp: quota.lastUpdated)
            return quota
        case .authenticationError, .permissionError:
            var quota = quotaCache[email]?.data ?? ProviderQuotaData(models: [], lastUpdated: Date())
            quota.isForbidden = true
            // Keep the last successful values and timestamp, but never TTL-cache an auth failure.
            quotaCache[email] = CachedQuota(data: quota, timestamp: quota.lastUpdated)
            return quota
        case .otherError:
            return quotaCache[email]?.data
        }
    }

    /// Refresh an expired access token using the refresh token
    /// - Returns: Tuple of new access token, optional new refresh token, and optional expires_in
    private func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        guard let url = URL(string: tokenURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Omitting scope retains the original grant; newer CLI scopes may not
        // have been authorized by older logins (RFC 6749 section 6).
        let params: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200...299 ~= httpResponse.statusCode else {
            NSLog("[ClaudeQuota] Token refresh failed with HTTP \(httpResponse.statusCode)")
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if httpResponse.statusCode == 401
                || (httpResponse.statusCode == 400 && json?["error"] as? String == "invalid_grant")
            {
                throw RefreshError.authenticationRequired
            }
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }

        let newRefreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int

        return (newAccessToken, newRefreshToken, expiresIn)
    }

    private func updatedAuthData(_ data: Data?, credential: MonitorOAuthCredential) -> Data? {
        guard let data,
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if var oauth = json["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = credential.accessToken
            oauth["refreshToken"] = credential.refreshToken
            oauth["expiresAt"] = credential.expiresAt.map { Int($0.timeIntervalSince1970 * 1000) }
            json["claudeAiOauth"] = oauth
        } else {
            json["access_token"] = credential.accessToken
            json["refresh_token"] = credential.refreshToken
            json["expired"] = credential.expiresAt?.ISO8601Format()
            json["last_refresh"] = Date().ISO8601Format()
        }
        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Fetch usage data from Anthropic OAuth API
    /// - Returns: ClaudeAPIResult indicating success, auth error, or other error
    private func fetchUsageFromAPI(accessToken: String) async -> ClaudeAPIResult {
        guard let url = URL(string: usageURL) else {
            return .otherError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.addValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return .otherError }
            if httpResponse.statusCode == 401 { return .authenticationError }
            if httpResponse.statusCode == 403 { return .permissionError }
            guard 200...299 ~= httpResponse.statusCode else {
                NSLog("[ClaudeQuota] HTTP error: \(httpResponse.statusCode)")
                return .otherError
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[ClaudeQuota] Failed to parse JSON response")
                return .otherError
            }

            // Check for API error response
            if json["type"] as? String == "error" {
                // Check if it's an authentication error
                if let errorObj = json["error"] as? [String: Any],
                    let errorType = errorObj["type"] as? String,
                    errorType == "authentication_error"
                {
                    // Token expired or invalid
                    NSLog("[ClaudeQuota] Usage authentication failed")
                    return .authenticationError
                }
                NSLog("[ClaudeQuota] Usage API returned an error")
                return .otherError
            }

            // API returns data directly (no wrapper)
            let fiveHour = parseQuotaUsage(from: json["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: json["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any])
            let extraUsage = parseExtraUsage(from: json["extra_usage"] as? [String: Any])

            return .success(
                ClaudeCodeQuotaInfo(
                    fiveHour: fiveHour,
                    sevenDay: sevenDay,
                    sevenDaySonnet: sevenDaySonnet,
                    sevenDayOpus: sevenDayOpus,
                    extraUsage: extraUsage
                ))
        } catch {
            NSLog("[ClaudeQuota] Network error: \(error.localizedDescription)")
            return .otherError
        }
    }

    /// Fetch quota for all Claude accounts from auth files in ~/.cli-proxy-api/
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data
    func fetchAsProviderQuota(
        forceRefresh: Bool = false,
        includeMonitorCredentials: Bool = false
    ) async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        let legacyFiles =
            (try? fileManager.contentsOfDirectory(atPath: expandedPath))?
            .filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
            .map { (expandedPath as NSString).appendingPathComponent($0) } ?? []
        let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeBase = (claudeHome?.isEmpty == false ? claudeHome! : NSString(string: "~/.claude").expandingTildeInPath)
        let nativePath = (nativeBase as NSString).appendingPathComponent(".credentials.json")
        let nativePaths = fileManager.fileExists(atPath: nativePath) ? [nativePath] : []
        var results: [String: ProviderQuotaData] = [:]
        var selectedKeys: Set<String> = []
        if includeMonitorCredentials {
            for account in await vault.accounts() where account.provider == .claude && !account.isDisabled {
                selectedKeys.insert(account.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                results[account.accountKey] = await fetchOwnedQuota(account: account, forceRefresh: forceRefresh)
            }
        }
        if let key = nativeKeychainIdentity(),
            selectedKeys.insert(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
        {
            results.merge(await fetchNativeKeychainQuotas(forceRefresh: forceRefresh)) { existing, _ in existing }
        }
        for filePath in nativePaths {
            guard let key = authFileIdentity(at: filePath),
                selectedKeys.insert(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted,
                let quota = await fetchQuotaFromAuthFile(at: filePath, forceRefresh: forceRefresh)
            else { continue }
            results[quota.email] = quota.data
        }

        if selectedKeys.insert("claude desktop").inserted,
            let desktop = await fetchClaudeDesktopQuota(forceRefresh: forceRefresh)
        {
            results[desktop.key] = desktop.value
        }

        for filePath in legacyFiles {
            guard let key = authFileIdentity(at: filePath),
                selectedKeys.insert(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted,
                let quota = await fetchQuotaFromAuthFile(at: filePath, forceRefresh: forceRefresh)
            else { continue }
            results[quota.email] = quota.data
        }

        return results
    }

    /// Fetch quota for exactly one canonical Claude account.
    func fetchQuota(accountKey: String, forceRefresh: Bool = false, allowUserInteraction: Bool = false) async -> ProviderQuotaData? {
        if let account = await vault.accounts().first(where: {
            $0.provider == .claude && !$0.isDisabled && $0.accountKey == accountKey
        }) {
            return await fetchOwnedQuota(account: account, forceRefresh: forceRefresh, allowUserInteraction: allowUserInteraction)
        }

        if nativeKeychainIdentity() == accountKey {
            return await fetchNativeKeychainQuotas(forceRefresh: forceRefresh)[accountKey]
        }

        let fileManager = FileManager.default
        let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeBase = (claudeHome?.isEmpty == false ? claudeHome! : NSString(string: "~/.claude").expandingTildeInPath)
        let nativePath = (nativeBase as NSString).appendingPathComponent(".credentials.json")
        if fileManager.fileExists(atPath: nativePath), authFileIdentity(at: nativePath) == accountKey {
            return await fetchQuotaFromAuthFile(at: nativePath, forceRefresh: forceRefresh)?.data
        }

        if accountKey == "Claude Desktop" {
            return await fetchClaudeDesktopQuota(forceRefresh: forceRefresh)?.value
        }

        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let legacyFiles =
            (try? fileManager.contentsOfDirectory(atPath: expandedPath))?
            .filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") } ?? []
        for filename in legacyFiles {
            let path = (expandedPath as NSString).appendingPathComponent(filename)
            guard let identity = authFileIdentity(at: path), identity == accountKey else { continue }
            return await fetchQuotaFromAuthFile(at: path, forceRefresh: forceRefresh)?.data
        }
        return nil
    }

    private func authFileIdentity(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = json["claudeAiOauth"] as? [String: Any]
        guard json["access_token"] as? String != nil || oauth?["accessToken"] as? String != nil else { return nil }
        return json["email"] as? String ?? oauth?["email"] as? String ?? "Claude Code"
    }

    private func nativeKeychainIdentity() -> String? {
        guard let record = KeychainHelper.readExternalCredentialRecord(service: "Claude Code-credentials"),
            let json = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            oauth["accessToken"] as? String != nil
        else { return nil }
        return oauth["email"] as? String ?? "Claude Code"
    }

    private func fetchClaudeDesktopQuota(forceRefresh: Bool) async -> (key: String, value: ProviderQuotaData)? {
        let key = "Claude Desktop"
        if !forceRefresh, let cached = quotaCache[key], cached.isValid(ttl: cacheTTL) {
            return (key, cached.data)
        }
        guard let credential = ClaudeDesktopCredentialReader.load() else { return nil }
        let response = await fetchUsageFromAPI(accessToken: credential.accessToken)
        guard let quota = quotaResult(response, email: key) else { return nil }
        return (key, quota)
    }

    private func fetchNativeKeychainQuotas(forceRefresh: Bool) async -> [String: ProviderQuotaData] {
        guard let record = KeychainHelper.readExternalCredentialRecord(service: "Claude Code-credentials"),
            let json = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return [:] }
        let email = oauth["email"] as? String ?? "Claude Code"
        guard let quota = await fetchQuota(source: .keychain(record.account), email: email, forceRefresh: forceRefresh) else { return [:] }
        return [email: quota]
    }

    func fetchOwnedQuota(account: MonitorAccount, forceRefresh: Bool, allowUserInteraction: Bool = false) async -> ProviderQuotaData? {
        if allowUserInteraction, await vault.credential(for: account.id) == nil {
            guard await vault.credentialForUserInitiatedAccess(for: account.id) != nil else { return nil }
        }
        return await fetchQuota(source: .owned(account), email: account.accountKey, forceRefresh: forceRefresh)
    }

    private func quotaData(from info: ClaudeCodeQuotaInfo) -> ProviderQuotaData? {
        var models: [ModelQuota] = []
        if let value = info.fiveHour {
            models.append(ModelQuota(name: "five-hour-session", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDay {
            models.append(ModelQuota(name: "seven-day-weekly", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDaySonnet {
            models.append(ModelQuota(name: "seven-day-sonnet", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDayOpus {
            models.append(ModelQuota(name: "seven-day-opus", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let extra = info.extraUsage, let remaining = extra.remaining {
            var model = ModelQuota(name: "extra-usage", percentage: remaining, resetTime: "")
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                model.used = Int(used)
                model.limit = Int(limit)
            }
            models.append(model)
        }
        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: Date(), isForbidden: false, planType: nil)
    }

    /// Fetch quota from a single auth file
    /// - Parameters:
    ///   - path: Path to the auth file
    ///   - forceRefresh: If true, bypass cache
    func fetchQuotaFromAuthFile(at path: String, forceRefresh: Bool = false) async -> (email: String, data: ProviderQuotaData)? {
        guard let email = authFileIdentity(at: path),
            let quota = await fetchQuota(source: .file(path), email: email, forceRefresh: forceRefresh)
        else { return nil }
        return (email, quota)
    }

    /// Clear the quota cache
    func clearCache() {
        quotaCache.removeAll()
    }

    /// Clear cache for a specific email
    func clearCache(for email: String) {
        quotaCache.removeValue(forKey: email)
    }

}
