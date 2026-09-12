import CryptoKit
import Foundation

nonisolated enum MonitorAccountSource: String, Codable, Sendable, CaseIterable {
    case quotioKeychain
    case nativeCredential
    case legacyCLIProxy
    case localIDE
    case apiKey

    var priority: Int {
        switch self {
        case .quotioKeychain: 300
        case .nativeCredential, .localIDE, .apiKey: 200
        case .legacyCLIProxy: 100
        }
    }

    var displayName: String {
        localizationKey.localizedStatic()
    }

    var localizationKey: String {
        switch self {
        case .quotioKeychain: "monitor.source.quotio"
        case .nativeCredential: "monitor.source.localLogin"
        case .legacyCLIProxy: "monitor.source.cliProxyFile"
        case .localIDE: "monitor.source.localIDE"
        case .apiKey: "monitor.source.apiKey"
        }
    }
}

nonisolated struct MonitorAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let accountKey: String
    let displayName: String
    let source: MonitorAccountSource
    let credentialReference: String?
    let canDelete: Bool
    var isDisabled: Bool

    var deduplicationKey: String {
        let identity = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(provider.rawValue):\(identity)"
    }

    static func make(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        credentialReference: String? = nil,
        canDelete: Bool = false,
        isDisabled: Bool = false
    ) -> MonitorAccount {
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let idSeed = "\(provider.rawValue)|\(normalized.lowercased())"
        return MonitorAccount(
            id: "monitor-" + MonitorIdentity.fingerprint(idSeed),
            provider: provider,
            accountKey: normalized,
            displayName: displayName?.nilIfBlank ?? normalized,
            source: source,
            credentialReference: credentialReference,
            canDelete: canDelete,
            isDisabled: isDisabled
        )
    }

    static func makeLegacy(_ file: DirectAuthFile) -> MonitorAccount {
        let accountKey: String
        if file.provider == .codex || file.provider == .copilot || file.provider == .kiro {
            accountKey = file.menuBarAccountKey
        } else if let email = file.email, !email.isEmpty {
            accountKey = email
        } else {
            accountKey = file.filename.replacingOccurrences(of: ".json", with: "")
        }
        let displayName = file.email?.nilIfBlank ?? file.login?.nilIfBlank ?? file.filename
        return make(
            provider: file.provider,
            accountKey: accountKey,
            displayName: displayName,
            source: .legacyCLIProxy,
            credentialReference: file.filePath
        )
    }
}

nonisolated struct MonitorRefreshIssue: Codable, Hashable, Sendable {
    let message: String
    let occurredAt: Date
    /// When present, only these account keys failed during a partial provider refresh.
    /// A provider-wide failure leaves this nil so every account can surface the issue.
    let affectedAccountKeys: Set<String>?

    init(message: String, occurredAt: Date, affectedAccountKeys: Set<String>? = nil) {
        self.message = message
        self.occurredAt = occurredAt
        self.affectedAccountKeys = affectedAccountKeys
    }

    func affects(accountKey: String) -> Bool {
        guard let affectedAccountKeys else { return true }
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return affectedAccountKeys.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }
}

nonisolated struct MonitorRefreshBatch: Sendable {
    var accounts: [MonitorAccount]
    var quotas: [AIProvider: [String: ProviderQuotaData]]
    var issues: [AIProvider: MonitorRefreshIssue]
}

nonisolated protocol MonitorProviderRuntime: Sendable {
    var provider: AIProvider { get }
    func discoverAccounts() async -> [MonitorAccount]
    func refresh(force: Bool) async -> [String: ProviderQuotaData]
}

/// Whether a Quotio-owned credential is usable, gone, or present-but-unreadable.
///
/// The last case matters on its own: the prompt-free Keychain read fails closed
/// when the item's ACL is bound to another code identity, and mapping that to
/// "no credential" makes the account vanish from every quota surface with no
/// error anywhere.
nonisolated enum MonitorStoredCredentialState: Equatable, Sendable {
    case available
    case absent
    case unreadable
}

nonisolated protocol MonitorCredentialStore: Sendable {
    func accounts() async -> [MonitorAccount]
    func credential(for accountID: String) async -> MonitorOAuthCredential?
    /// Read an existing credential in direct response to a foreground user action.
    /// Production Keychain storage may use this path to present an ACL prompt;
    /// background refreshes must continue to call `credential(for:)` instead.
    func credentialForUserInitiatedAccess(for accountID: String) async -> MonitorOAuthCredential?
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential?
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws
    func delete(accountID: String) async throws
    func credentialState(for accountID: String) async -> MonitorStoredCredentialState
}

extension MonitorCredentialStore {
    func credentialForUserInitiatedAccess(for accountID: String) async -> MonitorOAuthCredential? {
        await credential(for: accountID)
    }

    func credentialState(for accountID: String) async -> MonitorStoredCredentialState {
        await credential(for: accountID) == nil ? .absent : .available
    }
}

nonisolated struct MonitorOAuthCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var expiresAt: Date?
    var extra: [String: String]
}

/// Codex exposes both a user-facing email and a ChatGPT account ID. One email can
/// belong to multiple ChatGPT workspaces, so using the email alone as the quota or
/// Keychain key silently collapses distinct accounts.
nonisolated enum CodexAccountKey {
    static func canonical(
        email: String?,
        accountID: String?,
        aliases: [String: String] = [:],
        fallback: String
    ) -> String {
        let normalizedAccountID = accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        if let normalizedAccountID, let alias = aliases[normalizedAccountID]?.nilIfBlank {
            return alias
        }

        let base = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            ?? fallback
        guard let normalizedAccountID else { return base }
        return base + " • " + String(MonitorIdentity.fingerprint(normalizedAccountID).prefix(8))
    }
}

