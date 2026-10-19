import Foundation
import QuotioApplication
import QuotioDomain

struct StatusBarMenuAccountSnapshot: Equatable, Sendable {
    let id: QuotaAccountID
    let email: String
    /// Nil for a tracked account whose quota could not be fetched; the row stays
    /// listed and `statusMessage` explains the gap.
    let quota: ProviderQuota?
    let statusMessage: String?
    let subscription: QuotaSubscriptionInfo?
    let isActiveInIDE: Bool
    let isRefreshing: Bool
    let isRefreshBlocked: Bool
}

struct StatusBarMenuProviderSnapshot: Equatable, Sendable {
    let provider: QuotaProvider
    let accounts: [StatusBarMenuAccountSnapshot]
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
}

struct StatusBarMenuDisplaySettings: Equatable, Sendable {
    let quotaDisplayMode: QuotaDisplayMode
    let quotaDisplayStyle: QuotaDisplayStyle
    let hideSensitiveInfo: Bool
    let modelAggregationMode: ModelAggregationMode

    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        modelAggregationMode.aggregate(percentages) ?? -1
    }
}

public struct StatusBarMenuSnapshot: Equatable, Sendable {
    let isLocalProxyMode: Bool
    let proxyPort: UInt16
    let isProxyRunning: Bool
    let tunnel: CloudflareTunnelSnapshot
    let providers: [StatusBarMenuProviderSnapshot]
    let selectedProvider: QuotaProvider?
    let isLoadingQuotas: Bool
    let displaySettings: StatusBarMenuDisplaySettings
    let appearanceMode: AppearanceMode
    let language: AppLanguage
}

public enum StatusBarMenuSnapshotMapper {
    nonisolated public static func makeSnapshot(
        mode: OperatingMode,
        proxyPort: UInt16,
        isProxyRunning: Bool,
        tunnel: CloudflareTunnelSnapshot,
        directAuthProviders: Set<QuotaProvider>,
        monitorAccounts: [Account],
        quota: QuotaSnapshot,
        installedAgents: Set<CLIAgent>,
        activeAntigravityEmail: String?,
        menuBarPreferences: MenuBarPreferences,
        appearanceMode: AppearanceMode,
        language: AppLanguage,
        accountStatusMessages: [QuotaAccountID: String] = [:]
    ) -> StatusBarMenuSnapshot {
        let isMonitorMode = mode == .monitor
        // Monitor discovery already applies removal and disabled preferences; raw
        // CLIProxyAPI auth files must not bring a hidden account back into the menu.
        var availableProviders = isMonitorMode ? Set<QuotaProvider>() : directAuthProviders
        availableProviders.formUnion(quota.quotas.compactMap { provider, accounts in
            accounts.isEmpty ? nil : provider
        })
        if isMonitorMode {
            availableProviders.formUnion(monitorProviders(monitorAccounts))
        }

        let providers = filterProviders(
            availableProviders,
            isMonitorMode: isMonitorMode,
            installedAgents: installedAgents
        ).compactMap { provider -> StatusBarMenuProviderSnapshot? in
            let isRefreshing = quota.refreshingProviders.contains(provider)
            let rows = accountRows(
                quotaRows: orderedAccounts(
                    quota.quotas[provider] ?? [:],
                    provider: provider,
                    activeAntigravityEmail: activeAntigravityEmail
                ),
                trackedAccounts: isMonitorMode
                    ? monitorAccounts.filter { $0.providerID.rawValue == provider.rawValue }
                    : [],
                provider: provider,
                statusMessages: accountStatusMessages
            )
            let accounts = rows.map { row in
                StatusBarMenuAccountSnapshot(
                    id: QuotaAccountID(provider: provider, accountKey: row.accountKey),
                    email: row.email,
                    quota: row.data,
                    statusMessage: row.statusMessage,
                    subscription: quota.subscriptions[provider]?[row.accountKey],
                    isActiveInIDE: provider == .antigravity
                        && emailsMatch(row.email, activeAntigravityEmail),
                    isRefreshing: isRefreshing,
                    isRefreshBlocked: isRefreshing
                )
            }
            // A provider that would only render a generic empty block is noise; an
            // account-specific error stays visible because it is actionable.
            guard accounts.contains(where: hasDisplayableContent) else { return nil }
            return StatusBarMenuProviderSnapshot(
                provider: provider,
                accounts: accounts,
                isRefreshing: isRefreshing,
                supportsScopedRefresh: provider.supportsQuotaOnlyMode
            )
        }

        return StatusBarMenuSnapshot(
            isLocalProxyMode: mode == .localProxy,
            proxyPort: proxyPort,
            isProxyRunning: isProxyRunning,
            tunnel: tunnel,
            providers: providers,
            selectedProvider: menuBarPreferences.selectedProvider.flatMap { selected in
                providers.contains(where: { $0.provider == selected }) ? selected : nil
            },
            isLoadingQuotas: !quota.refreshingProviders.isEmpty,
            displaySettings: StatusBarMenuDisplaySettings(
                quotaDisplayMode: menuBarPreferences.quotaDisplayMode,
                quotaDisplayStyle: menuBarPreferences.quotaDisplayStyle,
                hideSensitiveInfo: menuBarPreferences.hideSensitiveInfo,
                modelAggregationMode: menuBarPreferences.modelAggregationMode
            ),
            appearanceMode: appearanceMode,
            language: language
        )
    }

