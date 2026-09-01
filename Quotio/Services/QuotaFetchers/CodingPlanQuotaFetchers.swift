import Foundation
import Darwin

// MARK: - Shared JSON helpers

nonisolated enum CodingPlanJSON {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as Int64: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    static func string(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    static func resetTime(
        in detail: [String: Any],
        window: [String: Any]? = nil,
        now: Date
    ) -> String {
        for source in [detail, window].compactMap({ $0 }) {
            for key in ["reset_at", "resetAt", "reset_time", "resetTime", "next_reset_at"] {
                guard let value = source[key] else { continue }
                if let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, Double(trimmed) == nil { return trimmed }
                    if let epoch = Double(trimmed) { return iso8601(epoch: epoch) }
                } else if let epoch = number(value) {
                    return iso8601(epoch: epoch)
                }
            }
            for key in ["reset_in", "resetIn", "reset_in_seconds", "ttl", "remaining_seconds"] {
                if let seconds = number(source[key]), seconds >= 0 {
                    return ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
                }
            }
        }
        return ""
    }

    static func iso8601(epoch: Double) -> String {
        let seconds = epoch > 1_000_000_000_000 ? epoch / 1000 : epoch
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    static func model(
        name: String,
        detail: [String: Any],
        window: [String: Any]? = nil,
        now: Date
    ) -> ModelQuota? {
        let limit = number(detail["limit"] ?? detail["total"] ?? detail["quota"])
        let used = number(detail["used"] ?? detail["consumed"])
        let remaining = number(detail["remaining"] ?? detail["left"])
        let explicitRemainingPercent = number(
            detail["remaining_percent"] ?? detail["remainingPercent"]
        )

        let remainingPercent: Double?
        if let limit, limit > 0, let used {
            remainingPercent = (limit - used) / limit * 100
        } else if let limit, limit > 0, let remaining {
            remainingPercent = remaining / limit * 100
        } else {
            remainingPercent = explicitRemainingPercent
        }
        guard let remainingPercent else { return nil }

        return ModelQuota(
            name: name,
            percentage: max(0, min(100, remainingPercent)),
            resetTime: resetTime(in: detail, window: window, now: now),
            used: used.map { Int($0.rounded()) },
            limit: limit.map { Int($0.rounded()) },
            remaining: (remaining ?? limit.flatMap { total in used.map { max(0, total - $0) } })
                .map { Int($0.rounded()) }
        )
    }
}

// MARK: - Kimi Code

nonisolated enum KimiQuotaMapper {
    static func map(_ data: Data, now: Date = Date()) -> ProviderQuotaData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let root = CodingPlanJSON.object(json["data"]) ?? json
        var models: [ModelQuota] = []

        if let limits = root["limits"] as? [Any] {
            let ordered = limits.compactMap { item -> (duration: Double?, detail: [String: Any], window: [String: Any]?)? in
                guard let item = item as? [String: Any] else { return nil }
                let detail = CodingPlanJSON.object(item["detail"]) ?? item
                let window = CodingPlanJSON.object(item["window"])
                return (durationSeconds(window), detail, window)
            }.sorted { lhs, rhs in
                switch (lhs.duration, rhs.duration) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): false
                }
            }
            if let first = ordered.first,
               let model = CodingPlanJSON.model(
                   name: "kimi-five-hour",
                   detail: first.detail,
                   window: first.window,
                   now: now
               ) {
                models.append(model)
            }
        }

        if let usage = CodingPlanJSON.object(root["usage"]),
           let weekly = CodingPlanJSON.model(name: "kimi-weekly", detail: usage, window: CodingPlanJSON.object(usage["window"]), now: now) {
            models.append(weekly)
        }

        guard !models.isEmpty else { return nil }
        let plan = CodingPlanJSON.string(
            root,
            keys: ["plan", "plan_name", "subscription_plan", "tier", "membership", "level", "product"]
        ) ?? CodingPlanJSON.string(CodingPlanJSON.object(root["subscription"]), keys: ["name", "plan", "tier", "level"])
        let displayName = CodingPlanJSON.string(root, keys: ["email", "user_email"])
            ?? CodingPlanJSON.string(CodingPlanJSON.object(root["user"]), keys: ["email"])
        return ProviderQuotaData(
            models: models,
            lastUpdated: now,
            planType: plan,
            accountDisplayName: displayName
        )
    }

    private static func durationSeconds(_ window: [String: Any]?) -> Double? {
        guard let window, let duration = CodingPlanJSON.number(window["duration"]) else { return nil }
        let unit = CodingPlanJSON.string(window, keys: ["timeUnit", "time_unit", "unit"])?.uppercased() ?? ""
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 3600 }
        if unit.contains("DAY") { return duration * 86400 }
        return duration
    }
}