/// One identity contract for native Kiro, legacy files, and their old snapshot keys.
nonisolated enum KiroAccountIdentity {
    static func canonicalKey(email: String?, profileARN: String?, filename: String) -> String {
        profileARN?.nilIfBlank ?? email?.nilIfBlank
            ?? filename.replacingOccurrences(of: ".json", with: "")
    }

    static func aliases(for file: DirectAuthFile) -> Set<String> {
        var keys = Set(file.legacyIdentityKeys)
        if let email = file.email?.nilIfBlank { keys.insert(email) }
        if let profile = file.kiroProfileARN?.nilIfBlank { keys.insert(profile) }
        keys.insert(file.menuBarAccountKey)
        if file.source == .nativeCredential, file.email?.nilIfBlank == nil,
           file.kiroProfileARN?.nilIfBlank == nil {
            keys.insert("Kiro")
        }
        return Set(keys.map { MonitorAccount.make(provider: .kiro, accountKey: $0, source: .nativeCredential).id })
    }
}

actor MonitorCredentialVault: MonitorCredentialStore {
    static let shared = MonitorCredentialVault()

    private let metadata: MonitorMetadataStore
    private var loadedGenerations: [String: String] = [:]
    private var removalGeneration: [String: Int] = [:]
    /// A foreground Keychain authorization may grant this process access without
    /// rewriting the item. Keep that decoded credential only in memory so later
    /// background refreshes in the same run remain prompt-free.
    private var sessionCredentials: [String: MonitorOAuthCredential] = [:]

    init(metadata: MonitorMetadataStore = .shared) {
        self.metadata = metadata
    }

    func accounts() async -> [MonitorAccount] {
        await metadata.accounts()
    }

    func credential(for accountID: String) -> MonitorOAuthCredential? {
        if case let .success(data) = KeychainHelper.readMonitorCredential(account: accountID),
           let credential = try? JSONDecoder().decode(MonitorOAuthCredential.self, from: data) {
            loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
            return credential
        }
        return sessionCredentials[accountID]
    }

    /// This is intentionally separate from `credential(for:)`: only a direct
    /// foreground account refresh may call it because macOS can show an access
    /// authorization prompt.
    func credentialForUserInitiatedAccess(for accountID: String) -> MonitorOAuthCredential? {
        guard case let .success(data) = KeychainHelper.readMonitorCredentialUserInitiated(account: accountID),
              let credential = try? JSONDecoder().decode(MonitorOAuthCredential.self, from: data)
        else { return nil }
        loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
        sessionCredentials[accountID] = credential
        return credential
    }

    func credentialState(for accountID: String) -> MonitorStoredCredentialState {
        if sessionCredentials[accountID] != nil { return .available }
        switch KeychainHelper.readMonitorCredential(account: accountID) {
        case .success: return .available
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }

    func reloadLatest(accountID: String) -> MonitorOAuthCredential? {
        credential(for: accountID)
    }

    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        try await save(credential, metadata: account, userInitiated: false)
    }

    /// Persist a credential produced by a foreground action the user explicitly
    /// started. This is the only path allowed to surface a macOS Keychain trust
    /// prompt; automatic refresh and discovery remain prompt-free.
    func saveUserInitiated(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        try await save(credential, metadata: account, userInitiated: true)
    }

    private func save(
        _ credential: MonitorOAuthCredential,
        metadata account: MonitorAccount,
        userInitiated: Bool
    ) async throws {
        let generation = removalGeneration[account.id, default: 0]
        if !userInitiated, await self.metadata.isRemoved(account.id) {
            throw MonitorRuntimeError.invalidCredential
        }
        guard userInitiated || generation == removalGeneration[account.id, default: 0] else {
            throw MonitorRuntimeError.invalidCredential
        }
        let data = try JSONEncoder().encode(credential)
        let saved: Bool
        if userInitiated {
            // The just-completed login is authoritative for this deterministic
            // account ID. In particular, it may replace an item owned by an old
            // ad-hoc Debug signature that background code is unable to read.
            saved = KeychainHelper.saveMonitorCredentialUserInitiated(data, account: account.id)
        } else if let expected = loadedGenerations[account.id] {
            saved = KeychainHelper.compareAndSwapMonitorCredential(
                data,
                account: account.id,
                expectedFingerprint: expected
            )
        } else {
            saved = KeychainHelper.saveMonitorCredential(data, account: account.id)
        }
        guard saved else {
            if userInitiated,
               KeychainHelper.monitorCredentialBackend(vaultEnabled: YubiKeySecretVault.isEnabled) == .keychain {
                throw MonitorRuntimeError.keychainAuthorizationRequired
            }
            throw MonitorRuntimeError.credentialWriteFailed
        }
        loadedGenerations[account.id] = MonitorIdentity.fingerprint(data.base64EncodedString())
        sessionCredentials[account.id] = credential
        try await self.metadata.saveAccount(account, restoringRemoved: userInitiated)
    }

    func delete(accountID: String) async throws {
        removalGeneration[accountID, default: 0] += 1
        // Persist the marker before touching credentials; a disk failure must not
        // look like a successful permanent removal to the caller.
        try await metadata.deleteAccount(accountID)
        KeychainHelper.deleteMonitorCredential(account: accountID)
        loadedGenerations.removeValue(forKey: accountID)
        sessionCredentials.removeValue(forKey: accountID)
    }
}

