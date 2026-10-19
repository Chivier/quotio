import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class QuotaFeatureController {
    enum OAuthLaunchMode {
        case manual
        case autoOpen
    }

    let quota: QuotaScreenModel
    let accounts: AccountsScreenModel
    let oauth: OAuthScreenModel
    let antigravityAccounts: AntigravityAccountScreenModel

    @ObservationIgnored private let modeManager: OperatingModeManager
    @ObservationIgnored private let refreshSettings: RefreshSettingsManager
    @ObservationIgnored private let menuBarSettings: MenuBarSettingsManager
    @ObservationIgnored private let notifications: any NotificationRequesting
    @ObservationIgnored private var authFiles: () -> [ManagedAuthFile]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didChangeHandler: (@MainActor () -> Void)?

    private static let localProxyProviders: Set<QuotaProvider> = [
        .claude, .codex, .antigravity, .kiro, .copilot, .glm, .kimi, .warp, .clinePass,
    ]

    private static let monitorProviders: Set<QuotaProvider> = [
        .claude, .codex, .antigravity, .kiro, .copilot, .factoryDroid,
        .devin, .grok, .openRouter, .amp, .glm, .kimi, .minimax, .warp, .clinePass,
    ]

    static func automaticallyRefreshedProviders(for mode: QuotaOperatingMode) -> Set<QuotaProvider> {
        switch mode {
        case .localProxy: localProxyProviders
        case .monitor: monitorProviders
        }
    }

    public init(
        quota: QuotaScreenModel,
        accounts: AccountsScreenModel,
        oauth: OAuthScreenModel,
        antigravityAccounts: AntigravityAccountScreenModel,
        modeManager: OperatingModeManager,
        refreshSettings: RefreshSettingsManager,
        menuBarSettings: MenuBarSettingsManager,
        notifications: any NotificationRequesting,
        authFiles: @escaping () -> [ManagedAuthFile]
    ) {
        self.quota = quota
        self.accounts = accounts
        self.oauth = oauth
        self.antigravityAccounts = antigravityAccounts
        self.modeManager = modeManager
        self.refreshSettings = refreshSettings
        self.menuBarSettings = menuBarSettings
        self.notifications = notifications
        self.authFiles = authFiles
        refreshSettings.addCadenceChangeHandler { [weak self] _ in
            self?.restartAutomaticRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var operatingMode: QuotaOperatingMode {
        modeManager.isMonitorMode ? .monitor : .localProxy
    }

    var oauthState: QuotaOAuthState? { QuotaOAuthState(oauth.state) }

    public func setAuthFilesProvider(_ provider: @escaping () -> [ManagedAuthFile]) {
        authFiles = provider
    }

    public func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }

    public func initialize() async {
        await quota.bootstrap(mode: operatingMode)
        await accounts.reloadAuthFiles()
        await reloadAccounts()
        await refreshAll()
        restartAutomaticRefresh()
    }

    public func refreshAll(force: Bool = false) async {
        await quota.refreshAll(
            mode: operatingMode,
            providers: Self.automaticallyRefreshedProviders(for: operatingMode),
            force: force
        )
        await refreshImportedIDEQuotas()
        await antigravityAccounts.detectActiveAccount()
        await finishRefresh()
    }

    public func refresh(provider: QuotaProvider, force: Bool = true) async {
        guard provider.supportsQuotaOnlyMode else { return }
        await quota.refresh(provider: provider, mode: operatingMode, force: force)
        if provider == .antigravity {
            await antigravityAccounts.detectActiveAccount()
        }
        await finishRefresh()
    }

    /// - Parameter allowsCredentialAccessPrompt: true only when the user pressed the
    ///   refresh control for this account; the fetcher may then ask macOS for access to
    ///   a credential this build cannot read in the background.
    public func refresh(account: QuotaAccountID, allowsCredentialAccessPrompt: Bool = false) async {
        guard account.provider.supportsQuotaOnlyMode else { return }
        await quota.refresh(
            provider: account.provider,
            scope: .account(account.accountKey),
            mode: operatingMode,
            force: true,
            allowsUserInteraction: allowsCredentialAccessPrompt
        )
        await finishRefresh()
    }

    /// Regains access to an owned credential whose Keychain item is bound to another
    /// build, then refreshes that account. Runs only from an explicit user action.
    func restoreCredentialAccess(for account: QuotaAccountID) async {
        if let stored = storedAccount(for: account) {
            _ = await accounts.restoreCredentialAccess(accountID: stored.id)
        }
        await refresh(account: account, allowsCredentialAccessPrompt: true)
    }

    /// Refreshes Grok after the user signed in with the Grok CLI. Returns whether a
    /// Grok login now produces an account.
    func connectGrokAccounts() async -> Bool {
        await refresh(provider: .grok)
        return accounts.accounts.contains { $0.provider == .grok && !$0.isDisabled }
            || !(quota.providerQuotas[.grok]?.isEmpty ?? true)
    }

    func restoreRemovedAccounts() async {
        guard await accounts.restoreRemovedAccounts() > 0 else { return }
        await refreshAll(force: true)
    }

    var removedAccountCount: Int { accounts.removedAccountCount }

    func isCredentialUnreadable(_ account: QuotaAccountID) -> Bool {
        storedAccount(for: account).map(accounts.isCredentialUnreadable) ?? false
    }

    private func storedAccount(for account: QuotaAccountID) -> Account? {
        accounts.accounts.first {
            $0.providerID.rawValue == account.provider.rawValue
                && $0.accountKey.caseInsensitiveCompare(account.accountKey) == .orderedSame
        }
    }

    func refreshAutoDetectedProviders() async {
        let providers = Self.automaticallyRefreshedProviders(for: operatingMode).filter {
            !$0.supportsManualAuth && !$0.isImportedFromLocalIDE
        }
        await quota.refreshAll(mode: operatingMode, providers: Set(providers), force: true)
        await finishRefresh()
    }

    func refreshImportedIDEQuotas() async {
        for provider in [QuotaProvider.cursor, .trae] {
            let keys = Set(quota.providerQuotas[provider]?.keys.map { $0 } ?? [])
            guard !keys.isEmpty else { continue }
            await quota.refresh(
                provider: provider,
                scope: .importedAccounts(keys),
                mode: operatingMode,
                force: true
            )
        }
    }

    func importIDEProvider(_ provider: QuotaProvider) async -> [String: ProviderQuota] {
        guard provider.isImportedFromLocalIDE else { return [:] }
        await quota.refresh(provider: provider, mode: operatingMode, force: true)
        await finishRefresh()
        return quota.providerQuotas[provider] ?? [:]
    }

    /// Every account row can be removed. An owned credential is deleted; one owned by
    /// another app or CLI is hidden in Quotio and left untouched at its source.
    func remove(account: QuotaAccountID) async {
        if let storedAccount = storedAccount(for: account) {
            if storedAccount.source == .localIDE {
                // Imported IDE rows exist only as quota data; dropping it deletes them.
                await accounts.setDisabled(false, accountID: storedAccount.id)
            } else {
                try? await accounts.remove(accountID: storedAccount.id)
            }
        } else if operatingMode == .monitor {
            try? await accounts.remove(accountID: AccountIdentity.make(
                providerID: AccountProviderID(rawValue: account.provider.rawValue),
                accountKey: account.accountKey
            ).id)
        }
        await quota.removeQuota(for: account, mode: operatingMode)
        await finishRefresh()
    }

    func setAccountDisabled(_ disabled: Bool, accountID: String) async {
        let account = accounts.accounts.first { $0.id == accountID }
        await accounts.setDisabled(disabled, accountID: accountID)
        if disabled, let account, let provider = QuotaProvider(rawValue: account.providerID.rawValue) {
            await quota.removeQuota(
                for: QuotaAccountID(provider: provider, accountKey: account.accountKey),
                mode: operatingMode
            )
        }
        await finishRefresh()
    }

    func saveAPIKey(
        provider: QuotaProvider,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil
    ) async throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedKey.isEmpty else {
            throw QuotaCredentialInputError.invalidCredential
        }
        guard provider != .amp
            || trimmedLabel.caseInsensitiveCompare(ProviderAccountKey.ampNative) != .orderedSame else {
            throw QuotaCredentialInputError.invalidCredential
        }

        let previousAccount = existingAccountID.flatMap { id in
            accounts.accounts.first { $0.id == id && $0.providerID.rawValue == provider.rawValue }
        }
        do {
            try await accounts.saveAPIKey(
                providerID: AccountProviderID(rawValue: provider.rawValue),
                label: trimmedLabel,
                apiKey: trimmedKey,
                existingAccountID: existingAccountID
            )
        } catch is AccountServiceFailure {
            throw QuotaCredentialInputError.invalidCredential
        }
        if let previousAccount, previousAccount.accountKey != trimmedLabel {
            await quota.removeQuota(
                for: QuotaAccountID(provider: provider, accountKey: previousAccount.accountKey),
                mode: operatingMode
            )
        }
        await refresh(provider: provider)
    }

    /// - Parameter expectedAccountID: set when re-authenticating one existing account;
    ///   a login that resolves to a different account is rejected instead of replacing it.
    func startOAuth(
        for provider: QuotaProvider,
        method: OAuthAuthorizationMethod = .providerDefault,
        launchMode: OAuthLaunchMode = .manual,
        expectedAccountID: String? = nil
    ) async {
        await oauth.start(OAuthAuthorizationRequest(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            method: method,
            automaticallyOpensBrowser: launchMode == .autoOpen,
            expectedAccountID: expectedAccountID,
            // Adding a Codex workspace that is already connected is reported, not merged.
            addingNewAccount: expectedAccountID == nil && provider == .codex && operatingMode == .monitor
        ))
    }

    func completeMonitorOAuthCode(_ code: String, provider: QuotaProvider) async {
        guard modeManager.isMonitorMode, provider == .claude else { return }
        await oauth.completeManualCode(code)
    }

    func cancelOAuth() {
        Task { await oauth.cancel() }
    }

    func monitorStatus(for account: Account) -> (status: String?, message: String?) {
        guard let provider = QuotaProvider(rawValue: account.providerID.rawValue) else { return (nil, nil) }
        let accountID = QuotaAccountID(provider: provider, accountKey: account.accountKey)
        let current = quota.providerQuotas[provider]?[account.accountKey]
        let updated = current?.lastUpdated
        // A Quotio-owned API key does not expire because a quota endpoint is briefly
        // unavailable; only an explicit 401/403 proves the credential needs attention.
        let hasStoredAPIKey = provider.usesAPIKeyAuth && account.source == .quotioKeychain
        // An unreadable item is reported first: fetchers mark such an account as
        // forbidden, but signing in again is not needed, only restoring access.
        if accounts.isCredentialUnreadable(account) {
            return ("error", "monitor.status.credentialUnreadable".localized())
        }
        if current?.isForbidden == true {
            return ("error", "monitor.status.authenticationRequired".localized())
        }
        if let issue = quota.state.accountIssues[accountID], updated == nil || updated! <= issue.occurredAt {
            return (hasStoredAPIKey ? "ready" : "outdated", message(for: issue))
        }
        // A partial provider refresh records the affected accounts individually above.
        if let issue = quota.state.issues[provider], issue.kind == .failed,
           updated == nil || updated! <= issue.occurredAt {
            return (hasStoredAPIKey ? "ready" : "outdated", message(for: issue))
        }
        guard let updated else { return hasStoredAPIKey ? ("ready", nil) : (nil, nil) }
        let staleAfter = refreshSettings.refreshCadence.intervalSeconds ?? 600
        if Date().timeIntervalSince(updated) > staleAfter {
            return (
                hasStoredAPIKey ? "ready" : "outdated",
                String(format: "monitor.status.outdated".localized(), updated.formatted(date: .abbreviated, time: .shortened))
            )
        }
        return (
            "ready",
            String(format: "monitor.status.updated".localized(), updated.formatted(date: .omitted, time: .shortened))
        )
    }

    /// Status lines for menu-bar rows whose account is not in a healthy state.
    public func menuStatusMessages() -> [QuotaAccountID: String] {
        guard operatingMode == .monitor else { return [:] }
        var messages: [QuotaAccountID: String] = [:]
        for account in accounts.accounts where !account.isDisabled {
            let status = monitorStatus(for: account)
            guard status.status != "ready", let message = status.message else { continue }
            messages[QuotaAccountID(provider: account.provider, accountKey: account.accountKey)] = message
        }
        return messages
    }

    func synchronizeMenuBarSelection() {
        func canonicalItem(_ item: MenuBarQuotaItem) -> MenuBarQuotaItem {
            guard let provider = QuotaProvider(rawValue: item.provider),
                  let aliases = quota.state.accountAliases[provider] else { return item }
            var key = item.accountKey
            if provider == .codex {
                if key.hasPrefix("codex-") { key.removeFirst("codex-".count) }
                if key.hasSuffix(".json") { key.removeLast(".json".count) }
            }
            guard let canonical = aliases[key],
                  quota.providerQuotas[provider]?[canonical] != nil else { return item }
            return MenuBarQuotaItem(provider: item.provider, accountKey: canonical)
        }

        var selectedIDs = Set<String>()
        let selected = menuBarSettings.selectedItems.map(canonicalItem).filter {
            selectedIDs.insert($0.id).inserted
        }
        if selected != menuBarSettings.selectedItems {
            menuBarSettings.selectedItems = selected
        }
        let disabledItemIDs = Set(accounts.accounts.compactMap { account -> String? in
            guard account.isDisabled,
                  let provider = QuotaProvider(rawValue: account.providerID.rawValue) else { return nil }
            return MenuBarQuotaItem(
                provider: provider.rawValue,
                accountKey: account.accountKey
            ).id.lowercased()
        })
        var available: [MenuBarQuotaItem] = []
        var seen = Set<String>()
        for (provider, quotas) in quota.providerQuotas {
            for key in quotas.keys {
                let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: key)
                if !disabledItemIDs.contains(item.id.lowercased()), seen.insert(item.id).inserted {
                    available.append(item)
                }
            }
        }
        for file in authFiles() where !file.disabled {
            guard let provider = file.providerID else { continue }
            let item = canonicalItem(MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey))
            if !disabledItemIDs.contains(item.id.lowercased()), seen.insert(item.id).inserted {
                available.append(item)
            }
        }
        for file in accounts.authFiles {
            guard let provider = QuotaProvider(rawValue: file.providerID.rawValue) else { continue }
            let item = canonicalItem(MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey))
            if !disabledItemIDs.contains(item.id.lowercased()), seen.insert(item.id).inserted {
                available.append(item)
            }
        }
        menuBarSettings.pruneInvalidItems(validItems: available)
        menuBarSettings.autoSelectNewAccounts(availableItems: available)
    }

    public func shutdown() async {
        refreshTask?.cancel()
        refreshTask = nil
        await quota.shutdown()
        await oauth.shutdown()
    }

    private func finishRefresh() async {
        await reloadAccounts()
        await removeDisabledMonitorQuotas()
        if operatingMode == .monitor {
            await quota.purgeExcludedAccounts(mode: operatingMode)
        }
        checkQuotaNotifications()
        synchronizeMenuBarSelection()
        didChangeHandler?()
    }

    private func reloadAccounts() async {
        await accounts.reloadAccounts(
            merging: quota.providerQuotas,
            aliases: quota.state.accountAliases
        )
    }

    private func removeDisabledMonitorQuotas() async {
        guard operatingMode == .monitor else { return }
        for account in accounts.accounts where account.isDisabled {
            guard let provider = QuotaProvider(rawValue: account.providerID.rawValue),
                  let quotaKey = quota.providerQuotas[provider]?.keys.first(where: {
                      $0.caseInsensitiveCompare(account.accountKey) == .orderedSame
                  }) else { continue }
            await quota.removeQuota(
                for: QuotaAccountID(provider: provider, accountKey: quotaKey),
                mode: operatingMode
            )
        }
    }

    private func restartAutomaticRefresh() {
        refreshTask?.cancel()
        guard let interval = refreshSettings.refreshCadence.intervalNanoseconds else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    private func checkQuotaNotifications() {
        let threshold = notifications.snapshot.preferences.quotaAlertThreshold
        for (provider, accountQuotas) in quota.providerQuotas {
            for (account, data) in accountQuotas {
                let values = data.models.map(\.percentage).filter { $0 >= 0 }
                guard let minimum = values.min() else { continue }
                if minimum <= threshold {
                    notifications.submit(.quotaLow(
                        provider: provider.displayName,
                        account: account,
                        remainingPercent: minimum
                    ))
                } else {
                    notifications.clearQuotaNotification(
                        provider: provider.rawValue,
                        account: account
                    )
                }
            }
        }
    }

    private func message(for issue: QuotaRefreshIssue) -> String {
        switch issue.kind {
        case .failed: "monitor.refresh.failed".localized()
        case .partial: "monitor.refresh.partial".localized()
        }
    }
}

