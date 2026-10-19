//
//  StatusBarMenuRenderer.swift
//  QuotioPresentation
//
//  Native NSMenu renderer that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual items)
//  - Actions
//

import AppKit
import QuotioDomain
import SwiftUI

@MainActor
@Observable
final class StatusBarProviderFilterController {
    enum Scope {
        case provider(QuotaProvider)
        case allProvidersOnly
    }

    var selectedProvider: QuotaProvider?

    @ObservationIgnored private weak var menu: NSMenu?
    @ObservationIgnored private var scopes: [ObjectIdentifier: Scope] = [:]
    @ObservationIgnored private let onSelectionChanged: (QuotaProvider?) -> Void

    init(
        selectedProvider: QuotaProvider?,
        onSelectionChanged: @escaping (QuotaProvider?) -> Void
    ) {
        self.selectedProvider = selectedProvider
        self.onSelectionChanged = onSelectionChanged
    }

    func register(_ item: NSMenuItem, scope: Scope) {
        scopes[ObjectIdentifier(item)] = scope
        item.isHidden = !isVisible(scope)
    }

    func activate(in menu: NSMenu) {
        self.menu = menu
        applySelection()
    }

    func select(_ provider: QuotaProvider?) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
        applySelection()
        onSelectionChanged(provider)
    }

    private func applySelection() {
        guard let menu else { return }
        for item in menu.items {
            guard let scope = scopes[ObjectIdentifier(item)] else { continue }
            item.isHidden = !isVisible(scope)
        }
        menu.update()
    }

    private func isVisible(_ scope: Scope) -> Bool {
        switch scope {
        case .provider(let provider):
            selectedProvider == nil || selectedProvider == provider
        case .allProvidersOnly:
            selectedProvider == nil
        }
    }
}

// MARK: - Status Bar Menu Renderer

@MainActor
final class StatusBarMenuRenderer {
    private let snapshot: StatusBarMenuSnapshot
    private let commands: StatusBarCommandDispatcher
    private let providerFilterController: StatusBarProviderFilterController
    private let menuWidth: CGFloat = 360

    init(
        snapshot: StatusBarMenuSnapshot,
        commands: StatusBarCommandDispatcher
    ) {
        self.snapshot = snapshot
        self.commands = commands
        let availableProviders = snapshot.providers.map(\.provider)
        let selectedProvider = snapshot.selectedProvider.flatMap { provider in
            availableProviders.contains(provider) ? provider : nil
        }
        self.providerFilterController = StatusBarProviderFilterController(
            selectedProvider: selectedProvider,
            onSelectionChanged: { provider in
                commands.dispatch(.selectProvider(provider))
            }
        )
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        let menu = makeMenu()

        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())

        // 2. Network info (Proxy + Tunnel) - Local Proxy Mode only
        if snapshot.isLocalProxyMode {
            menu.addItem(buildNetworkInfoItem())
            menu.addItem(NSMenuItem.separator())
        }

        // 3. Provider picker and account groups
        let providers = snapshot.providers
        if !providers.isEmpty {
            let pickerView = MenuProviderPickerView(
                providers: providers.map(\.provider),
                controller: providerFilterController
            )
            menu.addItem(viewItem(for: pickerView))
            menu.addItem(NSMenuItem.separator())

            for providerSnapshot in providers {
                let headerView = MenuProviderSectionHeader(
                    provider: providerSnapshot.provider,
                    isRefreshing: providerSnapshot.isRefreshing,
                    supportsScopedRefresh: providerSnapshot.supportsScopedRefresh,
                    onRefresh: {
                        self.commands.dispatch(.refreshProvider(providerSnapshot.provider))
                    }
                )
                let headerItem = viewItem(for: headerView)
                providerFilterController.register(headerItem, scope: .allProvidersOnly)
                menu.addItem(headerItem)

                if providerSnapshot.accounts.isEmpty {
                    let emptyItem = buildEmptyStateItem()
                    providerFilterController.register(
                        emptyItem,
                        scope: .provider(providerSnapshot.provider)
                    )
                    menu.addItem(emptyItem)
                } else {
                    for account in providerSnapshot.accounts {
                        let cardItem = buildAccountCardItem(account)
                        providerFilterController.register(
                            cardItem,
                            scope: .provider(providerSnapshot.provider)
                        )
                        menu.addItem(cardItem)
                    }
                }
            }

            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(buildEmptyStateItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 4. Action items
        for item in buildActionItems() {
            menu.addItem(item)
        }

        providerFilterController.activate(in: menu)
        
        return menu
    }

    func activateProviderFilter(in menu: NSMenu) {
        providerFilterController.activate(in: menu)
    }

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        let headerView = MenuHeaderView(isLoading: snapshot.isLoadingQuotas)
        return viewItem(for: headerView)
    }

    // MARK: - Network Info Item (Proxy + Tunnel combined)

    private func buildNetworkInfoItem() -> NSMenuItem {
        let networkView = MenuNetworkInfoView(
            port: String(snapshot.proxyPort),
            isProxyRunning: snapshot.isProxyRunning,
            tunnelStatus: snapshot.tunnel.status,
            tunnelURL: snapshot.tunnel.publicURL,
            onProxyToggle: {
                self.commands.dispatch(.toggleProxy)
            },
            onCopyProxyURL: {
                self.commands.dispatch(.copyProxyURL("http://127.0.0.1:\(self.snapshot.proxyPort)"))
            },
            onTunnelToggle: {
                self.commands.dispatch(.toggleTunnel(port: self.snapshot.proxyPort))
            },
            onCopyTunnelURL: {
                guard let url = self.snapshot.tunnel.publicURL else { return }
                self.commands.dispatch(.copyTunnelURL(url))
            }
        )
        return viewItem(for: networkView)
    }