actor MonitorMetadataStore {
    static let shared = MonitorMetadataStore()

    private struct Payload: Codable {
        var accounts: [MonitorAccount] = []
        var disabledAccountIDs: Set<String> = []
        // Optional so existing accounts-v1.json files decode without a migration.
        var removedAccountIDs: Set<String>?
        // Only equivalent identities observed in the same source are linked.
        var accountAliases: [String: String]?
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Monitor/accounts-v1.json")
    }

    func accounts() -> [MonitorAccount] { filteringAccounts(load().accounts) }
    func disabledAccountIDs() -> Set<String> { load().disabledAccountIDs }
    func removedAccountIDs() -> Set<String> { load().removedAccountIDs ?? [] }

    func saveAccount(_ account: MonitorAccount, restoringRemoved: Bool = false) throws {
        var payload = load()
        let identity = canonicalID(account.id, in: payload)
        if restoringRemoved {
            payload.removedAccountIDs = payload.removedAccountIDs?.filter {
                canonicalID($0, in: payload) != identity
            }
        } else if payload.removedAccountIDs?.contains(where: { canonicalID($0, in: payload) == identity }) == true {
            throw MonitorRuntimeError.invalidCredential
        }
        payload.accounts.removeAll { $0.id == account.id }
        payload.accounts.append(account)
        try save(payload)
    }

    func deleteAccount(_ accountID: String) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == accountID }
        payload.disabledAccountIDs.remove(accountID)
        payload.removedAccountIDs = (payload.removedAccountIDs ?? []).union([canonicalID(accountID, in: payload)])
        try save(payload)
    }

    func setDisabled(_ disabled: Bool, accountID: String) throws {
        var payload = load()
        let identity = canonicalID(accountID, in: payload)
        if disabled { payload.disabledAccountIDs.insert(identity) }
        else { payload.disabledAccountIDs = payload.disabledAccountIDs.filter { canonicalID($0, in: payload) != identity } }
        try save(payload)
    }

    func setRemoved(_ removed: Bool, accountID: String) throws {
        var payload = load()
        let identity = canonicalID(accountID, in: payload)
        var removedIDs = payload.removedAccountIDs ?? []
        if removed {
            removedIDs.insert(identity)
            payload.disabledAccountIDs = payload.disabledAccountIDs.filter { canonicalID($0, in: payload) != identity }
        } else {
            removedIDs = removedIDs.filter { canonicalID($0, in: payload) != identity }
        }
        payload.removedAccountIDs = removedIDs.isEmpty ? nil : removedIDs
        try save(payload)
    }

    @discardableResult
    func restoreRemovedAccounts() throws -> Int {
        var payload = load()
        let count = payload.removedAccountIDs?.count ?? 0
        guard count > 0 else { return 0 }
        payload.removedAccountIDs = nil
        try save(payload)
        return count
    }

    private func canonicalID(_ id: String, in payload: Payload) -> String {
        payload.accountAliases?[id] ?? id
    }

    func isRemoved(_ accountID: String) -> Bool {
        let payload = load()
        let identity = canonicalID(accountID, in: payload)
        return payload.removedAccountIDs?.contains { canonicalID($0, in: payload) == identity } == true
    }

    func isExcluded(_ accountID: String) -> Bool {
        excludedQuotaAccountIDs().contains(accountID)
    }

    func reconcileAliases(_ aliasesByIdentity: [String: Set<String>]) throws {
        var payload = load()
        // Freeze existing markers onto the previously proven identity before a
        // reused filename is associated with a different login.
        payload.removedAccountIDs = payload.removedAccountIDs.map { Set($0.map { canonicalID($0, in: payload) }) }
        payload.disabledAccountIDs = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        var targets: [String: Set<String>] = [:]
        for (identity, aliases) in aliasesByIdentity {
            for alias in aliases { targets[alias, default: []].insert(identity) }
        }
        var aliases = payload.accountAliases ?? [:]
        for (alias, identities) in targets {
            // An email or old generic label shared by different profiles proves
            // nothing; never let that label suppress all of those accounts.
            if identities.count == 1, let identity = identities.first, alias != identity {
                aliases[alias] = identity
            } else {
                aliases.removeValue(forKey: alias)
            }
        }
        guard aliases != (payload.accountAliases ?? [:]) else { return }
        payload.accountAliases = aliases.isEmpty ? nil : aliases
        payload.removedAccountIDs = payload.removedAccountIDs.map { Set($0.map { canonicalID($0, in: payload) }) }
        payload.disabledAccountIDs = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        try save(payload)
    }

    func filteringAccounts(_ accounts: [MonitorAccount]) -> [MonitorAccount] {
        let payload = load()
        let removed = Set((payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
        let disabled = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        var selected: [String: MonitorAccount] = [:]
        for var account in accounts {
            let identity = canonicalID(account.id, in: payload)
            guard !removed.contains(identity) else { continue }
            account.isDisabled = disabled.contains(identity)
            if let existing = selected[identity],
               existing.source.priority > account.source.priority
                || (existing.source.priority == account.source.priority && existing.id == identity) { continue }
            selected[identity] = account
        }
        return selected.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func filteringQuotas(_ quotas: [AIProvider: [String: ProviderQuotaData]]) -> [AIProvider: [String: ProviderQuotaData]] {
        let payload = load()
        let excluded = Set(payload.disabledAccountIDs.union(payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
        return quotas.reduce(into: [:]) { result, entry in
            var visible: [String: ProviderQuotaData] = [:]
            let currentIDs = Set(entry.value.keys.map {
                MonitorAccount.make(provider: entry.key, accountKey: $0, source: .nativeCredential).id
            })
            for (key, value) in entry.value {
                let id = MonitorAccount.make(provider: entry.key, accountKey: key, source: .nativeCredential).id
                guard !excluded.contains(canonicalID(id, in: payload)) else { continue }
                let identity = canonicalID(id, in: payload)
                if id != identity, currentIDs.contains(identity) { continue }
                if entry.key == .kiro {
                    guard let quota = KiroQuotaFetcher.sanitizedCachedQuota(value) else { continue }
                    visible[key] = quota
                } else {
                    visible[key] = value
                }
            }
            if !visible.isEmpty { result[entry.key] = visible }
        }
    }

    func persistSnapshot(_ quotas: [AIProvider: [String: ProviderQuotaData]], at url: URL) {
        // Filtering and writing share metadata's executor, so a delayed finish
        // cannot race a tombstone commit and write the removed account back.
        let visible = filteringQuotas(quotas)
        let encoded = visible.reduce(into: [String: [String: ProviderQuotaData]]()) {
            $0[$1.key.rawValue] = $1.value
        }
        do {
            try SecureAtomicFileWriter.write(try JSONEncoder().encode(["quotas": encoded]), to: url)
        } catch {
            Log.quota("Failed to persist Monitor snapshot: \(error.localizedDescription)")
        }
    }

    func excludedQuotaAccountIDs() -> Set<String> {
        let payload = load()
        let excluded = Set(payload.disabledAccountIDs.union(payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
        return excluded.union((payload.accountAliases ?? [:]).compactMap { excluded.contains($0.value) ? $0.key : nil })
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url) else { return Payload() }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return payload
        }

        // Drop persisted Gemini CLI accounts after direct provider support is removed.
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return Payload() }
        let removedIDs = Set(accounts.compactMap { account in
            account["provider"] as? String == "gemini-cli" ? account["id"] as? String : nil
        })
        guard !removedIDs.isEmpty else { return Payload() }

        object["accounts"] = accounts.filter { $0["provider"] as? String != "gemini-cli" }
        if let disabledIDs = object["disabledAccountIDs"] as? [String] {
            object["disabledAccountIDs"] = disabledIDs.filter { !removedIDs.contains($0) }
        }
        guard let migratedData = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(Payload.self, from: migratedData) else { return Payload() }
        try? save(payload)
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}

actor MonitorSnapshotStore {
    private struct Payload: Codable {
        var quotas: [String: [String: ProviderQuotaData]]
    }

    nonisolated let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base
                .appendingPathComponent("Quotio", isDirectory: true)
                .appendingPathComponent("Monitor", isDirectory: true)
                .appendingPathComponent("snapshots-v1.json")
        }
    }

    func load() -> [AIProvider: [String: ProviderQuotaData]] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return [:]
        }
        return payload.quotas.reduce(into: [:]) { result, item in
            if let provider = AIProvider(rawValue: item.key) {
                result[provider] = item.value
            }
        }
    }

    func store(_ quotas: [AIProvider: [String: ProviderQuotaData]]) {
        let encoded = quotas.reduce(into: [String: [String: ProviderQuotaData]]()) {
            $0[$1.key.rawValue] = $1.value
        }
        guard let data = try? JSONEncoder().encode(Payload(quotas: encoded)) else { return }
        do {
            try SecureAtomicFileWriter.write(data, to: url)
        } catch {
            Log.quota("Failed to persist Monitor snapshot: \(error.localizedDescription)")
        }
    }

    /// Drop a single account from the persisted snapshot, leaving every other entry as
    /// it is on disk.
    ///
    /// `store(_:)` replaces the whole file with the caller's in-memory quotas, which is
    /// only correct while Monitor mode is active. Deleting an imported IDE account is
    /// reachable from the other modes too, where the in-memory quotas belong to that
    /// mode, so the delete path needs this targeted removal instead (issue #213).
    ///
    /// - Returns: `true` when an entry was found and the file was rewritten.
    @discardableResult
    func removeAccount(provider: AIProvider, accountKey: String) -> Bool {
        var quotas = load()
        guard var accountQuotas = quotas[provider] else { return false }

        // Match the identity Monitor itself dedupes on (`MonitorAccount.deduplicationKey`):
        // the Monitor row carries a trimmed account key while the snapshot key is stored
        // verbatim, so an exact-only match could leave the entry behind.
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingKeys = accountQuotas.keys.filter {
            $0 == accountKey || $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
        guard !matchingKeys.isEmpty else { return false }

        for key in matchingKeys {
            accountQuotas.removeValue(forKey: key)
        }
        if accountQuotas.isEmpty {
            quotas.removeValue(forKey: provider)
        } else {
            quotas[provider] = accountQuotas
        }
        store(quotas)
        return true
    }
}

actor MonitorAccountDiscovery {
    private let vault: MonitorCredentialStore
    private let directAuthService: DirectAuthFileService
    let metadata: MonitorMetadataStore
    private let includesNativeSources: Bool

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        directAuthService: DirectAuthFileService = DirectAuthFileService(),
        metadata: MonitorMetadataStore = .shared,
        includesNativeSources: Bool = true
    ) {
        self.vault = vault
        self.directAuthService = directAuthService
        self.metadata = metadata
        self.includesNativeSources = includesNativeSources
    }

    func discover() async -> [MonitorAccount] {
        let legacyFiles = await directAuthService.scanAllAuthFiles()
        let codexAliases = Self.codexAliases(from: legacyFiles)
        var candidates = await canonicalizeCodexAccounts(await vault.accounts(), aliases: codexAliases)
        if includesNativeSources {
            candidates.append(contentsOf: await discoverNativeFiles(codexAliases: codexAliases))
            candidates.append(contentsOf: discoverNativeKeychains(codexAliases: codexAliases))
        }
        let legacy = legacyFiles.map(MonitorAccount.makeLegacy)
        candidates.append(contentsOf: legacy)

        var aliases: [String: Set<String>] = [:]
        var kiroFiles = legacyFiles.filter { $0.provider == .kiro }
        if includesNativeSources, let native = Self.kiroAuthFile(at: MonitorIdentity.expand("~/.aws/sso/cache/kiro-auth-token.json")) {
            kiroFiles.append(native)
        }
        for file in kiroFiles {
            let id = MonitorAccount.makeLegacy(file).id
            aliases[id, default: []].formUnion(KiroAccountIdentity.aliases(for: file))
        }
        for account in candidates where account.provider == .kiro && account.source == .quotioKeychain {
            guard let credential = await vault.credential(for: account.id),
                  let profile = credential.extra["profileArn"]?.nilIfBlank else { continue }
            let id = MonitorAccount.make(provider: .kiro, accountKey: profile, source: .nativeCredential).id
            aliases[id, default: []].formUnion([id, account.id])
        }
        do { try await metadata.reconcileAliases(aliases) }
        catch { Log.quota("Failed to persist Monitor account identities: \(error.localizedDescription)") }
        return await metadata.filteringAccounts(Self.selectPreferred(candidates))
    }

    nonisolated static func selectPreferred(
        _ candidates: [MonitorAccount],
        disabledIDs: Set<String> = []
    ) -> [MonitorAccount] {
        var selected: [String: MonitorAccount] = [:]
        for var account in candidates {
            account.isDisabled = disabledIDs.contains(account.id)
            let key = account.deduplicationKey
            if let existing = selected[key], existing.source.priority >= account.source.priority {
                continue
            }
            selected[key] = account
        }
        return selected.values.sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    nonisolated static func canonicalizeCodexAccount(
        _ account: MonitorAccount,
        accountID: String?,
        aliases: [String: String]
    ) -> MonitorAccount {
        guard account.provider == .codex,
              let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else { return account }
        let canonicalKey = CodexAccountKey.canonical(
            email: account.displayName,
            accountID: accountID,
            aliases: aliases,
            fallback: account.accountKey
        )
        return MonitorAccount(
            id: account.id,
            provider: account.provider,
            accountKey: canonicalKey,
            displayName: account.displayName,
            source: account.source,
            credentialReference: account.credentialReference,
            canDelete: account.canDelete,
            isDisabled: account.isDisabled
        )
    }

    private nonisolated static func codexAliases(from files: [DirectAuthFile]) -> [String: String] {
        var keysByAccountID: [String: Set<String>] = [:]
        for file in files where file.provider == .codex {
            guard let json = MonitorIdentity.json(at: file.filePath) else { continue }
            let accountID = (json["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(
                    json["id_token"] as? String,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty else { continue }
            keysByAccountID[accountID, default: []].insert(file.filename.codexFilenameKey)
        }
        return keysByAccountID.reduce(into: [:]) { aliases, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            aliases[entry.key] = key
        }
    }

    private func canonicalizeCodexAccounts(
        _ accounts: [MonitorAccount],
        aliases: [String: String]
    ) async -> [MonitorAccount] {
        var result: [MonitorAccount] = []
        for account in accounts {
            guard account.provider == .codex,
                  let credential = await vault.credential(for: account.id) else {
                result.append(account)
                continue
            }
            let accountID = credential.accountID
                ?? MonitorIdentity.jwtNestedString(
                    credential.idToken,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            result.append(Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: aliases))
        }
        return result
    }

    func setDisabled(_ disabled: Bool, accountID: String) async {
        try? await metadata.setDisabled(disabled, accountID: accountID)
    }

    func disabledAccountIDs() async -> Set<String> {
        await metadata.disabledAccountIDs()
    }

    func removedAccountIDs() async -> Set<String> {
        await metadata.removedAccountIDs()
    }

    func setRemoved(_ removed: Bool, accountID: String) async throws {
        try await metadata.setRemoved(removed, accountID: accountID)
    }

    func deleteOwnedAccount(accountID: String) async throws {
        try await vault.delete(accountID: accountID)
    }

    func restoreRemovedAccounts() async -> Int {
        (try? await metadata.restoreRemovedAccounts()) ?? 0
    }

    func filteringRemovedAccounts(
        from quotas: [AIProvider: [String: ProviderQuotaData]]
    ) async -> [AIProvider: [String: ProviderQuotaData]] {
        await metadata.filteringQuotas(quotas)
    }

    private func discoverNativeFiles(codexAliases: [String: String]) async -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        accounts.append(contentsOf: discoverCodexFiles(aliases: codexAliases))
        accounts.append(contentsOf: discoverClaudeFile())
        if ClaudeDesktopCredentialReader.hasCredentialMaterial() {
            accounts.append(.make(
                provider: .claude,
                accountKey: "Claude Desktop",
                source: .localIDE,
                credentialReference: "claude-desktop"
            ))
        }
        accounts.append(contentsOf: discoverCopilotFiles())
        accounts.append(contentsOf: discoverKiroFile())
        accounts.append(contentsOf: discoverFactoryDroidCredential())
        accounts.append(contentsOf: discoverAmpCredential())
        accounts.append(contentsOf: discoverDevinCredential())
        accounts.append(contentsOf: discoverGrokCredentials())
        accounts.append(contentsOf: KimiCredentialReader.loadAll().map(\.account))
        let antigravityDatabase = MonitorIdentity.expand("~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        if let token = try? await AntigravityDatabaseService().getCurrentTokenInfo(),
           token.accessToken?.nilIfBlank != nil || token.refreshToken?.nilIfBlank != nil {
            accounts.append(.make(
                provider: .antigravity,
                accountKey: "Antigravity",
                source: .localIDE,
                credentialReference: antigravityDatabase
            ))
        }
        return accounts
    }

    private func discoverFactoryDroidCredential() -> [MonitorAccount] {
        guard let credential = FactoryDroidCredentialReader.load() else { return [] }
        return [FactoryDroidQuotaFetcher.localAccount(for: credential)]
    }

    private func discoverAmpCredential() -> [MonitorAccount] {
        guard let credential = AmpNativeCredentialReader.load() else { return [] }
        return [AmpQuotaFetcher.localAccount(provider: .amp, sourcePath: credential.sourcePath)]
    }

    private func discoverDevinCredential() -> [MonitorAccount] {
        let credentialsPath = MonitorIdentity.expand(DevinQuotaFetcher.credentialsPath)
        if let text = try? String(contentsOfFile: credentialsPath, encoding: .utf8),
           DevinQuotaFetcher.parseCredentialsTOML(text) != nil {
            return [.make(
                provider: .devin,
                accountKey: "Devin",
                source: .nativeCredential,
                credentialReference: credentialsPath
            )]
        }

        let databasePath = MonitorIdentity.expand(DevinQuotaFetcher.stateDBPath)
        guard DevinQuotaFetcher.loadAppCredential(path: databasePath) != nil else { return [] }
        return [.make(
            provider: .devin,
            accountKey: "Devin",
            source: .localIDE,
            credentialReference: databasePath
        )]
    }

    private func discoverGrokCredentials() -> [MonitorAccount] {
        let path = MonitorIdentity.expand(GrokQuotaFetcher.authPath)
        return GrokQuotaFetcher.loadCandidates(path: path).map { candidate in
            .make(
                provider: .grok,
                accountKey: candidate.entryKey,
                displayName: candidate.displayName,
                source: .nativeCredential,
                credentialReference: path + "#" + candidate.entryKey
            )
        }
    }

    private func discoverCodexFiles(aliases: [String: String]) -> [MonitorAccount] {
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(contentsOf: ["~/.config/codex/auth.json", "~/.codex/auth.json"].map(MonitorIdentity.expand))
        return paths.compactMap { path in
            guard let json = MonitorIdentity.json(at: path),
                  let tokens = json["tokens"] as? [String: Any],
                  (tokens["access_token"] as? String)?.isEmpty == false else { return nil }
            let email = MonitorIdentity.jwtString(tokens["id_token"] as? String, claim: "email")
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(tokens["id_token"] as? String, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let key = CodexAccountKey.canonical(
                email: email,
                accountID: accountID,
                aliases: aliases,
                fallback: "Codex"
            )
            return MonitorAccount.make(
                provider: .codex,
                accountKey: key,
                displayName: email ?? key,
                source: .nativeCredential,
                credentialReference: path
            )
        }
    }

    private func discoverClaudeFile() -> [MonitorAccount] {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.nilIfBlank ?? MonitorIdentity.expand("~/.claude")
        let path = (base as NSString).appendingPathComponent(".credentials.json")
        guard let json = MonitorIdentity.json(at: path),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              (oauth["accessToken"] as? String)?.isEmpty == false else { return [] }
        let email = (oauth["email"] as? String) ?? "Claude Code"
        return [.make(provider: .claude, accountKey: email, source: .nativeCredential, credentialReference: path)]
    }

    private func discoverCopilotFiles() -> [MonitorAccount] {
        let paths = [
            "~/.config/github-copilot/apps.json",
            "~/.config/github-copilot/hosts.json",
            "~/.config/gh/hosts.yml",
        ].map(MonitorIdentity.expand)
        return paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return MonitorAccount.make(provider: .copilot, accountKey: "GitHub Copilot", source: .nativeCredential, credentialReference: path)
        }
    }

    private func discoverKiroFile() -> [MonitorAccount] {
        guard let file = Self.kiroAuthFile(at: MonitorIdentity.expand("~/.aws/sso/cache/kiro-auth-token.json")) else { return [] }
        return [.make(provider: .kiro, accountKey: file.menuBarAccountKey, source: .nativeCredential, credentialReference: file.filePath)]
    }

    nonisolated static func kiroAuthFile(at path: String) -> DirectAuthFile? {
        guard let json = MonitorIdentity.json(at: path),
              (json["accessToken"] as? String ?? json["access_token"] as? String)?.isEmpty == false else { return nil }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return DirectAuthFile(
            id: path, provider: .kiro, email: json["email"] as? String,
            login: nil, expired: nil, accountType: nil, filePath: path,
            source: .nativeCredential, filename: filename,
            legacyIdentityKeys: [filename.replacingOccurrences(of: ".json", with: "")],
            kiroProfileARN: json["profile_arn"] as? String ?? json["profileArn"] as? String
        )
    }

    private func discoverNativeKeychains(codexAliases: [String: String]) -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        if let data = KeychainHelper.readExternalCredential(service: "Codex Auth"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false {
            let idToken = tokens["id_token"] as? String
            let email = MonitorIdentity.jwtString(idToken, claim: "email") ?? "Codex"
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(idToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let key = CodexAccountKey.canonical(
                email: email,
                accountID: accountID,
                aliases: codexAliases,
                fallback: "Codex"
            )
            accounts.append(.make(
                provider: .codex,
                accountKey: key,
                displayName: email,
                source: .nativeCredential,
                credentialReference: "keychain:Codex Auth"
            ))
        }
        if let data = KeychainHelper.readExternalCredential(service: "Claude Code-credentials"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           (oauth["accessToken"] as? String)?.isEmpty == false {
            accounts.append(.make(provider: .claude, accountKey: (oauth["email"] as? String) ?? "Claude Code", source: .nativeCredential, credentialReference: "keychain:Claude Code-credentials"))
        }
        return accounts
    }
}

actor MonitorRefreshCoordinator {
    private let discovery: MonitorAccountDiscovery
    private let snapshots: MonitorSnapshotStore
    private var inFlight: [AIProvider: Task<[String: ProviderQuotaData], Never>] = [:]
    private var retryAfter: [AIProvider: Date] = [:]
    private(set) var issues: [AIProvider: MonitorRefreshIssue] = [:]

    /// Generic account keys that represent the same underlying login as a more
    /// specific, higher-priority credential for the same provider (e.g. a
    /// nameless "Claude Code" native credential once "Claude Desktop" is also
    /// discovered). `discoverAccounts` hides these from the account list to
    /// avoid duplicate rows; `QuotaViewModel` uses the same table to keep quota
    /// data for hidden placeholders from lingering on the Quota screen.
    static let placeholderAccountKeys: [AIProvider: Set<String>] = [
        .copilot: ["github copilot"],
        .antigravity: ["antigravity"],
        .claude: ["claude code"],
        .codex: ["codex", "codex user"],
        .kiro: ["kiro"],
    ]

    init(
        discovery: MonitorAccountDiscovery = MonitorAccountDiscovery(),
        snapshots: MonitorSnapshotStore = MonitorSnapshotStore()
    ) {
        self.discovery = discovery
        self.snapshots = snapshots
    }

    func bootstrap() async -> MonitorRefreshBatch {
        // Discover aliases before filtering older snapshots and tombstones.
        let snapshot = await snapshots.load()
        let accounts = await discoverAccounts(merging: snapshot)
        let quotas = await discovery.filteringRemovedAccounts(from: snapshot)
        await finish(quotas: quotas)
        return MonitorRefreshBatch(accounts: accounts, quotas: quotas, issues: issues)
    }

    func discoverAccounts(merging quotas: [AIProvider: [String: ProviderQuotaData]] = [:]) async -> [MonitorAccount] {
        var accounts = await discovery.discover()
        let quotas = await discovery.filteringRemovedAccounts(from: quotas)
        accounts = Self.applyingQuotaDisplayNames(accounts, quotas: quotas)
        let disabledIDs = await discovery.disabledAccountIDs()
        let removedIDs = await discovery.removedAccountIDs()
        let existingKeys = Set(accounts.map(\.deduplicationKey))
        var appendedKeys = existingKeys

        for (provider, accountQuotas) in quotas {
            let source: MonitorAccountSource
            switch provider {
            case .cursor, .trae: source = .localIDE
            case .glm, .minimax, .warp, .clinePass, .factoryDroid, .openRouter, .amp: source = .apiKey
            default: source = .nativeCredential
            }
            for (accountKey, quota) in accountQuotas {
                let account = Self.makeQuotaDerivedAccount(
                    provider: provider,
                    accountKey: accountKey,
                    displayName: quota.accountDisplayName,
                    source: source,
                    disabledIDs: disabledIDs
                )
                guard !removedIDs.contains(account.id) else { continue }
                guard appendedKeys.insert(account.deduplicationKey).inserted else { continue }
                accounts.append(account)
            }
        }
        let placeholders = Self.placeholderAccountKeys
        accounts = accounts.filter { account in
            guard placeholders[account.provider]?.contains(account.accountKey.lowercased()) == true else { return true }
            return !accounts.contains {
                $0.provider == account.provider
                    && $0.id != account.id
                    && placeholders[account.provider]?.contains($0.accountKey.lowercased()) != true
                    && $0.source.priority >= account.source.priority
            }
        }
        return await discovery.metadata.filteringAccounts(accounts).sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    nonisolated static func makeQuotaDerivedAccount(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        disabledIDs: Set<String>
    ) -> MonitorAccount {
        // Accounts imported from a local IDE (Cursor, Trae) exist only as imported quota
        // data with no owned credential, so removing that data fully deletes them and
        // they will not reappear on the next discovery pass (issue #213).
        var account = MonitorAccount.make(
            provider: provider,
            accountKey: accountKey,
            displayName: displayName,
            source: source,
            canDelete: provider.isImportedFromLocalIDE
        )
        account.isDisabled = disabledIDs.contains(account.id)
        return account
    }

    nonisolated static func applyingQuotaDisplayNames(
        _ accounts: [MonitorAccount],
        quotas: [AIProvider: [String: ProviderQuotaData]]
    ) -> [MonitorAccount] {
        accounts.map { account in
            guard let displayName = quotas[account.provider]?[account.accountKey]?.accountDisplayName else {
                return account
            }
            return MonitorAccount(
                id: account.id,
                provider: account.provider,
                accountKey: account.accountKey,
                displayName: displayName,
                source: account.source,
                credentialReference: account.credentialReference,
                canDelete: account.canDelete,
                isDisabled: account.isDisabled
            )
        }
    }

    func refresh(
        provider: AIProvider,
        force: Bool,
        previous: [String: ProviderQuotaData],
        credentialAvailability: MonitorCredentialAvailability = .unknown,
        operation: @escaping @Sendable () async -> [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        if !force, let retry = retryAfter[provider], retry > Date() {
            return await discovery.filteringRemovedAccounts(from: [provider: previous])[provider] ?? [:]
        }
        if let task = inFlight[provider] {
            return await discovery.filteringRemovedAccounts(from: [provider: await task.value])[provider] ?? [:]
        }

        let task = Task {
            await self.discovery.filteringRemovedAccounts(
                from: [provider: await operation()]
            )[provider] ?? [:]
        }
        inFlight[provider] = task
        let fresh = await task.value
        let visiblePrevious = await discovery.filteringRemovedAccounts(from: [provider: previous])[provider] ?? [:]
        inFlight[provider] = nil

        if fresh.isEmpty, credentialAvailability == .missing {
            issues.removeValue(forKey: provider)
            retryAfter.removeValue(forKey: provider)
            return [:]
        }

        if fresh.isEmpty, !visiblePrevious.isEmpty {
            issues[provider] = MonitorRefreshIssue(
                message: "monitor.refresh.failed".localizedStatic(),
                occurredAt: Date(),
                affectedAccountKeys: Set(visiblePrevious.keys)
            )
            retryAfter[provider] = Date().addingTimeInterval(60)
            return await discovery.filteringRemovedAccounts(from: [provider: visiblePrevious])[provider] ?? [:]
        }

        if !fresh.isEmpty {
            var merged = visiblePrevious
            merged.merge(fresh) { _, new in new }
            if fresh.count < visiblePrevious.count {
                let refreshedKeys = Set(fresh.keys.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let failedKeys = Set(visiblePrevious.keys.filter {
                    !refreshedKeys.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                })
                issues[provider] = MonitorRefreshIssue(
                    message: "monitor.refresh.partial".localizedStatic(),
                    occurredAt: Date(),
                    affectedAccountKeys: failedKeys
                )
                retryAfter[provider] = Date().addingTimeInterval(60)
            } else {
                issues.removeValue(forKey: provider)
                retryAfter.removeValue(forKey: provider)
            }
            return await discovery.filteringRemovedAccounts(from: [provider: merged])[provider] ?? [:]
        }

        issues.removeValue(forKey: provider)
        retryAfter.removeValue(forKey: provider)
        return await discovery.filteringRemovedAccounts(from: [provider: fresh])[provider] ?? [:]
    }

    func finish(quotas: [AIProvider: [String: ProviderQuotaData]]) async {
        await discovery.metadata.persistSnapshot(quotas, at: snapshots.url)
    }

    func filteringRemovedAccounts(
        from quotas: [AIProvider: [String: ProviderQuotaData]]
    ) async -> [AIProvider: [String: ProviderQuotaData]] {
        await discovery.filteringRemovedAccounts(from: quotas)
    }

    func excludedQuotaAccountIDs() async -> Set<String> {
        await discovery.metadata.excludedQuotaAccountIDs()
    }

    /// Forget every Monitor-owned trace of a single account: its persisted snapshot
    /// entry (`Monitor/snapshots-v1.json`) and any disabled flag it left behind in
    /// `Monitor/accounts-v1.json`.
    ///
    /// Unlike `finish(quotas:)` this never rewrites unrelated entries, so it is safe to
    /// call from whichever mode is active. Deleting an account imported from Cursor or
    /// Trae has to run in every mode: the account row is shown outside Monitor mode, but
    /// `bootstrap()` reads the snapshot back when Monitor mode is entered, which would
    /// otherwise resurrect the deleted account (issue #213).
    func forgetSnapshotAccount(provider: AIProvider, accountKey: String) async {
        await snapshots.removeAccount(provider: provider, accountKey: accountKey)

        // `MonitorAccount.make` derives the id from provider + normalized account key, so
        // this resolves the same id the Monitor row used when it was disabled.
        let accountID = MonitorAccount.make(
            provider: provider,
            accountKey: accountKey,
            source: .localIDE
        ).id
        guard await discovery.disabledAccountIDs().contains(accountID) else { return }
        await discovery.setDisabled(false, accountID: accountID)
    }

    func currentIssues() -> [AIProvider: MonitorRefreshIssue] {
        issues
    }

    func setDisabled(_ disabled: Bool, accountID: String) async {
        await discovery.setDisabled(disabled, accountID: accountID)
    }

    func removeDiscoveredAccount(accountID: String) async throws {
        try await discovery.setRemoved(true, accountID: accountID)
        await finish(quotas: await snapshots.load())
    }

    func removedAccountCount() async -> Int {
        await discovery.removedAccountIDs().count
    }

    @discardableResult
    func restoreRemovedAccounts() async -> Int {
        await discovery.restoreRemovedAccounts()
    }

    func deleteOwnedAccount(accountID: String) async throws {
        try await discovery.deleteOwnedAccount(accountID: accountID)
        await finish(quotas: await snapshots.load())
    }
}

nonisolated enum MonitorCredentialAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

nonisolated enum SecureAtomicFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw MonitorRuntimeError.symbolicLinkRefused
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

nonisolated enum MonitorIdentity {
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jwtString(_ token: String?, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    static func jwtNestedString(_ token: String?, namespace: String, claim: String) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

nonisolated enum MonitorRuntimeError: LocalizedError {
    case keychainAuthorizationRequired
    case credentialWriteFailed
    case invalidCredential
    case symbolicLinkRefused

    var errorDescription: String? {
        switch self {
        case .keychainAuthorizationRequired: "monitor.error.keychainAuthorizationRequired".localizedStatic()
        case .credentialWriteFailed: "monitor.error.credentialWriteFailed".localizedStatic()
        case .invalidCredential: "monitor.error.invalidCredential".localizedStatic()
        case .symbolicLinkRefused: "monitor.error.symbolicLinkRefused".localizedStatic()
        }
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