private enum QuotaCredentialInputError: LocalizedError {
    case invalidCredential

    var errorDescription: String? {
        "The Monitor credential file is invalid."
    }
}

struct QuotaOAuthState: Identifiable, Equatable {
    let provider: QuotaProvider
    var status: OAuthStatus
    var state: String?
    var error: String?
    var authURL: String?

    @MainActor
    init?(_ flowState: OAuthFlowState) {
        let providerID: AccountProviderID
        let prompt: OAuthPrompt?
        switch flowState {
        case .idle:
            return nil
        case .authorizing(let id):
            providerID = id
            prompt = nil
            status = .waiting
        case .awaitingUser(let id, let value):
            providerID = id
            prompt = value
            status = .polling
        case .awaitingManualCode(let id, let value, let manualState):
            providerID = id
            prompt = value
            state = manualState
            status = .polling
        case .succeeded(let id, _):
            providerID = id
            prompt = nil
            status = .success
        case .failed(let id, let failure):
            providerID = id
            prompt = nil
            status = .error
            error = failure.displayMessage(for: id)
        }
        guard let provider = QuotaProvider(rawValue: providerID.rawValue) else { return nil }
        self.provider = provider
        state = state ?? prompt?.userCode
        authURL = prompt?.authorizationURL?.absoluteString
        if error == nil {
            error = prompt?.status?.localizedText
                ?? prompt?.userCode.map { String(format: "oauth.enterDeviceCode".localizedStatic(), $0) }
        }
    }

