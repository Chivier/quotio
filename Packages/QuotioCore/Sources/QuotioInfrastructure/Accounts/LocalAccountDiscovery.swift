import Foundation
import QuotioApplication
import QuotioDomain

public actor LocalAccountDiscovery: AccountDiscovering {
    private let vault: any CredentialVault
    private let authFiles: any AuthFileRepository
    private let metadata: any AccountMetadataRepository
    private let externalCredentials: any ExternalCredentialReading
    private let environment: [String: String]
    private let homeDirectory: URL
    private let factoryCredentials: any FactoryDroidCredentialLoading
    private let kiroCredentials: any KiroQuotaCredentialSourcing
    private let quotaFiles: any QuotaCredentialFileReading
    private let devinDatabase: any DevinCredentialDatabaseReading
    private let claudeDesktop: ClaudeDesktopCredentialReader
    private let antigravityDatabase: AntigravitySwitchDatabase
    private var provenAliases: [String: Set<String>] = [:]
    private var discoveryTail: Task<[Account], Never>?

    public init(
        vault: any CredentialVault,
        authFileRepository: any AuthFileRepository,
        metadataRepository: any AccountMetadataRepository,
        externalCredentials: any ExternalCredentialReading
    ) {
        self.vault = vault
        self.authFiles = authFileRepository
        self.metadata = metadataRepository
        self.externalCredentials = externalCredentials
        environment = ProcessInfo.processInfo.environment
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        factoryCredentials = LocalFactoryDroidCredentialStore(
            externalCredentials: externalCredentials
        )
        kiroCredentials = LocalKiroQuotaCredentialSource()
        quotaFiles = LocalQuotaCredentialFileReader()
        devinDatabase = LocalDevinCredentialDatabaseReader()
        claudeDesktop = ClaudeDesktopCredentialReader(externalCredentials: externalCredentials)
        antigravityDatabase = AntigravitySwitchDatabase()
    }

    init(
        vault: any CredentialVault,
        authFileRepository: any AuthFileRepository,
        metadataRepository: any AccountMetadataRepository,
        externalCredentials: any ExternalCredentialReading,
        environment: [String: String],
        homeDirectory: URL,
        factoryCredentials: any FactoryDroidCredentialLoading,
        kiroCredentials: any KiroQuotaCredentialSourcing,
        quotaFiles: any QuotaCredentialFileReading,
        devinDatabase: any DevinCredentialDatabaseReading,
        claudeDesktop: ClaudeDesktopCredentialReader,
        antigravityDatabase: AntigravitySwitchDatabase
    ) {
        self.vault = vault
        self.authFiles = authFileRepository
        self.metadata = metadataRepository
        self.externalCredentials = externalCredentials
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.factoryCredentials = factoryCredentials
        self.kiroCredentials = kiroCredentials
        self.quotaFiles = quotaFiles
        self.devinDatabase = devinDatabase
        self.claudeDesktop = claudeDesktop
        self.antigravityDatabase = antigravityDatabase
    }

    public func discoverAccounts() async -> [Account] {
        // Discoveries run one at a time: each collects the aliases it proves in
        // `provenAliases`, and an interleaved run would reconcile a partial set.
        let previous = discoveryTail
        let task = Task {
            _ = await previous?.value
            return await self.performDiscovery()
        }
        discoveryTail = task
        return await task.value
    }

    private func performDiscovery() async -> [Account] {
        let legacyFiles = await authFiles.scanAllAuthFiles()
        let aliases = Self.codexAliases(from: legacyFiles)
        provenAliases = [:]
        var candidates = await canonicalizeCodexAccounts(await vault.accounts(), aliases: aliases)
        candidates.append(contentsOf: await discoverNativeFiles(codexAliases: aliases))
        candidates.append(contentsOf: await discoverNativeKeychains(codexAliases: aliases))
        candidates.append(contentsOf: legacyFiles.map(Self.legacyAccount))
        for file in legacyFiles where file.providerID.rawValue == QuotaProvider.kiro.rawValue {
            prove(Self.legacyAccount(file), aliases: Set(file.legacyIdentityKeys))
        }
        // Proven aliases let disabled and removed markers recorded under an older key
        // keep following the account after its key is canonicalized. A failed write
        // only delays that migration to the next discovery.
        try? await metadata.reconcileAliases(provenAliases)
        let preferred = AccountSelectionPolicy.preferred(
            candidates,
            disabledIDs: await metadata.disabledAccountIDs()
        )
        return await metadata.filteringAccounts(preferred)
    }

    /// Records that `aliases` (account keys older builds used) name `account`.
    private func prove(_ account: Account, aliases: Set<String>) {
        let ids = Set(aliases.map {
            AccountIdentity.make(providerID: account.providerID, accountKey: $0).id
        }).subtracting([account.id])
        guard !ids.isEmpty else { return }
        provenAliases[account.id, default: []].formUnion(ids)
    }

    static func legacyAccount(_ file: AuthFileDescriptor) -> Account {
        let accountKey: String
        switch file.providerID.rawValue {
        case QuotaProvider.codex.rawValue, QuotaProvider.copilot.rawValue, "copilot",
             QuotaProvider.kiro.rawValue:
            accountKey = file.menuBarAccountKey
        default:
            accountKey = nonBlank(file.email)
                ?? file.filename.replacingOccurrences(of: ".json", with: "")
        }
        return Account.make(
            providerID: file.providerID,
            accountKey: accountKey,
            displayName: nonBlank(file.email) ?? nonBlank(file.login) ?? file.filename,
            source: .legacyCLIProxy,
            credentialReference: file.filePath
        )
    }

    /// Keys a Codex account by `CodexAccountKey`, keeping its ID so Quotio-owned
    /// credentials stay addressable.
    static func canonicalizeCodexAccount(
        _ account: Account,
        accountID: String?,
        aliases: [String: String]
    ) -> Account {
        guard account.providerID.rawValue == QuotaProvider.codex.rawValue,
              let accountID = nonBlank(accountID) else {
            return account
        }
        let canonicalKey = CodexAccountKey.canonical(
            email: account.displayName,
            accountID: accountID,
            aliases: aliases,
            fallback: account.accountKey
        )
        return rekeyed(account, accountKey: canonicalKey, displayName: account.displayName)
    }

    private static func rekeyed(_ account: Account, accountKey: String, displayName: String) -> Account {
        Account(
            identity: AccountIdentity(
                id: account.id,
                providerID: account.providerID,
                accountKey: accountKey
            ),
            displayName: displayName,
            source: account.source,
            credentialReference: account.credentialReference,
            capabilities: account.capabilities,
            status: account.status,
            credentialMetadata: account.credentialMetadata
        )
    }

    private static func codexAliases(from files: [AuthFileDescriptor]) -> [String: String] {
        var keysByAccountID: [String: Set<String>] = [:]
        for file in files where file.providerID.rawValue == QuotaProvider.codex.rawValue {
            guard let json = json(at: file.filePath) else { continue }
            let accountID = nonBlank(json["account_id"] as? String)
                ?? jwtNestedString(
                    json["id_token"] as? String,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            guard let accountID else { continue }
            keysByAccountID[accountID, default: []].insert(file.menuBarAccountKey)
        }
        return keysByAccountID.reduce(into: [:]) { aliases, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            aliases[entry.key] = key
        }
    }

    private func canonicalizeCodexAccounts(
        _ accounts: [Account],
        aliases: [String: String]
    ) async -> [Account] {
        var result: [Account] = []
        for account in accounts {
            if account.providerID.rawValue == QuotaProvider.kiro.rawValue,
               let profile = Self.nonBlank(await vault.credential(for: account.id)?.extra["profileArn"]) {
                // A Quotio login of a profile that is also present on disk is one account.
                let profileID = AccountIdentity.make(providerID: account.providerID, accountKey: profile).id
                if profileID != account.id { provenAliases[profileID, default: []].insert(account.id) }
            }
            guard account.providerID.rawValue == QuotaProvider.codex.rawValue,
                  let credential = await vault.credential(for: account.id) else {
                result.append(account)
                continue
            }
            // The same key the quota fetcher derives, so the row and its quota meet.
            let owned = CompositeCodexQuotaCredentialLoader.ownedCredential(
                credential,
                account: account,
                legacyAliases: aliases
            )
            result.append(Self.rekeyed(
                account,
                accountKey: owned.accountKey,
                displayName: owned.displayName ?? account.displayName
            ))
        }
        return result
    }

    private func discoverNativeFiles(codexAliases: [String: String]) async -> [Account] {
        var accounts = discoverCodexFiles(aliases: codexAliases)
        accounts.append(contentsOf: discoverClaudeFile())
        if claudeDesktop.hasCredentialMaterial() {
            accounts.append(Self.account(
                provider: .claude,
                accountKey: "Claude Desktop",
                source: .localIDE,
                credentialReference: "claude-desktop"
            ))
        }
        accounts.append(contentsOf: discoverCopilotFiles())
        accounts.append(contentsOf: await discoverKiroFile())
        accounts.append(contentsOf: await discoverFactoryDroidCredential())
        accounts.append(contentsOf: await discoverAmpCredential())
        accounts.append(contentsOf: await discoverDevinCredential())
        accounts.append(contentsOf: await discoverGrokCredentials())
        accounts.append(contentsOf: await KimiLocalCredentialReader(homeDirectory: homeDirectory, files: quotaFiles).accounts())
        if await antigravityDatabase.hasCredential() {
            accounts.append(Self.account(
                provider: .antigravity,
                accountKey: "Antigravity",
                source: .localIDE,
                credentialReference: homeDirectory
                    .appendingPathComponent(
                        "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
                    ).path
            ))
        }
        return accounts
    }

    private func discoverFactoryDroidCredential() async -> [Account] {
        guard let credential = await factoryCredentials.load() else { return [] }
        return [Self.account(
            provider: .factoryDroid,
            accountKey: credential.accountKey,
            source: .nativeCredential,
            credentialReference: credential.sourcePath
        )]
    }

    private func discoverAmpCredential() async -> [Account] {
        let path = homeDirectory.appendingPathComponent(".local/share/amp/secrets.json").path
        guard let data = await quotaFiles.read(path: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"].contains(where: {
                  Self.nonBlank(json[$0] as? String) != nil
              }) else {
            return []
        }
        return [Self.account(
            provider: .amp,
            accountKey: AmpQuotaFetcher.localAccountKey,
            source: .nativeCredential,
            credentialReference: path
        )]
    }

    private func discoverDevinCredential() async -> [Account] {
        let credentialsPath = homeDirectory
            .appendingPathComponent(".local/share/devin/credentials.toml").path
        if let data = await quotaFiles.read(path: credentialsPath),
           let text = String(data: data, encoding: .utf8),
           DevinQuotaFetcher.parseCredentialsTOML(text) != nil {
            return [Self.account(
                provider: .devin,
                accountKey: DevinQuotaFetcher.accountKey,
                source: .nativeCredential,
                credentialReference: credentialsPath
            )]
        }
        let databasePath = homeDirectory.appendingPathComponent(
            "Library/Application Support/Devin/User/globalStorage/state.vscdb"
        ).path
        guard devinDatabase.credential(path: databasePath) != nil else { return [] }
        return [Self.account(
            provider: .devin,
            accountKey: DevinQuotaFetcher.accountKey,
            source: .localIDE,
            credentialReference: databasePath
        )]
    }

    private func discoverGrokCredentials() async -> [Account] {
        let path = GrokQuotaFetcher.authPath(environment: environment, homeDirectory: homeDirectory)
        guard let data = await quotaFiles.read(path: path) else { return [] }
        return GrokQuotaFetcher.loadCandidates(data: data).map { candidate in
            Self.account(
                provider: .grok,
                accountKey: candidate.entryKey,
                displayName: candidate.displayName,
                source: .nativeCredential,
                credentialReference: path + "#" + candidate.entryKey
            )
        }
    }

    private func discoverCodexFiles(aliases: [String: String]) -> [Account] {
        LocalCodexQuotaCredentialLoader.nativeAuthPaths(
            environment: environment,
            homeDirectory: homeDirectory
        ).compactMap { path in
            guard let credential = LocalCodexQuotaCredentialLoader.loadNative(path: path) else {
                return nil
            }
            return codexAccount(credential, aliases: aliases, credentialReference: path)
        }
    }

    /// One row per ChatGPT workspace, named by its email, with the key older builds
    /// used kept as a proven alias.
    private func codexAccount(
        _ native: CodexQuotaCredential,
        aliases: [String: String],
        credentialReference: String
    ) -> Account {
        let credential = LocalCodexQuotaCredentialLoader.applyingLegacyAlias(native, aliases: aliases)
        let account = Self.account(
            provider: .codex,
            accountKey: credential.accountKey,
            displayName: credential.displayName,
            source: .nativeCredential,
            credentialReference: credentialReference
        )
        prove(account, aliases: credential.aliases)
        return account
    }

    private func discoverClaudeFile() -> [Account] {
        let base = Self.nonBlank(environment["CLAUDE_CONFIG_DIR"])
            .map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".claude")
        let path = base.appendingPathComponent(".credentials.json").path
        guard let credential = LocalClaudeQuotaCredentialLoader.load(path: path) else { return [] }
        return [Self.account(
            provider: .claude,
            accountKey: credential.accountKey,
            source: .nativeCredential,
            credentialReference: path
        )]
    }

    private func discoverCopilotFiles() -> [Account] {
        [
            ".config/github-copilot/apps.json",
            ".config/github-copilot/hosts.json",
            ".config/gh/hosts.yml",
        ].compactMap { relativePath in
            let path = homeDirectory.appendingPathComponent(relativePath).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Self.account(
                provider: .copilot,
                accountKey: CopilotQuotaFetcher.nativeAccountKey,
                source: .nativeCredential,
                credentialReference: path
            )
        }
    }

    private func discoverKiroFile() async -> [Account] {
        var accounts: [Account] = []
        for credential in await kiroCredentials.credentials() {
            guard let path = credential.filePath,
                  path.contains("/.aws/sso/cache/") else { continue }
            let account = Self.account(
                provider: .kiro,
                accountKey: credential.accountKey,
                source: .nativeCredential,
                credentialReference: path
            )
            prove(account, aliases: credential.aliases)
            accounts.append(account)
        }
        return accounts
    }

    private func discoverNativeKeychains(codexAliases: [String: String]) async -> [Account] {
        var accounts: [Account] = []
        if let record = await externalCredentials.read(
            service: CompositeCodexQuotaCredentialLoader.keychainService,
            account: nil
        ), let credential = LocalCodexQuotaCredentialLoader.loadNative(
            data: record.data,
            fallbackAccountKey: "Codex"
        ) {
            accounts.append(codexAccount(
                credential,
                aliases: codexAliases,
                credentialReference: "keychain:Codex Auth"
            ))
        }
        if let record = await externalCredentials.read(
            service: "Claude Code-credentials",
            account: nil
        ), let credential = LocalClaudeQuotaCredentialLoader.load(data: record.data) {
            accounts.append(Self.account(
                provider: .claude,
                accountKey: credential.accountKey,
                source: .nativeCredential,
                credentialReference: "keychain:Claude Code-credentials"
            ))
        }
        return accounts
    }

    private static func account(
        provider: QuotaProvider,
        accountKey: String,
        displayName: String? = nil,
        source: AccountSource,
        credentialReference: String?
    ) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: accountKey,
            displayName: displayName,
            source: source,
            credentialReference: credentialReference
        )
    }

    private static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jwtNestedString(
        _ token: String?,
        namespace: String,
        claim: String
    ) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