nonisolated struct KimiLocalCredential: Sendable {
    let accountKey: String
    let displayName: String
    let accessToken: String
    let sourcePath: String
    let headers: [String: String]

    var account: MonitorAccount {
        .make(
            provider: .kimi,
            accountKey: accountKey,
            displayName: displayName,
            source: .nativeCredential,
            credentialReference: sourcePath
        )
    }
}

nonisolated enum KimiCredentialReader {
    static let cliCredentialPath = "~/.kimi-code/credentials/kimi-code.json"
    static let legacyConfigPath = "~/.kimi/config.toml"

    static func loadAll(now: Date = Date()) -> [KimiLocalCredential] {
        var credentials: [KimiLocalCredential] = []
        if let cli = loadCLICredential(now: now) { credentials.append(cli) }
        credentials.append(contentsOf: loadLegacyConfig())
        return credentials
    }

    static func loadCLICredential(now: Date = Date(), path: String? = nil) -> KimiLocalCredential? {
        let path = path ?? MonitorIdentity.expand(cliCredentialPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = cleaned(json["access_token"] as? String),
              let expiresAt = CodingPlanJSON.number(json["expires_at"]),
              expiresAt > now.addingTimeInterval(60).timeIntervalSince1970 else { return nil }

        let home = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deviceID = cleaned(try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8))
            ?? "quotio-" + String(MonitorIdentity.fingerprint(token).prefix(32))
        return KimiLocalCredential(
            accountKey: "Kimi Code",
            displayName: "Kimi Code CLI",
            accessToken: token,
            sourcePath: path,
            headers: identityHeaders(accessToken: token, deviceID: deviceID)
        )
    }

    static func identityHeaders(accessToken: String, deviceID: String? = nil) -> [String: String] {
        let version = asciiHeaderValue(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        )
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let resolvedDeviceID = cleaned(deviceID)
            ?? "quotio-" + String(MonitorIdentity.fingerprint(accessToken).prefix(32))
        return [
            "User-Agent": "Quotio/\(version)",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": version,
            "X-Msh-Device-Name": asciiHeaderValue(localHostName),
            "X-Msh-Device-Model": asciiHeaderValue("macOS \(osVersion) \(architectureName)"),
            "X-Msh-Os-Version": asciiHeaderValue(osVersion),
            "X-Msh-Device-Id": resolvedDeviceID,
        ]
    }

    static func loadLegacyConfig(path: String? = nil) -> [KimiLocalCredential] {
        let path = path ?? MonitorIdentity.expand(legacyConfigPath)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var credentials: [KimiLocalCredential] = []
        var section: String?
        var sectionType: String?
        var sectionBaseURL: String?
        var sectionKey: String?

        func flush() {
            defer {
                sectionType = nil
                sectionBaseURL = nil
                sectionKey = nil
            }
            guard let token = cleaned(sectionKey) else { return }
            let normalizedSection = section?.lowercased() ?? ""
            let normalizedBaseURL = sectionBaseURL?.lowercased() ?? ""
            guard sectionType?.lowercased() == "kimi"
                    || normalizedSection.contains("kimi")
                    || normalizedBaseURL.contains("kimi.com/coding")
                    || normalizedBaseURL.contains("moonshot")
                    || token.hasPrefix("sk-kimi") else { return }
            let label = cleaned(section) ?? "Kimi Code"
            let suffix = String(MonitorIdentity.fingerprint(token).prefix(8))
            credentials.append(KimiLocalCredential(
                accountKey: "\(label) · \(suffix)",
                displayName: label,
                accessToken: token,
                sourcePath: path,
                headers: ["User-Agent": "Quotio-KimiMonitor/1.0"]
            ))
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = tomlString(String(line[line.index(after: equals)...]))
            switch key {
            case "api_key", "apikey": sectionKey = value
            case "type": sectionType = value
            case "base_url", "baseurl": sectionBaseURL = value
            default: break
            }
        }
        flush()

        var seen = Set<String>()
        return credentials.filter { seen.insert($0.accessToken).inserted }
    }

    private static func tomlString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'" else {
            if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
            return value.trimmingCharacters(in: .whitespaces)
        }
        value.removeFirst()
        return value.firstIndex(of: quote).map { String(value[..<$0]) } ?? value
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func asciiHeaderValue(_ raw: String) -> String {
        var ascii = ""
        for scalar in raw.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
            ascii.unicodeScalars.append(scalar)
        }
        let value = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unknown" : value
    }

    private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static var localHostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