    var id: String { provider.rawValue }

    enum OAuthStatus {
        case waiting, polling, success, error
    }
}

private extension OAuthFlowFailure {
    @MainActor
    func displayMessage(for providerID: AccountProviderID) -> String {
        switch self {
        case .unsupportedProvider:
            "Quotio-managed login is not available for this provider."
        case .invalidResponse:
            "The OAuth provider returned an invalid response."
        case .expired:
            "The device authorization expired. Please try again."
        case .stateMismatch:
            "The OAuth callback state did not match the login request."
        case .browserOpenFailed:
            "Quotio could not open the OAuth page in your browser."
        case .proxyCLI(let status):
            status.localizedText
        case .provider(let message):
            message
        case .accountMismatch:
            providerID.rawValue == QuotaProvider.claude.rawValue
                ? "oauth.claude.accountMismatch".localized()
                : "oauth.codex.accountMismatch".localized()
        case .accountAlreadyConnected:
            "oauth.codex.alreadyConnected".localized()
        case .credentialStorageDenied:
            "monitor.error.keychainAuthorizationRequired".localized()
        case .unknown:
            "The OAuth request failed. Please try again."
        }
    }
}

private extension OAuthPromptStatus {
    @MainActor
    var localizedText: String {
        switch self {
        case .proxyCLI(let status): status.localizedText
        case .importingQuotas: "oauth.cli.importingQuotas".localized()
        }
    }
}

private extension ProxyCLIAuthStatus {
    @MainActor
    var localizedText: String {
        switch self {
        case .authenticationCompleted:
            "oauth.cli.authenticationCompleted".localized()
        case .authenticationCancelled:
            "oauth.cli.authenticationCancelled".localized()
        case .copilotBrowserOpened(let deviceCode):
            if let deviceCode {
                String(format: "oauth.cli.copilotBrowserOpenedWithCode".localized(), deviceCode)
            } else {
                "oauth.cli.copilotBrowserOpenedWithoutCode".localized()
            }
        case .browserOpened:
            "oauth.cli.browserOpened".localized()
        case .failedToStart(let details):
            String(format: "oauth.cli.failedToStart".localized(), details)
        }
    }
}