    // MARK: - Account Card Item (with submenu for Antigravity)

    private func buildAccountCardItem(_ account: StatusBarMenuAccountSnapshot) -> NSMenuItem {
        let provider = account.id.provider
        let cardView = MenuAccountCardView(
            accountKey: account.id.accountKey,
            email: account.email,
            data: account.quota,
            statusMessage: account.statusMessage,
            provider: provider,
            subscriptionInfo: account.subscription,
            isActiveInIDE: account.isActiveInIDE,
            isRefreshing: account.isRefreshing,
            canRefresh: !account.isRefreshBlocked && provider.supportsQuotaOnlyMode,
            settings: snapshot.displaySettings,
            onRefresh: {
                self.commands.dispatch(.refreshAccount(account.id))
            },
            onUseAccount: provider == .antigravity && !account.isActiveInIDE ? {
                self.commands.dispatch(.useAntigravityAccount(email: account.email))
            } : nil
        )

        let item = viewItem(for: cardView)
        guard let quota = account.quota else { return item }

        let isAntigravitySummary = provider == .antigravity
            && quota.models.contains { $0.name.hasPrefix("antigravity-") }

        if provider == .codex, let analytics = quota.analytics, !analytics.isEmpty {
            item.submenu = buildCodexAnalyticsSubmenu(analytics: analytics)
        } else if provider == .antigravity && !quota.models.isEmpty && !isAntigravitySummary {
            item.submenu = buildAntigravitySubmenu(data: quota)
        }

        return item
    }

    private func buildCodexAnalyticsSubmenu(analytics: QuotaAnalytics) -> NSMenu {
        let submenu = makeMenu()
        submenu.addItem(viewItem(for: AnalyticsDetailSection(analytics: analytics), width: 640))
        return submenu
    }

    // MARK: - Antigravity Submenu

    private func buildAntigravitySubmenu(data: ProviderQuota) -> NSMenu {
        let submenu = makeMenu()

        let hasSummary = data.models.contains { $0.name.hasPrefix("antigravity-") }
        let allModels = hasSummary ? data.models : data.models.sorted { $0.name < $1.name }

        for model in allModels {
            let isSummary = model.name.hasPrefix("antigravity-")
            let modelItem = viewItem(for: MenuModelDetailView(
                model: model,
                showRawName: !isSummary,
                settings: snapshot.displaySettings
            ))
            submenu.addItem(modelItem)
        }

        return submenu
    }
    
    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        let emptyView = MenuEmptyStateView()
        return viewItem(for: emptyView)
    }
    
    // MARK: - Action Items
    
    private func buildActionItems() -> [NSMenuItem] {
        let actionsView = MenuActionsView(
            isLoading: snapshot.isLoadingQuotas,
            onRefresh: { self.commands.dispatch(.refreshAll) },
            onOpenApp: { self.commands.dispatch(.openApp) },
            onQuit: { self.commands.dispatch(.quit) }
        )
        return [viewItem(for: actionsView)]
    }
    
    // MARK: - Helpers

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = snapshot.appearanceMode.appKitAppearance
        return menu
    }
    
    private func viewItem<V: View>(for view: V, width: CGFloat? = nil) -> NSMenuItem {
        let effectiveWidth = width ?? menuWidth
        let rootView = view
            .frame(width: effectiveWidth)
            .environment(\.locale, snapshot.language.locale)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = snapshot.appearanceMode.appKitAppearance
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}

// MARK: - SwiftUI Menu Components

// MARK: Header View

private struct MenuHeaderView: View {
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}



// MARK: - Provider Section Header

private struct MenuProviderSectionHeader: View {
    let provider: QuotaProvider
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconMono(provider: provider, size: 14)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing || !supportsScopedRefresh)
            .help("action.refreshQuota".localized())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Picker View (separate from accounts list)

private struct MenuProviderPickerView: View {
    let providers: [QuotaProvider]
    let controller: StatusBarProviderFilterController
    