actor KimiQuotaFetcher {
    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private let directAuthService: DirectAuthFileService
    private var session: URLSession
    private let endpoints = [
        URL(string: "https://api.kimi.com/coding/v1/usages")!,
        URL(string: "https://api.moonshot.ai/v1/usages")!,
    ]

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared,
        directAuthService: DirectAuthFileService = DirectAuthFileService()
    ) {
        self.vault = vault
        self.metadata = metadata
        self.directAuthService = directAuthService
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        let disabled = await metadata.disabledAccountIDs()

        for local in KimiCredentialReader.loadAll() where !disabled.contains(local.account.id) {
            if let quota = await fetch(accessToken: local.accessToken, headers: local.headers) {
                results[local.accountKey] = quota
            }
        }

        for file in await directAuthService.scanAllAuthFiles()
        where file.provider == .kimi && !file.isExpired {
            let account = MonitorAccount.makeLegacy(file)
            guard !disabled.contains(account.id),
                  let token = await directAuthService.readAuthToken(from: file),
                  let quota = await fetch(
                      accessToken: token.accessToken,
                      headers: KimiCredentialReader.identityHeaders(
                          accessToken: token.accessToken,
                          deviceID: token.extras?["device_id"]
                      )
                  ) else { continue }
            results[account.accountKey] = quota
        }

        for account in await vault.accounts()
        where account.provider == .kimi && !disabled.contains(account.id) {
            guard let credential = await vault.credential(for: account.id),
                  let quota = await fetch(accessToken: credential.accessToken) else { continue }
            results[account.accountKey] = quota
        }
        return results
    }

    /// Fetch one account. Only a foreground refresh initiated by the user may
    /// request Keychain ACL access; scheduled and provider-wide refreshes remain
    /// prompt-free through `fetchAllQuotas()`.
    func fetchQuota(
        accountKey: String,
        allowUserInteraction: Bool = false
    ) async -> ProviderQuotaData? {
        let disabled = await metadata.disabledAccountIDs()
        if let local = KimiCredentialReader.loadAll().first(where: { $0.accountKey == accountKey }),
           !disabled.contains(local.account.id) {
            return await fetch(accessToken: local.accessToken, headers: local.headers)
        }
        if let file = await directAuthService.scanAllAuthFiles().first(where: {
            $0.provider == .kimi && MonitorAccount.makeLegacy($0).accountKey == accountKey && !$0.isExpired
        }) {
            let account = MonitorAccount.makeLegacy(file)
            if !disabled.contains(account.id), let token = await directAuthService.readAuthToken(from: file) {
                return await fetch(
                    accessToken: token.accessToken,
                    headers: KimiCredentialReader.identityHeaders(
                        accessToken: token.accessToken,
                        deviceID: token.extras?["device_id"]
                    )
                )
            }
        }
        guard let account = await vault.accounts().first(where: {
            $0.provider == .kimi && $0.accountKey == accountKey && !disabled.contains($0.id)
        }) else { return nil }
        guard let credential = await credential(
            for: account,
            allowUserInteraction: allowUserInteraction
        ) else { return nil }
        return await fetch(accessToken: credential.accessToken)
    }

    /// Kept internal so the prompt boundary can be tested without making a real
    /// request or exposing a fixture credential outside the test process.
    func credential(
        for account: MonitorAccount,
        allowUserInteraction: Bool
    ) async -> MonitorOAuthCredential? {
        if let credential = await vault.credential(for: account.id) {
            return credential
        }
        guard allowUserInteraction else { return nil }
        return await vault.credentialForUserInitiatedAccess(for: account.id)
    }

    private func fetch(accessToken: String, headers: [String: String] = [:]) async -> ProviderQuotaData? {
        var sawAuthenticationFailure = false
        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Quotio-KimiMonitor/1.0", forHTTPHeaderField: "User-Agent")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 {
                sawAuthenticationFailure = true
                continue
            }
            guard 200...299 ~= http.statusCode else { continue }
            if let quota = KimiQuotaMapper.map(data) { return quota }
        }
        return sawAuthenticationFailure ? ProviderQuotaData(isForbidden: true) : nil
    }
}

// MARK: - MiniMax Token Plan

