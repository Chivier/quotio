//
//  CodexCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Codex CLI by reading ~/.codex/auth.json and calling ChatGPT usage API
//  Used in Quota-Only mode for direct quota tracking without proxy
//

import Foundation

/// Auth file structure for Codex CLI (~/.codex/auth.json)
nonisolated struct CodexCLIAuthFile: Codable, Sendable {
    var OPENAI_API_KEY: String?
    var tokens: CodexCLITokens?
    var lastRefresh: String?
    
    enum CodingKeys: String, CodingKey {
        case OPENAI_API_KEY
        case tokens
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct CodexCLITokens: Codable, Sendable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var accountId: String?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

/// Decoded JWT claims from Codex id_token
nonisolated struct CodexJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let planType: String?
    let accountId: String?
    let userId: String?
    let organizationName: String?
    let subscriptionActiveUntil: Date?
}

nonisolated struct CodexQuotaAccountIdentity: Sendable {
    let key: String
    let email: String?
    let accountID: String?
}

nonisolated struct CodexAccountQuotaResult: Sendable {
    let accountKey: String
    let quota: ProviderQuotaData
}

/// Fetches quota from Codex CLI auth file
actor CodexCLIQuotaFetcher {
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let refreshURL = "https://auth.openai.com/oauth/token"
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    
    private var session: URLSession
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

#if DEBUG
    private func debugMask(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<nil>" }
        if value.count <= 8 { return "\(value) (len=\(value.count))" }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)…\(suffix) (len=\(value.count))"
    }
#endif

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }
    
    private var authFilePaths: [String] {
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(NSString(string: "~/.config/codex/auth.json").expandingTildeInPath)
        paths.append(NSString(string: "~/.codex/auth.json").expandingTildeInPath)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Check if any supported Codex auth source exists.
    func isAuthFilePresent() -> Bool {
        authFilePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Read auth file from ~/.codex/auth.json
    func readAuthFile() -> CodexCLIAuthFile? {
        for path in authFilePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { continue }
            return auth
        }
        return nil
    }

    private func readAuthSources() -> [(path: String, auth: CodexCLIAuthFile)] {
        authFilePaths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { return nil }
            return (path, auth)
        }
    }
    
    /// Decode JWT to extract email and plan info
    func decodeJWT(token: String) -> CodexJWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
        // Add padding if needed
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        
        // Extract email
        let email = json["email"] as? String
        let emailVerified = json["email_verified"] as? Bool ?? false
        
        // Extract plan info from nested auth object
        var planType: String? = nil
        var accountId: String? = nil
        var userId: String? = nil
        var orgName: String? = nil
        var subscriptionUntil: Date? = nil
        
        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any] {
            planType = authInfo["chatgpt_plan_type"] as? String
            accountId = authInfo["chatgpt_account_id"] as? String
            userId = authInfo["chatgpt_user_id"] as? String
            
            // Parse organizations
            if let orgs = authInfo["organizations"] as? [[String: Any]], let firstOrg = orgs.first {
                orgName = firstOrg["title"] as? String
            }
            
            // Parse subscription end date
            if let untilStr = authInfo["chatgpt_subscription_active_until"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                subscriptionUntil = formatter.date(from: untilStr)
            }
        }
        
        return CodexJWTClaims(
            email: email,
            emailVerified: emailVerified,
            planType: planType,
            accountId: accountId,
            userId: userId,
            organizationName: orgName,
            subscriptionActiveUntil: subscriptionUntil
        )
    }
    
    /// Fetch quota from ChatGPT usage API
    func fetchQuota(accessToken: String, accountId: String?, identity: CodexQuotaIdentity) async throws -> ProviderQuotaData {
        guard let url = URL(string: usageURL) else {
            throw CodexCLIQuotaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.addValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
#if DEBUG
        Log.quota("GET \(usageURL) accountId=\(debugMask(accountId))")
#endif
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexCLIQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.httpError(httpResponse.statusCode)
        }
        
        var quotaData = try CodexUsageMapper.map(data: data, identity: identity)
#if DEBUG
        Log.quota("plan_type=\(quotaData.planType ?? "<nil>")")
#endif
        if let resetCreditAnalytics = await fetchResetCreditAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = CodexResetCreditInventoryFetcher.merge(
                resetCreditAnalytics,
                into: quotaData.analytics
            )
        }
        if let profileAnalytics = await fetchProfileAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = quotaData.analytics?.merging(profileAnalytics) ?? profileAnalytics
        }
        return quotaData
    }

    private func fetchResetCreditAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexResetCreditInventoryFetcher(urlSession: session).fetchAnalytics(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex reset credit inventory: \(error)")
            return nil
        }
    }

    private func fetchProfileAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexProfileAnalyticsFetcher(urlSession: session).fetch(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex profile analytics: \(error)")
            return nil
        }
    }
    
    /// Refresh access token using refresh token
    nonisolated struct TokenRefresh: Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int?
    }

    func refreshAccessToken(refreshToken: String) async throws -> TokenRefresh {
        var request = URLRequest(url: URL(string: refreshURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "client_id=\(clientID.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.tokenRefreshFailed
        }
        
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Int?
        }
        
        let tokenResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return TokenRefresh(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            idToken: tokenResponse.id_token,
            expiresIn: tokenResponse.expires_in
        )
    }
    
    /// Check if access token is expired by decoding JWT
    func isTokenExpired(accessToken: String) -> Bool {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return true }
        
        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        
        // Refresh five minutes early so scheduled quota checks do not race token expiry.
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(300)
    }
    
    /// Fetch quota and convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        var results = await fetchOwnedQuotas()
        for (key, quota) in await fetchNativeKeychainQuotas() where results[key] == nil {
            results[key] = quota
        }
        for source in readAuthSources() {
            guard let tokens = source.auth.tokens, let originalAccessToken = tokens.accessToken else { continue }
            var email = "Codex User"
            var planType: String?
            var accountId = tokens.accountId
            if let idToken = tokens.idToken, let claims = decodeJWT(token: idToken) {
                email = claims.email ?? email
                planType = claims.planType
                accountId = accountId ?? claims.accountId
            }

            var accessToken = originalAccessToken
            var refreshToken = tokens.refreshToken
            if isTokenExpired(accessToken: accessToken), let currentRefresh = refreshToken {
                do {
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    accessToken = refreshed.accessToken
                    refreshToken = refreshed.refreshToken ?? currentRefresh
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                    if let refreshedClaims = refreshed.idToken.flatMap(decodeJWT) {
                        email = refreshedClaims.email ?? email
                        planType = refreshedClaims.planType ?? planType
                        accountId = accountId ?? refreshedClaims.accountId
                    }
                } catch {
                    Log.quota("Failed to refresh Codex token")
                }
            }

            do {
                let quota: ProviderQuotaData
                do {
                    quota = try await fetchQuota(
                        accessToken: accessToken,
                        accountId: accountId,
                        identity: CodexQuotaIdentity(planType: planType)
                    )
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    let latestTokens = readAuthFile(at: source.path)?.tokens
                    let currentRefresh = latestTokens?.refreshToken ?? refreshToken
                    guard let currentRefresh else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let latestClaims = latestTokens?.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                    let refreshedClaims = refreshed.idToken.flatMap(decodeJWT) ?? latestClaims
                    email = refreshedClaims?.email ?? email
                    planType = refreshedClaims?.planType ?? planType
                    accountId = latestTokens?.accountId ?? refreshedClaims?.accountId ?? accountId
                    quota = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: accountId,
                        identity: CodexQuotaIdentity(planType: planType)
                    )
                }
#if DEBUG
                Log.quota("finalPlan=\(quota.planType ?? "<nil>") jwt=\(planType ?? "<nil>")")
#endif
                let key = canonicalLocalKey(
                    email: email,
                    accountID: accountId,
                    fallback: "Codex User"
                )
                if results[key] == nil {
                    var displayedQuota = quota
                    displayedQuota.accountDisplayName = email
                    results[key] = displayedQuota
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for local credential: \(error.localizedDescription)")
            }
        }
        for (key, quota) in await fetchLegacyQuotas() where results[key] == nil {
            results[key] = quota
        }
        return await promoteFreshLegacyAliases(in: results)
    }

    /// Fetches only the credential represented by the canonical account key.
    func fetchQuota(forAccountKey accountKey: String) async -> ProviderQuotaData? {
        await fetchQuotaResult(forAccountKey: accountKey)?.quota
    }

    /// Foreground Monitor refreshes may ask macOS to authorize an existing
    /// Quotio-owned Keychain item. All scheduled/provider-wide paths continue to
    /// use `fetchAsProviderQuota()` and therefore remain strictly prompt-free.
    func fetchQuotaResult(
        forAccountKey accountKey: String,
        allowUserInteraction: Bool = false
    ) async -> CodexAccountQuotaResult? {
        var matchedOwnedAccount = false
        for account in await MonitorCredentialVault.shared.accounts() where account.provider == .codex && !account.isDisabled {
            let mayIdentifyAccount = Self.accountKeyMayIdentifyStoredAccount(
                accountKey,
                metadataKey: account.accountKey,
                displayName: account.displayName
            )
            matchedOwnedAccount = matchedOwnedAccount || mayIdentifyAccount
            var credential = await MonitorCredentialVault.shared.credential(for: account.id)
            if credential == nil,
               allowUserInteraction,
               mayIdentifyAccount {
                credential = await MonitorCredentialVault.shared.credentialForUserInitiatedAccess(for: account.id)
            }
            guard let credential else { continue }
            let claims = credential.idToken.flatMap(decodeJWT)
            let key = canonicalLocalKey(
                email: claims?.email ?? account.displayName,
                accountID: credential.accountID ?? claims?.accountId,
                fallback: account.accountKey
            )
            if (Self.accountKeysMatch(account.accountKey, accountKey) || Self.accountKeysMatch(key, accountKey)),
               let quota = await fetchOwnedQuota(
                   account,
                   initialCredential: credential,
                   allowUserInteractionForPersistence: allowUserInteraction
               ) {
                return CodexAccountQuotaResult(accountKey: key, quota: quota)
            }
        }

        // Once an account key identifies an app-owned login, never satisfy that
        // request with a same-named credential from another source. That would
        // silently show one workspace's quota on another workspace's row.
        if matchedOwnedAccount { return nil }

        if let record = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth"),
           let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
           let tokens = auth.tokens {
            let claims = tokens.idToken.flatMap(decodeJWT)
            let key = canonicalLocalKey(
                email: claims?.email,
                accountID: tokens.accountId ?? claims?.accountId,
                fallback: "Codex"
            )
            if Self.accountKeysMatch(key, accountKey),
               let quota = await fetchNativeKeychainQuotas().values.first {
                return CodexAccountQuotaResult(accountKey: key, quota: quota)
            }
        }

        for source in readAuthSources() {
            guard let tokens = source.auth.tokens else { continue }
            let claims = tokens.idToken.flatMap(decodeJWT)
            let key = canonicalLocalKey(
                email: claims?.email,
                accountID: tokens.accountId ?? claims?.accountId,
                fallback: "Codex User"
            )
            guard Self.accountKeysMatch(key, accountKey),
                  let quota = await fetchLocalAuthQuota(source: source, claims: claims)
            else { continue }
            return CodexAccountQuotaResult(accountKey: key, quota: quota)
        }

        let directory = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let filename = try? FileManager.default.contentsOfDirectory(atPath: directory).first(where: {
            $0.hasPrefix("codex-") && $0.hasSuffix(".json") && $0.codexFilenameKey == accountKey
        }) else { return nil }
        let path = (directory as NSString).appendingPathComponent(filename)
        guard let quota = await fetchLegacyQuota(at: path) else { return nil }
        return CodexAccountQuotaResult(accountKey: accountKey, quota: quota)
    }

    nonisolated static func accountKeysMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Older Monitor metadata used only the email while quota snapshots may
    /// already contain the newer `email • fingerprint` key. Recognize that
    /// narrow migration shape before asking Keychain for the credential; the
    /// exact canonical key is still verified after the credential is decoded.
    nonisolated static func accountKeyMayIdentifyStoredAccount(
        _ requestedKey: String,
        metadataKey: String,
        displayName: String
    ) -> Bool {
        if accountKeysMatch(requestedKey, metadataKey) { return true }

        // A metadata key that already carries a fingerprint identifies exactly
        // one workspace. Its plain display email and sibling fingerprints must
        // remain available to their own credential sources.
        if hasFingerprintSuffix(metadataKey) { return false }
        if accountKeysMatch(requestedKey, displayName) { return true }

        let normalizedRequested = requestedKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for base in [metadataKey, displayName] {
            let normalizedBase = base
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let prefix = normalizedBase + " • "
            guard normalizedRequested.hasPrefix(prefix) else { continue }
            let suffix = normalizedRequested.dropFirst(prefix.count)
            if suffix.count == 8, suffix.allSatisfy(\.isHexDigit) {
                return true
            }
        }
        return false
    }

    private nonisolated static func hasFingerprintSuffix(_ accountKey: String) -> Bool {
        guard let delimiter = accountKey.range(of: " • ", options: .backwards) else { return false }
        let suffix = accountKey[delimiter.upperBound...]
        return suffix.count == 8 && suffix.allSatisfy(\.isHexDigit)
    }

    private func canonicalLocalKey(email: String?, accountID: String?, fallback: String) -> String {
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases: [String: String] = [:]
        if let normalizedAccountID, !normalizedAccountID.isEmpty {
            let matchingAliases = Set(readLegacyIdentities().compactMap { identity -> String? in
                guard identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedAccountID else {
                    return nil
                }
                return identity.key
            })
            if matchingAliases.count == 1, let alias = matchingAliases.first {
                aliases[normalizedAccountID] = alias
            }
        }
        return CodexAccountKey.canonical(
            email: email,
            accountID: accountID,
            aliases: aliases,
            fallback: fallback
        )
    }

    private func fetchLocalAuthQuota(
        source: (path: String, auth: CodexCLIAuthFile),
        claims: CodexJWTClaims?
    ) async -> ProviderQuotaData? {
        guard let tokens = source.auth.tokens, var accessToken = tokens.accessToken else { return nil }
        var refreshToken = tokens.refreshToken
        if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
            guard let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken) else { return nil }
            accessToken = refreshed.accessToken
            try? self.persistRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: source.path)
            refreshToken = refreshed.refreshToken ?? currentRefreshToken
        }
        do {
            var quota = try await fetchQuota(
                accessToken: accessToken,
                accountId: tokens.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: claims?.planType)
            )
            quota.accountDisplayName = claims?.email
            return quota
        } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
            guard let latest = readAuthFile(at: source.path)?.tokens,
                  let refresh = latest.refreshToken ?? refreshToken,
                  let refreshed = try? await refreshAccessToken(refreshToken: refresh) else { return nil }
            try? persistRefresh(refreshed, originalRefreshToken: refresh, path: source.path)
            let latestClaims = latest.idToken.flatMap(decodeJWT)
            guard var quota = try? await fetchQuota(
                accessToken: refreshed.accessToken,
                accountId: latest.accountId ?? latestClaims?.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
            ) else { return nil }
            quota.accountDisplayName = latestClaims?.email ?? claims?.email
            return quota
        } catch {
            return nil
        }
    }

    func reconcileLegacyAliases(
        in quotas: [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        Self.reconcileLegacyAliases(
            in: quotas,
            legacy: readLegacyIdentities(),
            current: await currentAccountIdentities()
        )
    }

    func promoteFreshLegacyAliases(
        in quotas: [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        Self.promoteFreshLegacyAliases(
            in: quotas,
            legacy: readLegacyIdentities(),
            current: await currentAccountIdentities()
        )
    }

    nonisolated static func promoteFreshLegacyAliases(
        in quotas: [String: ProviderQuotaData],
        legacy: [CodexQuotaAccountIdentity],
        current: [CodexQuotaAccountIdentity]
    ) -> [String: ProviderQuotaData] {
        var promoted = quotas
        let uniqueLegacyByAccountID = Dictionary(grouping: legacy.compactMap { identity -> (String, CodexQuotaAccountIdentity)? in
            guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty else { return nil }
            return (accountID, identity)
        }, by: \.0).compactMapValues { entries -> CodexQuotaAccountIdentity? in
            let identities = entries.map(\.1)
            guard Set(identities.map(\.key)).count == 1 else { return nil }
            return identities.first
        }
        let currentByKey = Dictionary(grouping: current, by: \.key)

        for (key, quota) in quotas {
            let identities = currentByKey[key, default: []]
            let accountIDs = identities.compactMap { identity -> String? in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty else { return nil }
                return accountID
            }
            let distinctAccountIDs = Set(accountIDs)
            guard accountIDs.count == identities.count,
                  distinctAccountIDs.count == 1,
                  let accountID = distinctAccountIDs.first,
                  let legacyIdentity = uniqueLegacyByAccountID[accountID],
                  legacyIdentity.key != key else { continue }
            if promoted[legacyIdentity.key].map({ $0.lastUpdated <= quota.lastUpdated }) ?? true {
                promoted[legacyIdentity.key] = quota
            }
            promoted.removeValue(forKey: key)
        }
        return promoted
    }

    private func currentAccountIdentities() async -> [CodexQuotaAccountIdentity] {
        var current = readAuthSources().map { source in
            let claims = source.auth.tokens?.idToken.flatMap(decodeJWT)
            let accountID = source.auth.tokens?.accountId ?? claims?.accountId
            return CodexQuotaAccountIdentity(
                key: canonicalLocalKey(
                    email: claims?.email,
                    accountID: accountID,
                    fallback: "Codex User"
                ),
                email: claims?.email,
                accountID: accountID
            )
        }

        if let record = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth"),
           let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
           let tokens = auth.tokens {
            let claims = tokens.idToken.flatMap(decodeJWT)
            let accountID = tokens.accountId ?? claims?.accountId
            current.append(CodexQuotaAccountIdentity(
                key: canonicalLocalKey(
                    email: claims?.email,
                    accountID: accountID,
                    fallback: "Codex"
                ),
                email: claims?.email,
                accountID: accountID
            ))
        }

        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .codex }) {
            guard let credential = await MonitorCredentialVault.shared.credential(for: account.id) else { continue }
            let claims = credential.idToken.flatMap(decodeJWT)
            let accountID = credential.accountID ?? claims?.accountId
            current.append(CodexQuotaAccountIdentity(
                key: canonicalLocalKey(
                    email: claims?.email ?? account.displayName,
                    accountID: accountID,
                    fallback: account.accountKey
                ),
                email: claims?.email ?? account.displayName,
                accountID: accountID
            ))
        }
        return current
    }

    nonisolated static func reconcileLegacyAliases(
        in quotas: [String: ProviderQuotaData],
        legacy: [CodexQuotaAccountIdentity],
        current: [CodexQuotaAccountIdentity]
    ) -> [String: ProviderQuotaData] {
        var reconciled = quotas
        let legacyByEmail = Dictionary(grouping: legacy.compactMap { identity -> (String, CodexQuotaAccountIdentity)? in
            guard let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            return (email, identity)
        }, by: \.0)

        for (email, entries) in legacyByEmail {
            let legacyAccounts = entries.map(\.1)
            guard legacyAccounts.contains(where: { reconciled[$0.key] != nil }) else { continue }

            let legacyAccountIDs = Set(legacyAccounts.compactMap { identity -> String? in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty else { return nil }
                return accountID
            })
            let matchingCurrent = current.filter {
                $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
            }
            for currentIdentity in matchingCurrent {
                guard let freshQuota = reconciled[currentIdentity.key],
                      let currentAccountID = currentIdentity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !currentAccountID.isEmpty,
                      matchingCurrent.filter({ $0.key == currentIdentity.key }).allSatisfy({
                    $0.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == currentAccountID
                }) else { continue }
                for legacyAccount in legacyAccounts where
                    legacyAccount.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == currentAccountID {
                    guard reconciled[legacyAccount.key].map({ $0.lastUpdated <= freshQuota.lastUpdated }) ?? true else {
                        continue
                    }
                    reconciled[legacyAccount.key] = freshQuota
                }
            }
            let hasDistinctCurrentAccount = matchingCurrent.contains { identity in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty, !legacyAccountIDs.isEmpty else { return true }
                return !legacyAccountIDs.contains(accountID)
            }
            guard !hasDistinctCurrentAccount else { continue }

            for key in reconciled.keys where key.lowercased() == email {
                reconciled.removeValue(forKey: key)
            }
        }

        // Versions that keyed a Quotio-owned or native Codex login by email can
        // leave that old snapshot row beside the new account-ID-qualified key.
        // Remove only an email alias that is no longer a canonical current key
        // and is not the real filename key of a distinct legacy account.
        let currentByEmail = Dictionary(grouping: current.compactMap { identity -> (String, CodexQuotaAccountIdentity)? in
            guard let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            return (email, identity)
        }, by: \.0)
        for (email, entries) in currentByEmail {
            let currentIdentities = entries.map(\.1)
            guard currentIdentities.allSatisfy({ $0.key.lowercased() != email }) else { continue }
            let emailIsLegacyFilenameKey = legacyByEmail[email, default: []]
                .map(\.1)
                .contains { $0.key.lowercased() == email }
            guard !emailIsLegacyFilenameKey else { continue }
            for key in reconciled.keys where key.lowercased() == email {
                reconciled.removeValue(forKey: key)
            }
        }
        return reconciled
    }

    private func readLegacyIdentities() -> [CodexQuotaAccountIdentity] {
        let directory = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return files.compactMap { filename in
            guard filename.hasPrefix("codex-"), filename.hasSuffix(".json") else { return nil }
            let path = (directory as NSString).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
            let claims = auth.idToken.flatMap(decodeJWT)
            return CodexQuotaAccountIdentity(
                key: filename.codexFilenameKey,
                email: claims?.email,
                accountID: auth.accountId ?? claims?.accountId
            )
        }
    }

    private func fetchLegacyQuotas() async -> [String: ProviderQuotaData] {
        let directory = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var results: [String: ProviderQuotaData] = [:]

        for filename in files where filename.hasPrefix("codex-") && filename.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { continue }
            let claims = auth.idToken.flatMap(decodeJWT)
            let key = filename.codexFilenameKey
            let accountID = auth.accountId ?? claims?.accountId
            let identity = CodexQuotaIdentity(planType: claims?.planType)
            var accessToken = auth.accessToken
            var refreshToken = auth.refreshToken

            if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
                if let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken) {
                    accessToken = refreshed.accessToken
                    self.persistLegacyRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: path)
                    refreshToken = refreshed.refreshToken ?? currentRefreshToken
                }
            }

            do {
                do {
                    var quota = try await fetchQuota(accessToken: accessToken, accountId: accountID, identity: identity)
                    quota.accountDisplayName = claims?.email
                    results[key] = quota
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    guard let latestData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let latest = try? JSONDecoder().decode(CodexAuthFile.self, from: latestData),
                          let latestRefreshToken = latest.refreshToken ?? refreshToken else { continue }
                    let latestClaims = latest.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: latestRefreshToken)
                    persistLegacyRefresh(refreshed, originalRefreshToken: latestRefreshToken, path: path)
                    var quota = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: latest.accountId ?? latestClaims?.accountId ?? accountID,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
                    )
                    quota.accountDisplayName = latestClaims?.email ?? claims?.email
                    results[key] = quota
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for legacy credential: \(error.localizedDescription)")
            }
        }
        return results
    }

    private func fetchLegacyQuota(at path: String) async -> ProviderQuotaData? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
        let claims = auth.idToken.flatMap(decodeJWT)
        var accessToken = auth.accessToken
        var refreshToken = auth.refreshToken
        if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
            guard let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken) else { return nil }
            accessToken = refreshed.accessToken
            persistLegacyRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: path)
            refreshToken = refreshed.refreshToken ?? currentRefreshToken
        }
        do {
            var quota = try await fetchQuota(
                accessToken: accessToken,
                accountId: auth.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: claims?.planType)
            )
            quota.accountDisplayName = claims?.email
            return quota
        } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
            guard let latestData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let latest = try? JSONDecoder().decode(CodexAuthFile.self, from: latestData),
                  let refresh = latest.refreshToken ?? refreshToken,
                  let refreshed = try? await refreshAccessToken(refreshToken: refresh) else { return nil }
            persistLegacyRefresh(refreshed, originalRefreshToken: refresh, path: path)
            let latestClaims = latest.idToken.flatMap(decodeJWT)
            guard var quota = try? await fetchQuota(
                accessToken: refreshed.accessToken,
                accountId: latest.accountId ?? latestClaims?.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
            ) else { return nil }
            quota.accountDisplayName = latestClaims?.email ?? claims?.email
            return quota
        } catch {
            return nil
        }
    }

    private func fetchNativeKeychainQuotas() async -> [String: ProviderQuotaData] {
        guard let record = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth"),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
              var tokens = auth.tokens,
              var accessToken = tokens.accessToken else { return [:] }
        var claims = tokens.idToken.flatMap(decodeJWT)
        do {
            if isTokenExpired(accessToken: accessToken), let refresh = tokens.refreshToken {
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                accessToken = refreshed.accessToken
                tokens.accessToken = refreshed.accessToken
                tokens.refreshToken = refreshed.refreshToken ?? refresh
                tokens.idToken = refreshed.idToken ?? tokens.idToken
                claims = tokens.idToken.flatMap(decodeJWT)
                auth.tokens = tokens
                if let data = try? JSONEncoder().encode(auth) {
                    _ = KeychainHelper.compareAndSwapExternalCredential(
                        service: "Codex Auth",
                        account: record.account,
                        expectedData: record.data,
                        newData: data
                    )
                }
            }
            do {
                let key = canonicalLocalKey(
                    email: claims?.email,
                    accountID: tokens.accountId ?? claims?.accountId,
                    fallback: "Codex"
                )
                var quota = try await fetchQuota(
                    accessToken: accessToken,
                    accountId: tokens.accountId ?? claims?.accountId,
                    identity: CodexQuotaIdentity(planType: claims?.planType)
                )
                quota.accountDisplayName = claims?.email
                return [key: quota]
            } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                guard let latest = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth", account: record.account),
                      let latestAuth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
                      let latestTokens = latestAuth.tokens,
                      let refresh = latestTokens.refreshToken else { return [:] }
                let latestClaims = latestTokens.idToken.flatMap(decodeJWT)
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                persistNativeKeychainRefresh(refreshed, originalRefreshToken: refresh, account: record.account)
                let refreshedClaims = refreshed.idToken.flatMap(decodeJWT) ?? latestClaims
                let key = canonicalLocalKey(
                    email: refreshedClaims?.email ?? claims?.email,
                    accountID: latestTokens.accountId ?? refreshedClaims?.accountId ?? claims?.accountId,
                    fallback: "Codex"
                )
                var quota = try await fetchQuota(
                    accessToken: refreshed.accessToken,
                    accountId: latestTokens.accountId ?? refreshedClaims?.accountId,
                    identity: CodexQuotaIdentity(planType: refreshedClaims?.planType)
                )
                quota.accountDisplayName = refreshedClaims?.email ?? claims?.email
                return [key: quota]
            }
        } catch {
            return [:]
        }
    }

    private func persistNativeKeychainRefresh(
        _ refreshed: TokenRefresh,
        originalRefreshToken: String,
        account: String
    ) {
        guard let latest = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth", account: account),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
              var tokens = auth.tokens,
              tokens.refreshToken == originalRefreshToken else { return }
        tokens.accessToken = refreshed.accessToken
        tokens.refreshToken = refreshed.refreshToken ?? originalRefreshToken
        tokens.idToken = refreshed.idToken ?? tokens.idToken
        auth.tokens = tokens
        guard let data = try? JSONEncoder().encode(auth) else { return }
        _ = KeychainHelper.compareAndSwapExternalCredential(
            service: "Codex Auth",
            account: account,
            expectedData: latest.data,
            newData: data
        )
    }

    private func fetchOwnedQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .codex && !$0.isDisabled }) {
            guard var credential = await MonitorCredentialVault.shared.credential(for: account.id) else { continue }
            do {
                if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? isTokenExpired(accessToken: credential.accessToken),
                   let refresh = credential.refreshToken {
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                }
                let claims = credential.idToken.flatMap(decodeJWT)
                let displayName = claims?.email ?? account.displayName
                let key = canonicalLocalKey(
                    email: displayName,
                    accountID: credential.accountID ?? claims?.accountId,
                    fallback: account.accountKey
                )
                do {
                    var quota = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? claims?.accountId,
                        identity: CodexQuotaIdentity(planType: claims?.planType)
                    )
                    quota.accountDisplayName = displayName
                    results[key] = quota
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id) {
                        credential = latest
                    }
                    guard let refresh = credential.refreshToken else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                    let latestClaims = credential.idToken.flatMap(decodeJWT)
                    let latestDisplayName = latestClaims?.email ?? displayName
                    let latestKey = canonicalLocalKey(
                        email: latestDisplayName,
                        accountID: credential.accountID ?? latestClaims?.accountId,
                        fallback: key
                    )
                    var quota = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? latestClaims?.accountId,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
                    )
                    quota.accountDisplayName = latestDisplayName
                    results[latestKey] = quota
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for Quotio credential")
            }
        }
        return results
    }

    private func fetchOwnedQuota(
        _ account: MonitorAccount,
        initialCredential: MonitorOAuthCredential? = nil,
        allowUserInteractionForPersistence: Bool = false
    ) async -> ProviderQuotaData? {
        let storedCredential: MonitorOAuthCredential?
        if let initialCredential {
            storedCredential = initialCredential
        } else {
            storedCredential = await MonitorCredentialVault.shared.credential(for: account.id)
        }
        guard var credential = storedCredential else { return nil }
        do {
            if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? isTokenExpired(accessToken: credential.accessToken),
               let refresh = credential.refreshToken {
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                credential.accessToken = refreshed.accessToken
                credential.refreshToken = refreshed.refreshToken ?? refresh
                credential.idToken = refreshed.idToken ?? credential.idToken
                credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                try await persistOwnedCredential(
                    credential,
                    metadata: account,
                    allowUserInteraction: allowUserInteractionForPersistence
                )
            }
            let claims = credential.idToken.flatMap(decodeJWT)
            do {
                return try await fetchQuota(
                    accessToken: credential.accessToken,
                    accountId: credential.accountID ?? claims?.accountId,
                    identity: CodexQuotaIdentity(planType: claims?.planType)
                )
            } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id) {
                    credential = latest
                }
                guard let refresh = credential.refreshToken else { return nil }
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                credential.accessToken = refreshed.accessToken
                credential.refreshToken = refreshed.refreshToken ?? refresh
                credential.idToken = refreshed.idToken ?? credential.idToken
                credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                try await persistOwnedCredential(
                    credential,
                    metadata: account,
                    allowUserInteraction: allowUserInteractionForPersistence
                )
                let latestClaims = credential.idToken.flatMap(decodeJWT)
                return try await fetchQuota(
                    accessToken: credential.accessToken,
                    accountId: credential.accountID ?? latestClaims?.accountId,
                    identity: CodexQuotaIdentity(planType: latestClaims?.planType)
                )
            }
        } catch {
            return nil
        }
    }

    private func persistOwnedCredential(
        _ credential: MonitorOAuthCredential,
        metadata account: MonitorAccount,
        allowUserInteraction: Bool
    ) async throws {
        if allowUserInteraction {
            try await MonitorCredentialVault.shared.saveUserInitiated(credential, metadata: account)
        } else {
            try await MonitorCredentialVault.shared.save(credential, metadata: account)
        }
    }

    private func persistRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              var tokenJSON = json["tokens"] as? [String: Any],
              tokenJSON["refresh_token"] as? String == originalRefreshToken else {
            return
        }
        tokenJSON["access_token"] = refreshed.accessToken
        tokenJSON["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { tokenJSON["id_token"] = idToken }
        json["tokens"] = tokenJSON
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try SecureAtomicFileWriter.write(data, to: url)
    }

    private func persistLegacyRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              json["refresh_token"] as? String == originalRefreshToken else { return }
        json["access_token"] = refreshed.accessToken
        json["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { json["id_token"] = idToken }
        let lifetime = TimeInterval(refreshed.expiresIn ?? 3600)
        json["expired"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(lifetime))
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? SecureAtomicFileWriter.write(data, to: url)
    }

    private func readAuthFile(at path: String) -> CodexCLIAuthFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data)
    }
}

private extension String {
    nonisolated var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Errors

nonisolated enum CodexCLIQuotaError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in Codex auth file"
        case .tokenRefreshFailed: return "Failed to refresh Codex token"
        }
    }
}