    var body: some View {
        // Wrap providers in a flexible layout
        FlowLayout(spacing: 6) {
            AllProviderFilterButton(isSelected: controller.selectedProvider == nil) {
                controller.select(nil)
            }

            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: controller.selectedProvider == provider
                ) {
                    controller.select(provider)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: All Provider Filter Button

private struct AllProviderFilterButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .opacity(isSelected ? 1.0 : 0.7)

                Text("menubar.providers.all".localized())
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: QuotaProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .opacity(isSelected ? 1.0 : 0.7)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Monochrome Provider Icon

private struct ProviderIconMono: View {
    let provider: QuotaProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorMultiply(.primary)
            } else {
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Network Info View (Proxy + Tunnel Combined)

private struct MenuNetworkInfoView: View {
    let port: String
    let isProxyRunning: Bool
    let tunnelStatus: CloudflareTunnelStatus
    let tunnelURL: String?
    let onProxyToggle: () -> Void
    let onCopyProxyURL: () -> Void
    let onTunnelToggle: () -> Void
    let onCopyTunnelURL: () -> Void

    private var proxyURL: String { "http://127.0.0.1:" + port }

    @State private var didCopyProxy = false
    @State private var didCopyTunnel = false

    private enum CopyTarget {
        case proxy
        case tunnel
    }

    var body: some View {
        VStack(spacing: 8) {
            // Proxy Row
            HStack(spacing: 8) {
                Circle()
                    .fill(isProxyRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text("providers.source.proxy".localized())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                if isProxyRunning {
                    Text(proxyURL)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    copyButton(
                        isCopied: didCopyProxy,
                        helpText: "action.copy".localized()
                    ) {
                        onCopyProxyURL()
                        triggerCopyState(.proxy)
                    }
                }

                Spacer()

                Button(action: onProxyToggle) {
                    Image(systemName: isProxyRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isProxyRunning ? .red : .green)
                }
                .buttonStyle(.plain)
            }

            // Tunnel Row (only show when proxy is running)
            if isProxyRunning {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tunnelStatus == .active ? Color.blue : Color.gray)
                        .frame(width: 6, height: 6)

                    Text(tunnelStatus == .active ? "tunnel.action.stop".localized() : "tunnel.action.start".localized())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if tunnelStatus == .active, let url = tunnelURL {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        copyButton(
                            isCopied: didCopyTunnel,
                            helpText: "action.copy".localized()
                        ) {
                            onCopyTunnelURL()
                            triggerCopyState(.tunnel)
                        }
                    } else if tunnelStatus == .starting {
                        Text("status.starting".localized())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button(action: onTunnelToggle) {
                        Image(systemName: tunnelStatus == .active || tunnelStatus == .starting ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(tunnelStatus == .active ? .red : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnelStatus == .starting || tunnelStatus == .stopping)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func triggerCopyState(_ target: CopyTarget) {
        setCopied(target, value: true)

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                setCopied(target, value: false)
            }
        }
    }

    private func setCopied(_ target: CopyTarget, value: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch target {
            case .proxy:
                didCopyProxy = value
            case .tunnel:
                didCopyTunnel = value
            }
        }
    }

    @ViewBuilder
    private func copyButton(isCopied: Bool, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(isCopied ? .green : .secondary)
                .scaleEffect(isCopied ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: Account Card View

private struct MenuAccountCardView: View {
    let accountKey: String
    let email: String
    let data: ProviderQuota?
    let statusMessage: String?
    let provider: QuotaProvider
    let subscriptionInfo: QuotaSubscriptionInfo?
    let isActiveInIDE: Bool
    let isRefreshing: Bool
    let canRefresh: Bool
    let settings: StatusBarMenuDisplaySettings
    let onRefresh: () -> Void
    let onUseAccount: (() -> Void)?

    @State private var isHovered = false
    @State private var isUseHovered = false
    @State private var isUsingAccount = false
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }

    private var quotaModels: [QuotaMetric] { data?.models ?? [] }
    
    // Modern Tier Badge Config
    private var tierConfig: (name: String, bgColor: Color, textColor: Color)? {
        if let info = subscriptionInfo {
            let tierId = info.tierId.lowercased()
            let tierName = info.tierDisplayName.lowercased()
            
            if tierId.contains("ultra") || tierName.contains("ultra") {
                return ("Ultra", .orange.opacity(0.15), .orange)
            }
            if tierId.contains("pro") || tierName.contains("pro") {
                return ("Pro", .blue.opacity(0.15), .blue)
            }
            if tierId.contains("standard") || tierId.contains("free") ||
               tierName.contains("standard") || tierName.contains("free") {
                return ("Free", .secondary.opacity(0.1), .secondary)
            }
            return (info.tierDisplayName, .secondary.opacity(0.1), .secondary)
        }
        
        if provider == .codex, let planName = codexPlanDisplayName(data?.planType) {
            let config = planConfig(for: planName)
            return (planName, config.bgColor, config.textColor)
        }

        guard let planName = data?.planDisplayName else { return nil }
        return planConfig(for: planName)
    }

    private func codexPlanDisplayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let exact = [
            "pro": "Pro 20x",
            "prolite": "Pro 5x",
            "pro_lite": "Pro 5x",
            "pro-lite": "Pro 5x",
            "pro lite": "Pro 5x"
        ]
        if let value = exact[trimmed.lowercased()] {
            return value
        }

        let cleaned = trimmed
            .replacingOccurrences(of: #"(?i)\b(claude|codex|account|plan)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if let value = exact[cleaned.lowercased()] {
            return value
        }

        let display = cleaned.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if lower == "cbp" || lower == "k12" { return lower.uppercased() }
            if word == word.uppercased(), word.contains(where: { $0.isLetter }) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return display.isEmpty ? trimmed : display
    }
    
    private func planConfig(for planName: String) -> (name: String, bgColor: Color, textColor: Color) {
        let lowercased = planName.lowercased()
        
        if lowercased.contains("ultra") {
            return ("Ultra", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("pro") {
            return ("Pro", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("plus") {
            return ("Plus", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("team") {
            return ("Team", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red.opacity(0.15), .red)
        }
        if lowercased.contains("business") {
            return ("Business", .red.opacity(0.15), .red)
        }
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary.opacity(0.1), .secondary)
        }
        
        return (planName, .secondary.opacity(0.1), .secondary)
    }
    
    private var isAntigravity: Bool {
        provider == .antigravity && !quotaModels.isEmpty
    }
    
    private var antigravityGroups: [AntigravityDisplayGroup] {
        guard isAntigravity else { return [] }
        let summaryModels = quotaModels.filter { $0.name.hasPrefix("antigravity-") }
        if !summaryModels.isEmpty {
            return summaryModels
                .map { AntigravityDisplayGroup(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime) }
        }

        var groups: [AntigravityDisplayGroup] = []

        let gemini3ProModels = quotaModels.filter {
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image")
        }
        if !gemini3ProModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3ProModels.map(\.percentage))
            let minModel = gemini3ProModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let gemini3FlashModels = quotaModels.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3FlashModels.map(\.percentage))
            let minModel = gemini3FlashModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let geminiImageModels = quotaModels.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(geminiImageModels.map(\.percentage))
            let minModel = geminiImageModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let claudeModels = quotaModels.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(claudeModels.map(\.percentage))
            let minModel = claudeModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Claude 4.5", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection
            quotaContentSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 7) {
            // Provider Icon
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)
                .opacity(0.8)

            // Keep freshness attached to the account identity instead of spending a
            // separate footer row on the same timestamp in every card.
            VStack(alignment: .leading, spacing: 1) {
                Text(displayEmail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let data {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 8, weight: .medium))
                        Text(data.lastUpdated.formatted(
                            .relative(presentation: .numeric, unitsStyle: .abbreviated)
                        ))
                        .lineLimit(1)
                    }
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                }
            }
            .layoutPriority(1)

            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canRefresh)
            .help("action.refreshQuota".localized())
            .accessibilityLabel("action.refreshQuota".localized())
            
            // Tier Badge
            if let config = tierConfig {
                Text(config.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(config.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(config.bgColor)
                    .clipShape(Capsule())
            }
            
            // Active/Use Badge
            if isActiveInIDE {
                Text("antigravity.active".localized())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            } else if let onUse = onUseAccount {
                Button {
                    isUsingAccount = true
                    Task { @MainActor in
                        onUse()
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        isUsingAccount = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isUsingAccount {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("antigravity.useInIDE".localized() + " " + "→".localized())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isUseHovered ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.secondary.opacity(isUseHovered ? 0.45 : 0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUsingAccount)
                .onHover { isUseHovered = $0 }
            }
        }
    }
    
    // MARK: - Quota Content
    
    private var quotaContentSection: some View {
        let isCardStyle = displayStyle == .card
        let models: [ModelBadgeData] = {
            if isAntigravity {
                return antigravityGroups.map { ModelBadgeData(name: $0.name, percentage: $0.percentage, resetTime: $0.resetTime, lastUpdated: data?.lastUpdated) }
            } else {
                let meterModels = quotaModels.filter { !$0.isStandaloneMetric }.map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, lastUpdated: data?.lastUpdated)
                }
                guard isCardStyle else { return meterModels }
                let standaloneModels = quotaModels.filter(\.isStandaloneMetric).map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, lastUpdated: data?.lastUpdated, usage: $0.formattedUsage)
                }
                return meterModels + standaloneModels
            }
        }()
        let standaloneModels = isAntigravity || isCardStyle ? [] : quotaModels.filter(\.isStandaloneMetric)
        let factorySections = provider == .factoryDroid
            ? FactoryDroidQuotaSection.sections(from: quotaModels.filter { !$0.isStandaloneMetric })
            : []
        
        return VStack(spacing: 6) {
            if models.isEmpty && standaloneModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: statusMessage == nil ? "info.circle" : "exclamationmark.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text(statusMessage ?? "dashboard.noQuotaData".localized())
                        .font(.system(size: 10, design: .rounded))
                        .lineLimit(2)
                }
                .foregroundStyle(Color.secondary.opacity(statusMessage == nil ? 0.65 : 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else if !factorySections.isEmpty {
                ForEach(factorySections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        FactoryDroidMenuSectionHeader(title: section.title)
                        quotaLayout(models: section.models.map {
                            ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, lastUpdated: data?.lastUpdated)
                        })
                    }
                }
            } else if !models.isEmpty {
                quotaLayout(models: models)
            }
            if let statusMessage, data != nil, !(models.isEmpty && standaloneModels.isEmpty) {
                Label(statusMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(standaloneModels) { model in
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.formattedUsage ?? "—")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 2)
                .menuNativeTooltip(model.tooltip ?? "")
            }
        }
    }

    @ViewBuilder
    private func quotaLayout(models: [ModelBadgeData]) -> some View {
        switch settings.quotaDisplayStyle {
        case .lowestBar:
            LowestBarLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .ring:
            RingGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .card:
            CardGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        }
    }
    
    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }
    
    private var primaryResetModel: QuotaMetric? {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        
        let validModels = quotaModels.filter { model in
            guard let date = formatter.date(from: model.resetTime) else { return false }
            return date > now
        }
        
        return validModels.sorted { m1, m2 in
            if abs(m1.percentage - m2.percentage) > 0.1 {
                return m1.percentage < m2.percentage
            }
            let d1 = formatter.date(from: m1.resetTime) ?? Date.distantFuture
            let d2 = formatter.date(from: m2.resetTime) ?? Date.distantFuture
            return d1 < d2
        }.first
    }
    
    private func formatLocalTime(_ isoString: String) -> String {
        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: isoString)
              ?? isoFormatterStandard.date(from: isoString) else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct FactoryDroidMenuSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct AnalyticsDetailSection: View {
    let analytics: QuotaAnalytics

    @State private var trendMode: AnalyticsTrendMode = .daily

    private static let primaryMetricRowIDs = [
        "codex-lifetime-tokens",
        "codex-peak-daily",
        "codex-longest-task",
        "codex-current-streak",
        "codex-longest-streak"
    ]

    private static let usageMetricRowIDs = [
        "codex-extra-usage",
        "today",
        "yesterday",
        "last-30-days"
    ]

    private static let hiddenRowIDs = Set(primaryMetricRowIDs + usageMetricRowIDs)
    private static let resetCreditsSummaryID = "codex-rate-limit-resets"
    private static let resetCreditRowPrefix = "codex-rate-limit-reset-"

    private var metricRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.primaryMetricRowIDs)
    }

    private var usageRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.usageMetricRowIDs)
    }

    private var shouldShowNote: Bool {
        metricRows.isEmpty && usageRows.isEmpty && resetCreditsSummary == nil
    }

    private func metricRows(for ids: [String]) -> [QuotaAnalyticsRow] {
        let rowsByID = analytics.rows.reduce(into: [String: QuotaAnalyticsRow]()) { result, row in
            result[row.id] = result[row.id] ?? row
        }
        return ids.compactMap { rowsByID[$0] }
    }

    private var detailRows: [QuotaAnalyticsRow] {
        analytics.rows.filter {
            !Self.hiddenRowIDs.contains($0.id)
                && $0.id != Self.resetCreditsSummaryID
                && !$0.id.hasPrefix(Self.resetCreditRowPrefix)
        }
    }

    private var resetCreditsSummary: QuotaAnalyticsRow? {
        analytics.rows.first { $0.id == Self.resetCreditsSummaryID }
    }

    private var resetCreditRows: [QuotaAnalyticsRow] {
        analytics.rows.filter { $0.id.hasPrefix(Self.resetCreditRowPrefix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !metricRows.isEmpty {
                AnalyticsMetricStripView(rows: metricRows)
            }

            if !usageRows.isEmpty {
                AnalyticsMetricStripView(rows: usageRows)
            }

            if let resetCreditsSummary {
                ResetCreditsInventoryView(summary: resetCreditsSummary, credits: resetCreditRows)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Usage Trend")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Spacer()

                    if analytics.trend.isEmpty {
                        Text("No data")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        AnalyticsTrendModePicker(selection: $trendMode)
                    }
                }

                if !analytics.trend.isEmpty {
                    UsageTrendHeatmap(points: analytics.trend, mode: trendMode)
                        .id(trendMode)
                }
            }

            ForEach(detailRows) { row in
                AnalyticsRowView(row: row)
            }

            if shouldShowNote, let note = analytics.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }
}

private struct ResetCreditsInventoryView: View {
    let summary: QuotaAnalyticsRow
    let credits: [QuotaAnalyticsRow]

    private var countLabel: String {
        let count = summary.value.split(separator: " ").first.map(String.init) ?? "0"
        return "\(count) resets available"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text(countLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                    ResetCreditChip(
                        label: compactRelativeLabel(credit.value),
                        tooltip: creditTooltip(credit),
                        isNext: index == 0
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func compactRelativeLabel(_ value: String) -> String {
        let lowercased = value.lowercased()
        let parts = lowercased.split(separator: " ")
        guard parts.count >= 3, parts.first == "in", let number = parts.dropFirst().first else {
            return value.isEmpty ? "∞" : value
        }

        let unit = parts.dropFirst(2).first ?? ""
        if unit.hasPrefix("day") { return "\(number)d" }
        if unit.hasPrefix("hour") { return "\(number)h" }
        if unit.hasPrefix("minute") { return "\(number)m" }
        return String(number)
    }

    private func creditTooltip(_ credit: QuotaAnalyticsRow) -> String {
        let suffix = credit.value.isEmpty ? "" : " - \(credit.value)"
        return "Expires: \(credit.title)\(suffix)"
    }
}

private struct ResetCreditChip: View {
    let label: String
    let tooltip: String
    let isNext: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(isNext ? Color.blue : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isNext ? Color.blue.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .contentShape(Capsule(style: .continuous))
            .menuNativeTooltip(tooltip)
    }
}

private struct AnalyticsMetricStripView: View {
    let rows: [QuotaAnalyticsRow]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AnalyticsMetricTileView(row: row)
                    .frame(maxWidth: .infinity)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(.separator.opacity(0.45))
                        .frame(width: 1, height: 34)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct AnalyticsMetricTileView: View {
    let row: QuotaAnalyticsRow

    private var displayValue: String {
        switch row.id {
        case "codex-lifetime-tokens", "codex-peak-daily":
            row.value.replacingOccurrences(of: " tokens", with: "")
        default:
            row.value
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(row.title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(minWidth: 82)
    }
}

private enum AnalyticsTrendMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .cumulative: "Cumulative"
        }
    }
}

private struct AnalyticsTrendModePicker: View {
    @Binding var selection: AnalyticsTrendMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalyticsTrendMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(selection == mode ? .primary : .tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum AnalyticsTrendSeries {
    typealias ParsedPoint = (date: Date, point: QuotaAnalyticsPoint)

    static func dailyPoints(from points: [QuotaAnalyticsPoint]) -> [QuotaAnalyticsPoint] {
        parsedPoints(from: points).map { item in
            QuotaAnalyticsPoint(
                date: dayLabel(for: item.date),
                value: item.point.value,
                label: "on \(shortDateLabel(for: item.date))",
                valueLabel: item.point.valueLabel.isEmpty ? tokenLabel(item.point.value) : item.point.valueLabel
            )
        }
    }

    static func weeklyBuckets(from points: [QuotaAnalyticsPoint], mode: AnalyticsTrendMode) -> [AnalyticsTrendBucket] {
        let parsed = parsedPoints(from: points)
        let grouped = Dictionary(grouping: parsed) { item in
            startOfWeek(containing: item.date)
        }
        switch mode {
        case .daily, .weekly:
            return grouped.keys.sorted().map { weekStart in
                let weeklyValue = grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                return AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: weeklyValue,
                    valueLabel: tokenLabel(weeklyValue),
                    tooltipLabel: "on week of \(longDateLabel(for: weekStart))"
                )
            }
        case .cumulative:
            let sortedWeeks = grouped.keys.sorted()
            guard let first = sortedWeeks.first, let last = sortedWeeks.last else {
                return []
            }

            var buckets: [AnalyticsTrendBucket] = []
            var runningTotal = 0.0
            var weekStart = first

            while weekStart <= last {
                runningTotal += grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                buckets.append(AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: runningTotal,
                    valueLabel: tokenLabel(runningTotal),
                    tooltipLabel: "through week of \(longDateLabel(for: weekStart))"
                ))

                guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                    break
                }
                weekStart = nextWeek
            }

            return buckets
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    static func dayLabel(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "Unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parsedPoints(from points: [QuotaAnalyticsPoint]) -> [ParsedPoint] {
        points.compactMap { point in
            guard let date = date(from: point.date) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private static func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private static func date(from string: String) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func longDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func tokenLabel(_ value: Double) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000_000 {
            return "\(compactNumber(value / 1_000_000_000))B tokens"
        }
        if absoluteValue >= 1_000_000 {
            return "\(compactNumber(value / 1_000_000))M tokens"
        }
        if absoluteValue >= 1_000 {
            return "\(compactNumber(value / 1_000))K tokens"
        }
        return "\(Int(value.rounded())) tokens"
    }

    private static func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

private struct AnalyticsTrendBucket: Identifiable {
    var id: String { AnalyticsTrendSeries.dayLabel(for: weekStart) }
    let weekStart: Date
    let value: Double
    let valueLabel: String
    let tooltipLabel: String
}

private struct UsageTrendHeatmap: View {
    let points: [QuotaAnalyticsPoint]
    let mode: AnalyticsTrendMode

    @State private var hoveredCellID: String?
    @State private var hoveredText: String?

    private let cellSize: CGFloat = 9
    private let spacing: CGFloat = 2.4

    private var calendar: Calendar {
        AnalyticsTrendSeries.calendar
    }

    private var parsedPoints: [(date: Date, point: QuotaAnalyticsPoint)] {
        AnalyticsTrendSeries.dailyPoints(from: points).compactMap { point in
            guard let date = Self.date(from: point.date, calendar: calendar) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private var heatmapData: HeatmapData {
        switch mode {
        case .daily:
            dailyHeatmapData()
        case .weekly, .cumulative:
            weeklyHeatmapData()
        }
    }

    private func dailyHeatmapData() -> HeatmapData {
        let parsed = parsedPoints
        guard let last = parsed.last?.date else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let pointByDate = parsed.reduce(into: [Date: QuotaAnalyticsPoint]()) { result, item in
            result[item.date] = item.point
        }
        let maxValue = max(parsed.map(\.point.value).max() ?? 0, 1)
        let first = displayStartDate(endingAt: last)
        let start = startOfWeek(containing: first)
        let days = max(calendar.dateComponents([.day], from: start, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let cells = (0..<7).map { weekdayIndex -> HeatmapCell in
                let dayOffset = weekIndex * 7 + weekdayIndex
                let date = calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
                let point = pointByDate[date]
                let intensity = point.map { point in
                    point.value <= 0 ? 0 : max(0.18, min(point.value / maxValue, 1))
                } ?? 0
                let isInRange = date >= first && date <= last
                return HeatmapCell(
                    id: "\(weekIndex)-\(weekdayIndex)",
                    date: date,
                    point: point,
                    intensity: intensity,
                    isInRange: isInRange
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: start, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    private func weeklyHeatmapData() -> HeatmapData {
        let buckets = AnalyticsTrendSeries.weeklyBuckets(from: points, mode: mode)
        guard let last = buckets.last?.weekStart else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let bucketByWeek = buckets.reduce(into: [Date: AnalyticsTrendBucket]()) { result, bucket in
            result[bucket.weekStart] = bucket
        }
        let maxValue = max(buckets.map(\.value).max() ?? 0, 1)
        let first = startOfWeek(containing: displayStartDate(endingAt: last))
        let days = max(calendar.dateComponents([.day], from: first, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let weekStart = calendar.date(byAdding: .day, value: weekIndex * 7, to: first) ?? first
            let bucket = bucketByWeek[weekStart]
            let normalizedValue = bucket.map { $0.value <= 0 ? 0 : max(0.14, min($0.value / maxValue, 1)) } ?? 0
            let filledRows = normalizedValue <= 0 ? 0 : max(1, min(Int((normalizedValue * 7).rounded(.up)), 7))

            let cells = (0..<7).map { rowIndex -> HeatmapCell in
                let isFilled = rowIndex >= 7 - filledRows
                let point = bucket.map { bucket -> QuotaAnalyticsPoint in
                    QuotaAnalyticsPoint(
                        date: AnalyticsTrendSeries.dayLabel(for: weekStart),
                        value: bucket.value,
                        label: bucket.tooltipLabel,
                        valueLabel: bucket.valueLabel
                    )
                }

                return HeatmapCell(
                    id: "\(weekIndex)-\(rowIndex)",
                    date: weekStart,
                    point: isFilled ? point : nil,
                    intensity: isFilled ? normalizedValue : 0,
                    isInRange: true
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: first, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    var body: some View {
        let data = heatmapData

        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(data.monthLabels) { label in
                        Text(label.title)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: monthLabelWidth(for: label, in: data), alignment: .leading)
                    }
                }
                .frame(width: data.width, height: 12, alignment: .leading)

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(data.weeks) { week in
                        VStack(spacing: spacing) {
                            ForEach(week.cells) { cell in
                                heatmapCell(cell)
                            }
                        }
                    }
                }
                .frame(width: data.width, alignment: .leading)
            }

            if let hoveredText {
                Text(hoveredText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .offset(y: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func heatmapCell(_ cell: HeatmapCell) -> some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .fill(fillColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .opacity(cell.isInRange ? 1 : 0)
            .overlay {
                if hoveredCellID == cell.id, cell.point != nil {
                    RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .onHover { hovering in
                updateHover(hovering, cell: cell)
            }
    }

    private func fillColor(for cell: HeatmapCell) -> Color {
        guard cell.intensity > 0 else {
            return Color.primary.opacity(0.06)
        }
        return Color.accentColor.opacity(0.16 + cell.intensity * 0.78)
    }

    private func updateHover(_ hovering: Bool, cell: HeatmapCell) {
        guard let point = cell.point else {
            if !hovering, hoveredCellID == cell.id {
                hoveredCellID = nil
                hoveredText = nil
            }
            return
        }

        if hovering {
            hoveredCellID = cell.id
            hoveredText = point.label.isEmpty
                ? "\(point.valueLabel) on \(Self.shortDateLabel(for: cell.date))"
                : "\(point.valueLabel) \(point.label)"
        } else if hoveredCellID == cell.id {
            hoveredCellID = nil
            hoveredText = nil
        }
    }

    private func monthLabelWidth(for label: MonthLabel, in data: HeatmapData) -> CGFloat {
        guard let index = data.monthLabels.firstIndex(where: { $0.id == label.id }) else {
            return 0
        }
        let nextColumn = data.monthLabels.dropFirst(index + 1).first?.column ?? data.weeks.count
        let columns = max(nextColumn - label.column, 1)
        return CGFloat(columns) * cellSize + CGFloat(max(columns - 1, 0)) * spacing
    }

    private func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private func displayStartDate(endingAt date: Date) -> Date {
        calendar.date(byAdding: .day, value: -370, to: date)
            .map { calendar.startOfDay(for: $0) } ?? date
    }

    private func monthLabels(from start: Date, first: Date, last: Date, weekCount: Int) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        var components = calendar.dateComponents([.year, .month], from: first)
        components.day = 1
        var monthStart = calendar.date(from: components) ?? first
        if monthStart < first {
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? first
        }

        while monthStart <= last {
            let column = max(calendar.dateComponents([.day], from: start, to: monthStart).day ?? 0, 0) / 7
            if column < weekCount {
                labels.append(MonthLabel(
                    id: AnalyticsTrendSeries.dayLabel(for: monthStart),
                    title: formatter.string(from: monthStart),
                    column: column
                ))
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
            monthStart = nextMonth
        }
        return labels
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private struct HeatmapData {
        let weeks: [HeatmapWeek]
        let monthLabels: [MonthLabel]
        let width: CGFloat
    }

    private struct HeatmapWeek: Identifiable {
        let id: Int
        let cells: [HeatmapCell]
    }

    private struct HeatmapCell: Identifiable {
        let id: String
        let date: Date
        let point: QuotaAnalyticsPoint?
        let intensity: Double
        let isInRange: Bool
    }

    private struct MonthLabel: Identifiable {
        let id: String
        let title: String
        let column: Int
    }
}

private struct AnalyticsRowView: View {
    let row: QuotaAnalyticsRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }
}

private struct ModelBadgeData: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?
    let lastUpdated: Date?
    let usage: String?

    init(
        name: String,
        percentage: Double,
        resetTime: String?,
        lastUpdated: Date? = nil,
        usage: String? = nil
    ) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.lastUpdated = lastUpdated
        self.usage = usage
    }

    var id: String { name }

    var resetState: QuotaResetState {
        QuotaResetState.evaluate(resetTime: resetTime ?? "", lastUpdated: lastUpdated)
    }

    /// Countdown until the window resets, or nil when unknown or already passed.
    var formattedResetTime: String? {
        guard case .upcoming = resetState else { return nil }
        return resetState.compactLabel
    }
}

/// Reset countdown, or an explicit note that the window reset after this quota was
/// fetched. Hiding a passed reset made week-old usage look current.
private struct MenuResetLabel: View {
    let model: ModelBadgeData
    var fontSize: CGFloat = 9
    var showsIcon = true

    var body: some View {
        switch model.resetState {
        case .upcoming:
            if let label = model.resetState.compactLabel {
                HStack(spacing: 3) {
                    if showsIcon {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: fontSize - 1, weight: .medium))
                    }
                    Text(label)
                        .font(.system(size: fontSize, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }
        case .passedSinceFetch:
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: fontSize - 1, weight: .medium))
                Text("quota.reset.passed".localized())
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.orange)
            .help("quota.reset.passedHelp".localized())
        case .unknown:
            EmptyView()
        }
    }
}

private struct AntigravityDisplayGroup: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?

    var id: String { name }
}

private func menuDisplayPercent(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Double {
    displayMode.displayValue(from: remainingPercent)
}

/// Formatted percentage for menu rows. A negative remaining percentage means
/// "no data yet" and renders as a placeholder instead of a fake value like 101%.
private func menuPercentText(remainingPercent: Double, displayMode: QuotaDisplayMode) -> String {
    guard remainingPercent >= 0 else { return "—" }
    return "\(Int(menuDisplayPercent(remainingPercent: remainingPercent, displayMode: displayMode)))%"
}

/// System green is too light for small text on the light menu background; use a darker
/// tone there while keeping the vivid one in dark mode.
private let menuHealthyGreen = Color(nsColor: NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark
        ? NSColor(srgbRed: 0.29, green: 0.82, blue: 0.43, alpha: 1)
        : NSColor(srgbRed: 0.03, green: 0.32, blue: 0.15, alpha: 1)
})

private func menuStatusColor(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Color {
    guard remainingPercent.isFinite, (0...100).contains(remainingPercent) else { return .secondary }
    let usedPercent = 100 - remainingPercent
    let checkValue = displayMode == .used ? usedPercent : remainingPercent

    if displayMode == .used {
        if checkValue < 70 { return menuHealthyGreen }
        if checkValue < 90 { return .yellow }
        return .red
    } else {
        if checkValue > 50 { return menuHealthyGreen }
        if checkValue > 20 { return .orange }
        return .red
    }
}

// MARK: - Layout Subviews

private struct LowestBarLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var sorted: [ModelBadgeData] {
        models.sorted { $0.percentage < $1.percentage }
    }

    private var lowest: ModelBadgeData? {
        sorted.first
    }

    private var others: [ModelBadgeData] {
        Array(sorted.dropFirst())
    }

    var body: some View {
        VStack(spacing: 6) {
            if let lowest = lowest {
                // Hero Row for Lowest with reset time
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lowest.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                        PercentageBadge(
                            percentage: lowest.percentage,
                            displayMode: displayMode,
                            style: .textOnly
                        )
                    }

                    ModernProgressBar(
                        percentage: lowest.percentage,
                        height: 5,
                        displayMode: displayMode
                    )

                    MenuResetLabel(model: lowest)
                }
            }

            // Others as text rows (one per line)
            if !others.isEmpty {
                VStack(spacing: 3) {
                    ForEach(others, id: \.name) { (model: ModelBadgeData) in
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            MenuResetLabel(model: model, showsIcon: false)
                            Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }
}

private struct RingGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var columnCount: Int {
        min(max(models.count, 1), 4)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: columnCount)
    }

    private var ringSize: CGFloat {
        columnCount >= 4 ? 32 : 36
    }

    var body: some View {
        // Auto-distribute 1-4 columns, cap at 4
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(spacing: 3) {
                    RingProgressView(percent: menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode), size: ringSize, lineWidth: 4, tint: menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode), showLabel: true)

                    Text(model.name)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    MenuResetLabel(model: model, fontSize: 8, showsIcon: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CardGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            ForEach(0..<((models.count + 2) / 3), id: \.self) { row in
                GridRow(alignment: .top) {
                    ForEach(row * 3..<min(row * 3 + 3, models.count), id: \.self) { index in
                        let model = models[index]
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(model.name)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 2)
                                if let usage = model.usage {
                                    Text(usage)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                } else {
                                    Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                                }
                            }

                            if model.usage == nil {
                                ModernProgressBar(
                                    percentage: model.percentage,
                                    height: 3,
                                    displayMode: displayMode
                                )
                            }

                            MenuResetLabel(model: model, fontSize: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .menuNativeTooltip(model.name)
                    }
                }
            }
        }
    }
}

// MARK: - Shared Components

private struct ModernProgressBar: View {
    let percentage: Double
    let height: CGFloat
    let displayMode: QuotaDisplayMode
    
    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: displayMode)
    }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: displayMode)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0, displayPercent / 100)))
            }
        }
        .frame(height: height)
    }
}

private struct PercentageBadge: View {
    let percentage: Double
    let displayMode: QuotaDisplayMode
    var style: Style = .pill
    
    enum Style { case pill, textOnly }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: displayMode)
    }

    private var displayText: String {
        menuPercentText(remainingPercent: percentage, displayMode: displayMode)
    }

    var body: some View {
        switch style {
        case .pill:
            Text(displayText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        case .textOnly:
            Text(displayText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: Model Detail View (for submenu)

private struct MenuModelDetailView: View {
    let model: QuotaMetric
    let showRawName: Bool
    let settings: StatusBarMenuDisplaySettings

    private var statusColor: Color {
        menuStatusColor(remainingPercent: model.percentage, displayMode: settings.quotaDisplayMode)
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayStyle = settings.quotaDisplayStyle
        let displayPercent = menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)

        HStack(spacing: 8) {
            Text(showRawName ? model.name : model.displayName)
                .font(.system(size: 11, weight: .medium, design: showRawName ? .monospaced : .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let usage = model.formattedUsage {
                Text(usage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle != .ring {
                Text(displayPercent >= 0
                    ? String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized())
                    : "—")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            if !model.isStandaloneMetric && model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                Text(model.formattedResetTime)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle == .ring {
                if RingProgressView.isUnknown(displayPercent) {
                    // A 14pt ring has no room for a label, so replace it with the
                    // same placeholder the other display styles render.
                    Text("—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel("usage.ring".localized())
                        .accessibilityValue("quota.noDataYet".localized())
                } else {
                    RingProgressView(percent: displayPercent, size: 14, lineWidth: 2, tint: statusColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: Empty State View

private struct MenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("menubar.noData".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }
}

// MARK: View More Accounts

private struct MenuViewMoreAccountsView: View {
    let remainingCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)

                Text(isExpanded ? "menubar.hideAccounts".localized() : "menubar.viewMoreAccounts".localized())
                    .font(.system(size: 12, weight: .medium))

                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                        .opacity(isExpanded ? 0 : 1)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
}

// MARK: - QuotaProvider Extension

private extension QuotaProvider {
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .qwen: return "Qwen"
        case .iflow: return "iFlow"
        case .vertex: return "Vertex"
        case .kiro: return "Kiro"
        case .factoryDroid: return "Factory Droid"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .amp: return "Amp"
        case .glm: return "Z.ai"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .warp: return "Warp"
        case .clinePass: return "ClinePass"
        }
    }
}

// MARK: - Menu Actions View

private struct MenuActionsView: View {
    let isLoading: Bool
    let onRefresh: () -> Void
    let onOpenApp: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(
                icon: "arrow.clockwise",
                title: "action.refresh".localized(),
                isLoading: isLoading,
                action: onRefresh
            )
            .disabled(isLoading)
            
            MenuBarActionButton(
                icon: "macwindow",
                title: "action.openApp".localized(),
                action: onOpenApp
            )
            
            Divider()
                .padding(.vertical, 4)
            
            MenuBarActionButton(
                icon: "xmark.circle",
                title: "action.quit".localized(),
                action: onQuit
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if isLoading {
                    SmallProgressView(size: 12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
    }
}