nonisolated enum MiniMaxQuotaMapper {
    static func map(_ data: Data, now: Date = Date()) -> ProviderQuotaData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let base = CodingPlanJSON.object(json["base_resp"]),
           let status = CodingPlanJSON.number(base["status_code"]), status != 0 {
            return nil
        }
        let root = CodingPlanJSON.object(json["data"]) ?? json
        guard let entries = root["model_remains"] as? [Any] else { return nil }
        let objects = entries.compactMap { $0 as? [String: Any] }
        guard let entry = objects.first(where: {
            CodingPlanJSON.string($0, keys: ["model_name"])?.lowercased() == "general"
        }) ?? objects.first(where: {
            CodingPlanJSON.string($0, keys: ["model_name"])?.lowercased() != "video"
        }) ?? objects.first else { return nil }

        var models: [ModelQuota] = []
        if let interval = model(
            name: "minimax-five-hour",
            entry: entry,
            totalKey: "current_interval_total_count",
            usedKey: "current_interval_usage_count",
            percentKey: "current_interval_remaining_percent",
            endKey: "end_time",
            remainsKey: "remains_time",
            now: now
        ) {
            models.append(interval)
        }
        if let weekly = model(
            name: "minimax-weekly",
            entry: entry,
            totalKey: "current_weekly_total_count",
            usedKey: "current_weekly_usage_count",
            percentKey: "current_weekly_remaining_percent",
            endKey: "weekly_end_time",
            remainsKey: "weekly_remains_time",
            now: now
        ) {
            models.append(weekly)
        }
        guard !models.isEmpty else { return nil }
        let plan = CodingPlanJSON.string(
            root,
            keys: ["current_subscribe_title", "plan_name", "plan", "subscription_plan"]
        ) ?? "Token Plan"
        return ProviderQuotaData(models: models, lastUpdated: now, planType: plan)
    }

    private static func model(
        name: String,
        entry: [String: Any],
        totalKey: String,
        usedKey: String,
        percentKey: String,
        endKey: String,
        remainsKey: String,
        now: Date
    ) -> ModelQuota? {
        let limit = CodingPlanJSON.number(entry[totalKey])
        let used = CodingPlanJSON.number(entry[usedKey])
        let explicitRemainingPercent = CodingPlanJSON.number(entry[percentKey])
        let remainingPercent: Double?
        if let limit, limit > 0, let used {
            remainingPercent = (limit - used) / limit * 100
        } else {
            remainingPercent = explicitRemainingPercent
        }
        guard let remainingPercent else { return nil }

        let resetTime: String
        if let end = CodingPlanJSON.number(entry[endKey]), end > 0 {
            resetTime = CodingPlanJSON.iso8601(epoch: end)
        } else if let remains = CodingPlanJSON.number(entry[remainsKey]), remains > 0 {
            resetTime = ISO8601DateFormatter().string(from: now.addingTimeInterval(remains / 1000))
        } else {
            resetTime = ""
        }
        return ModelQuota(
            name: name,
            percentage: max(0, min(100, remainingPercent)),
            resetTime: resetTime,
            used: used.map { Int($0.rounded()) },
            limit: limit.map { Int($0.rounded()) },
            remaining: limit.flatMap { total in used.map { Int(max(0, total - $0).rounded()) } }
        )
    }
}

actor MiniMaxQuotaFetcher {
    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private var session: URLSession
    private let endpoints = [
        URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!,
        URL(string: "https://api.minimax.io/v1/token_plan/remains")!,
    ]

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared
    ) {
        self.vault = vault
        self.metadata = metadata
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        let disabled = await metadata.disabledAccountIDs()
        for account in await vault.accounts()
        where account.provider == .minimax && !disabled.contains(account.id) {
            guard let credential = await vault.credential(for: account.id),
                  let quota = await fetch(apiKey: credential.accessToken) else { continue }
            results[account.accountKey] = quota
        }
        return results
    }

    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        let disabled = await metadata.disabledAccountIDs()
        guard let account = await vault.accounts().first(where: {
            $0.provider == .minimax && $0.accountKey == accountKey && !disabled.contains($0.id)
        }), let credential = await vault.credential(for: account.id) else { return nil }
        return await fetch(apiKey: credential.accessToken)
    }

    private func fetch(apiKey: String) async -> ProviderQuotaData? {
        var sawAuthenticationFailure = false
        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Quotio-MiniMaxMonitor/1.0", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 {
                sawAuthenticationFailure = true
                continue
            }
            guard 200...299 ~= http.statusCode else { continue }
            if let base = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap({ CodingPlanJSON.object($0["base_resp"]) }),
               let code = CodingPlanJSON.number(base["status_code"]),
               [1004, 2049].contains(Int(code)) {
                sawAuthenticationFailure = true
                continue
            }
            if let quota = MiniMaxQuotaMapper.map(data) { return quota }
        }
        return sawAuthenticationFailure ? ProviderQuotaData(isForbidden: true) : nil
    }
}