    nonisolated static func hasDisplayableContent(_ account: StatusBarMenuAccountSnapshot) -> Bool {
        if let quota = account.quota, !quota.models.isEmpty || quota.isForbidden { return true }
        return account.statusMessage?.isEmpty == false
    }

    struct AccountRow: Equatable {
        let accountKey: String
        let email: String
        let data: ProviderQuota?
        let statusMessage: String?
    }

    /// Quota rows first, in `orderedAccounts` order, then tracked accounts that produced
    /// no quota. Deriving the list from quota data alone hid every account whose fetch
    /// failed, so a user with two logins saw one row and no explanation for the other.
    nonisolated static func accountRows(
        quotaRows: [(accountKey: String, email: String, data: ProviderQuota)],
        trackedAccounts: [Account],
        provider: QuotaProvider,
        statusMessages: [QuotaAccountID: String]
    ) -> [AccountRow] {
        func normalized(_ key: String) -> String {
            key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var messages: [String: String] = [:]
        for (id, message) in statusMessages where id.provider == provider {
            messages[normalized(id.accountKey)] = message
        }
        let disabledKeys = Set(trackedAccounts.filter(\.isDisabled).map { normalized($0.accountKey) })
        var rows = quotaRows
            .filter { !disabledKeys.contains(normalized($0.accountKey)) }
            .map {
                AccountRow(
                    accountKey: $0.accountKey,
                    email: $0.email,
                    data: $0.data,
                    statusMessage: messages[normalized($0.accountKey)]
                )
            }
        var listed = Set(rows.map { normalized($0.accountKey) })
        let pending = trackedAccounts
            .filter { !$0.isDisabled }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for account in pending where listed.insert(normalized(account.accountKey)).inserted {
            rows.append(AccountRow(
                accountKey: account.accountKey,
                email: account.displayName,
                data: nil,
                statusMessage: messages[normalized(account.accountKey)]
            ))
        }
        return rows
    }

    nonisolated static func monitorProviders(_ accounts: [Account]) -> Set<QuotaProvider> {
        Set(accounts.lazy.filter { !$0.isDisabled }.map(\.provider))
    }

    nonisolated static func filterProviders(
        _ providers: Set<QuotaProvider>,
        isMonitorMode: Bool,
        installedAgents: Set<CLIAgent>
    ) -> [QuotaProvider] {
        let sorted = providers.sorted { $0.displayName < $1.displayName }
        guard !isMonitorMode else { return sorted }
        return sorted.filter { provider in
            guard let agent = provider.cliAgent else { return true }
            return installedAgents.contains(agent)
        }
    }

    nonisolated static func orderedAccounts(
        _ quotas: [String: ProviderQuota],
        provider: QuotaProvider,
        activeAntigravityEmail: String?
    ) -> [(accountKey: String, email: String, data: ProviderQuota)] {
        let sorted = quotas
            .map { (accountKey: $0.key, email: $0.value.accountDisplayName ?? $0.key, data: $0.value) }
            .sorted { $0.email < $1.email }

        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) {
            emailsMatch($0.email, activeAntigravityEmail)
        }
    }

    nonisolated private static func emailsMatch(_ email: String, _ activeEmail: String?) -> Bool {
        guard let activeEmail, !email.isEmpty, !activeEmail.isEmpty else { return false }
        return email.caseInsensitiveCompare(activeEmail) == .orderedSame
    }
}
