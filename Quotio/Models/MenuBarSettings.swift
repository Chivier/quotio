//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import SwiftUI

// MARK: - Privacy String Extension

extension String {
    /// Masks sensitive information with asterisks (*)
    /// Email: `john.doe@gmail.com` → `********@*****.com`
    /// Other: `account-name` → `************`
    func masked() -> String {
        // Check if it's an email
        if self.contains("@") {
            let components = self.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let localPart = String(repeating: "*", count: min(components[0].count, 8))
                let domainParts = components[1].split(separator: ".", maxSplits: 1)
                if domainParts.count == 2 {
                    let domainName = String(repeating: "*", count: min(domainParts[0].count, 5))
                    return "\(localPart)@\(domainName).\(domainParts[1])"
                }
                return "\(localPart)@\(String(repeating: "*", count: 5))"
            }
        }
        
        // For non-email strings, mask entirely but keep reasonable length
        let maskedLength = min(self.count, 12)
        return String(repeating: "*", count: max(maskedLength, 4))
    }
    
    /// Conditionally masks the string based on a flag
    func masked(if shouldMask: Bool) -> String {
        shouldMask ? masked() : self
    }
}

// MARK: - Menu Bar Quota Item

/// Represents a single item selected for menu bar display
struct MenuBarQuotaItem: Codable, Identifiable, Hashable {
    let provider: String      // AIProvider.rawValue
    let accountKey: String    // email or account identifier
    
    var id: String { "\(provider)_\(accountKey)" }
    
    /// Get the AIProvider enum value
    var aiProvider: AIProvider? {
        // Handle "copilot" alias
        if provider == "copilot" {
            return .copilot
        }
        return AIProvider(rawValue: provider)
    }
    
    /// Short display symbol for the provider
    var providerSymbol: String {
        aiProvider?.menuBarSymbol ?? "?"
    }
}

// MARK: - Appearance Mode

/// Appearance mode for the app (light/dark/system)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()
    
    private let defaults = UserDefaults.standard
    private let appearanceModeKey = "appearanceMode"
    
    /// Current appearance mode
    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
            applyAppearance()
        }
    }
    
    private init() {
        let saved = defaults.string(forKey: appearanceModeKey) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: saved) ?? .system
    }
    
    /// Apply the current appearance mode to the app
    func applyAppearance() {
        NSApp.appearance = appearanceMode.appKitAppearance
    }
}

// MARK: - Color Mode

/// Color mode for menu bar quota display
enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable {
    case colored = "colored"       // Green/Yellow/Red based on quota %
    case monochrome = "monochrome" // White/Gray only
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .colored: return "settings.menubar.colored"
        case .monochrome: return "settings.menubar.monochrome"
        }
    }
}

// MARK: - Quota Display Mode

/// Display mode for quota percentage (used vs remaining)
enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable {
    case used = "used"           // Show percentage used (e.g., "75% used")
    case remaining = "remaining" // Show percentage remaining (e.g., "25% left")
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .used: return "settings.quota.displayMode.used"
        case .remaining: return "settings.quota.displayMode.remaining"
        }
    }
    
    /// Convert a remaining percentage to the display value based on mode.
    /// A negative input is the "no data" sentinel and is propagated as -1 so it can
    /// never surface as a fake percentage (e.g. 100 - (-1) = 101%). Valid input is
    /// clamped to 0-100 before conversion.
    func displayValue(from remainingPercent: Double) -> Double {
        guard remainingPercent >= 0 else { return -1 }
        let clamped = min(100, max(0, remainingPercent))
        switch self {
        case .used: return 100 - clamped
        case .remaining: return clamped
        }
    }
    
    var suffixKey: String {
        switch self {
        case .used: return "settings.quota.used"
        case .remaining: return "settings.quota.left"
        }
    }
}

// MARK: - Quota Display Style

/// Visual style for quota display in the main UI
enum QuotaDisplayStyle: String, Codable, CaseIterable, Identifiable {
    case card = "card"           // Default card with progress bar
    case lowestBar = "lowestBar" // Compact: lowest % bar, others text
    case ring = "ring"           // Circular progress rings

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .card: return "settings.quota.style.card"
        case .lowestBar: return "settings.quota.style.lowestBar"
        case .ring: return "settings.quota.style.ring"
        }
    }

    var iconName: String {
        switch self {
        case .card: return "rectangle.portrait"
        case .lowestBar: return "chart.bar.fill"
        case .ring: return "circle.dotted"
        }
    }
}

// MARK: - Refresh Cadence

/// Refresh cadence options for quota auto-refresh
enum RefreshCadence: String, CaseIterable, Identifiable, Codable {
    case manual = "manual"
    case oneMinute = "1min"
    case twoMinutes = "2min"
    case fiveMinutes = "5min"
    case tenMinutes = "10min"
    case fifteenMinutes = "15min"
    
    var id: String { rawValue }
    
    /// Interval in seconds (nil for manual = no auto-refresh)
    var intervalSeconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .fifteenMinutes: return 900
        }
    }
    
    /// Interval in nanoseconds for Task.sleep
    var intervalNanoseconds: UInt64? {
        guard let seconds = intervalSeconds else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
    
    var localizationKey: String {
        switch self {
        case .manual: return "settings.refresh.manual"
        case .oneMinute: return "settings.refresh.1min"
        case .twoMinutes: return "settings.refresh.2min"
        case .fiveMinutes: return "settings.refresh.5min"
        case .tenMinutes: return "settings.refresh.10min"
        case .fifteenMinutes: return "settings.refresh.15min"
        }
    }
}

// MARK: - Total Usage Calculation Mode

/// Mode for calculating total usage indicators (session vs extra)
enum TotalUsageMode: String, CaseIterable, Identifiable, Codable {
    case sessionOnly = "sessionOnly"
    case combined = "combined"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .sessionOnly: return "settings.usageDisplay.totalMode.sessionOnly"
        case .combined: return "settings.usageDisplay.totalMode.combined"
        }
    }
}

// MARK: - Model Aggregation Mode

/// Mode for aggregating multi-model provider quotas
nonisolated enum ModelAggregationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case lowest = "lowest"
    case average = "average"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .lowest: return "settings.usageDisplay.modelAggregation.lowest"
        case .average: return "settings.usageDisplay.modelAggregation.average"
        }
    }

    /// Unknown, nonfinite and out-of-range values are not quota measurements.
    func aggregate<S: Sequence>(_ percentages: S) -> Double? where S.Element == Double {
        var total = 0.0
        var count = 0
        for percentage in percentages where percentage.isFinite && (0...100).contains(percentage) {
            switch self {
            case .lowest:
                total = count == 0 ? percentage : min(total, percentage)
            case .average:
                total += percentage
            }
            count += 1
        }
        guard count > 0 else { return nil }
        return self == .average ? total / Double(count) : total
    }
}

// MARK: - Usage Calculation Helpers

extension MenuBarSettingsManager {
    /// Remaining quota for one account, preserving the selected session/extra policy.
    func totalUsagePercent(for quota: ProviderQuotaData) -> Double {
        guard !quota.isForbidden else { return -1 }
        let models = quota.models.lazy.filter { !$0.isStandaloneMetric }
        let session = modelAggregationMode.aggregate(models.filter {
            !Self.isExtraModel($0.name)
        }.map(\.percentage))
        if totalUsageMode == .sessionOnly, let session {
            return session
        }
        let extra = modelAggregationMode.aggregate(models.filter {
            Self.isExtraModel($0.name)
        }.map(\.percentage))

        switch totalUsageMode {
        case .sessionOnly:
            return session ?? extra ?? -1
        case .combined:
            if let session, let extra {
                return max(session, extra)
            }
            return session ?? extra ?? -1
        }
    }

    /// Each account contributes one total, regardless of its number of model limits.
    func summaryUsagePercent<S: Sequence>(for accounts: S) -> Double? where S.Element == ProviderQuotaData {
        modelAggregationMode.aggregate(accounts.lazy.map { self.totalUsagePercent(for: $0) })
    }

    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        modelAggregationMode.aggregate(percentages) ?? -1
    }

    private static func isExtraModel(_ name: String) -> Bool {
        name == "extra-usage" || name == "codex-extra" || name == "on-demand"
    }
}

// MARK: - Refresh Settings Manager

/// Manager for refresh cadence settings with persistence
@MainActor
@Observable
final class RefreshSettingsManager {
    static let shared = RefreshSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let refreshCadenceKey = "refreshCadence"
    
    /// Current refresh cadence
    var refreshCadence: RefreshCadence {
        didSet {
            defaults.set(refreshCadence.rawValue, forKey: refreshCadenceKey)
            onRefreshCadenceChanged?(refreshCadence)
        }
    }
    
    /// Callback when refresh cadence changes (for ViewModel to restart timer)
    var onRefreshCadenceChanged: ((RefreshCadence) -> Void)?
    
    private init() {
        let saved = defaults.string(forKey: refreshCadenceKey) ?? RefreshCadence.tenMinutes.rawValue
        self.refreshCadence = RefreshCadence(rawValue: saved) ?? .tenMinutes
    }
}

// MARK: - Menu Bar Quota Display Item

/// A semantic quota metric rendered as one row of a compact menu bar pair.
nonisolated struct MenuBarQuotaMetric: Equatable, Sendable {
    let labelKey: String
    let remainingPercentage: Double
}

/// Two related quota metrics rendered together in the compact menu bar layout.
nonisolated struct MenuBarQuotaPair: Equatable, Sendable {
    let top: MenuBarQuotaMetric
    let bottom: MenuBarQuotaMetric

    static func resolve(
        for provider: AIProvider,
        from models: [ModelQuota],
        aggregationMode: ModelAggregationMode
    ) -> MenuBarQuotaPair? {
        switch provider {
        case .claude:
            return makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["five-hour-session"],
                topLabelKey: "quota.metric.fiveHour",
                bottomNames: ["seven-day-weekly", "seven-day-sonnet", "seven-day-opus"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .codex:
            guard let pair = makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["codex-session", "codex-spark"],
                topLabelKey: "quota.metric.session",
                bottomNames: ["codex-weekly", "codex-spark-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            ), pair.top.remainingPercentage >= 0 else { return nil }
            return pair
        case .amp:
            return makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["amp-agent-usage"],
                topLabelKey: "amp.quota.agent",
                bottomNames: ["amp-orb-usage"],
                bottomLabelKey: "amp.quota.orb",
                requiresBoth: true
            )
        case .antigravity:
            return makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["antigravity-gemini-session", "antigravity-claude-gpt-session"],
                topLabelKey: "quota.metric.session",
                bottomNames: ["antigravity-gemini-weekly", "antigravity-claude-gpt-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .devin:
            return makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["devin-daily"],
                topLabelKey: "quota.metric.daily",
                bottomNames: ["devin-weekly"],
                bottomLabelKey: "quota.metric.weekly",
                requiresBoth: true
            )
        case .cursor:
            guard models.contains(where: {
                $0.name == "on-demand"
                    && ($0.limit ?? 0) > 0
                    && $0.remaining != nil
                    && !$0.isStandaloneMetric
                    && $0.percentage.isFinite
                    && (0...100).contains($0.percentage)
            }) else {
                return nil
            }
            return makePair(
                from: models,
                aggregationMode: aggregationMode,
                topNames: ["plan-usage"],
                topLabelKey: "quota.metric.planUsage",
                bottomNames: ["on-demand"],
                bottomLabelKey: "quota.metric.onDemand",
                requiresBoth: true
            )
        default:
            return nil
        }
    }

    private static func makePair(
        from models: [ModelQuota],
        aggregationMode: ModelAggregationMode,
        topNames: Set<String>,
        topLabelKey: String,
        bottomNames: Set<String>,
        bottomLabelKey: String,
        requiresBoth: Bool = false
    ) -> MenuBarQuotaPair? {
        let topPercentage = percentage(in: models, named: topNames, aggregationMode: aggregationMode)
        let bottomPercentage = percentage(in: models, named: bottomNames, aggregationMode: aggregationMode)

        if requiresBoth {
            guard topPercentage != nil, bottomPercentage != nil else { return nil }
        } else {
            guard topPercentage != nil || bottomPercentage != nil else { return nil }
        }

        return MenuBarQuotaPair(
            top: MenuBarQuotaMetric(
                labelKey: topLabelKey,
                remainingPercentage: topPercentage ?? -1
            ),
            bottom: MenuBarQuotaMetric(
                labelKey: bottomLabelKey,
                remainingPercentage: bottomPercentage ?? -1
            )
        )
    }

    private static func percentage(
        in models: [ModelQuota],
        named names: Set<String>,
        aggregationMode: ModelAggregationMode
    ) -> Double? {
        aggregationMode.aggregate(models.lazy.filter {
            names.contains($0.name) && !$0.isStandaloneMetric
        }.map(\.percentage))
    }
}

/// Data for displaying a single quota item in menu bar
struct MenuBarQuotaDisplayItem: Identifiable, Equatable {
    let id: String
    let providerSymbol: String
    let accountShort: String
    let percentage: Double
    let provider: AIProvider
    var isForbidden: Bool = false
    var quotaPair: MenuBarQuotaPair? = nil
    
    var statusColor: Color {
        statusColor(for: percentage)
    }

    func statusColor(for percentage: Double) -> Color {
        if isForbidden { return .orange }
        guard percentage.isFinite, (0...100).contains(percentage) else { return .secondary }
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
final class MenuBarSettingsManager {
    static let shared = MenuBarSettingsManager()
    
    private let defaults: UserDefaults
    private let selectedItemsKey = "menuBarSelectedQuotaItems"
    private let colorModeKey = "menuBarColorMode"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let showQuotaKey = "menuBarShowQuota"
    private let menuBarMaxItemsKey = "menuBarMaxItems"
    private let quotaDisplayModeKey = "quotaDisplayMode"
    private let quotaDisplayStyleKey = "quotaDisplayStyle"
    // Retain the key introduced by #493 so existing user preferences carry forward.
    private let stackPairedQuotaMetricsKey = "menuBarStackClaudeQuotaWindows"
    private let hideSensitiveInfoKey = "hideSensitiveInfo"
    private let totalUsageModeKey = "totalUsageMode"
    private let modelAggregationModeKey = "modelAggregationMode"
    private let hasUserModifiedMenuBarKey = "hasUserModifiedMenuBar"

    static let minMenuBarItems = 1
    static let maxMenuBarItems = 10
    static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: showMenuBarIconKey) }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    var showQuotaInMenuBar: Bool {
        didSet { defaults.set(showQuotaInMenuBar, forKey: showQuotaKey) }
    }

    /// Maximum number of items to display in menu bar
    var menuBarMaxItems: Int {
        didSet {
            defaults.set(menuBarMaxItems, forKey: menuBarMaxItemsKey)
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    var selectedItems: [MenuBarQuotaItem] {
        didSet { saveSelectedItems() }
    }
    
    /// Color mode (colored vs monochrome)
    var colorMode: MenuBarColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: colorModeKey) }
    }
    
    /// Quota display mode (used vs remaining)
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { defaults.set(quotaDisplayMode.rawValue, forKey: quotaDisplayModeKey) }
    }
    
    /// Visual style for quota display
    var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { defaults.set(quotaDisplayStyle.rawValue, forKey: quotaDisplayStyleKey) }
    }

    /// Whether providers with a stable metric pair use the compact stacked layout.
    var stackPairedQuotaMetrics: Bool {
        didSet { defaults.set(stackPairedQuotaMetrics, forKey: stackPairedQuotaMetricsKey) }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    var hideSensitiveInfo: Bool {
        didSet { defaults.set(hideSensitiveInfo, forKey: hideSensitiveInfoKey) }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    var totalUsageMode: TotalUsageMode {
        didSet { defaults.set(totalUsageMode.rawValue, forKey: totalUsageModeKey) }
    }
    
    /// Model aggregation mode (lowest vs average)
    var modelAggregationMode: ModelAggregationMode {
        didSet { defaults.set(modelAggregationMode.rawValue, forKey: modelAggregationModeKey) }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    private(set) var hasUserModifiedMenuBar: Bool {
        didSet { defaults.set(hasUserModifiedMenuBar, forKey: hasUserModifiedMenuBarKey) }
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        return selectedItems.count >= threshold && selectedItems.count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    var isAtMaxItems: Bool {
        selectedItems.count >= menuBarMaxItems
    }
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Show menu bar icon - default true if not set
        if defaults.object(forKey: showMenuBarIconKey) == nil {
            defaults.set(true, forKey: showMenuBarIconKey)
        }
        self.showMenuBarIcon = defaults.bool(forKey: showMenuBarIconKey)
        
        // Show quota in menu bar - default true if not set
        if defaults.object(forKey: showQuotaKey) == nil {
            defaults.set(true, forKey: showQuotaKey)
        }
        self.showQuotaInMenuBar = defaults.bool(forKey: showQuotaKey)
        
        if defaults.object(forKey: menuBarMaxItemsKey) == nil {
            defaults.set(Self.defaultMenuBarMaxItems, forKey: menuBarMaxItemsKey)
        }

        self.colorMode = MenuBarColorMode(rawValue: defaults.string(forKey: colorModeKey) ?? "") ?? .colored
        self.quotaDisplayMode = QuotaDisplayMode(rawValue: defaults.string(forKey: quotaDisplayModeKey) ?? "") ?? .used
        self.quotaDisplayStyle = QuotaDisplayStyle(rawValue: defaults.string(forKey: quotaDisplayStyleKey) ?? "") ?? .card
        if defaults.object(forKey: stackPairedQuotaMetricsKey) == nil {
            defaults.set(true, forKey: stackPairedQuotaMetricsKey)
        }
        self.stackPairedQuotaMetrics = defaults.bool(forKey: stackPairedQuotaMetricsKey)
        self.selectedItems = Self.loadSelectedItems(from: defaults, key: selectedItemsKey)

        // Load and clamp menuBarMaxItems, then persist the clamped value
        let loadedMax = defaults.integer(forKey: menuBarMaxItemsKey)
        let clampedMax = Self.clampedMenuBarMax(loadedMax)
        self.menuBarMaxItems = clampedMax
        if loadedMax != clampedMax {
            defaults.set(clampedMax, forKey: menuBarMaxItemsKey)
        }

        self.hideSensitiveInfo = defaults.bool(forKey: hideSensitiveInfoKey)
        self.totalUsageMode = TotalUsageMode(rawValue: defaults.string(forKey: totalUsageModeKey) ?? "") ?? .sessionOnly
        self.modelAggregationMode = ModelAggregationMode(rawValue: defaults.string(forKey: modelAggregationModeKey) ?? "") ?? .average
        self.hasUserModifiedMenuBar = defaults.bool(forKey: hasUserModifiedMenuBarKey)

        enforceMaxItems()
    }
    
    private func saveSelectedItems() {
        if let data = try? JSONEncoder().encode(selectedItems) {
            defaults.set(data, forKey: selectedItemsKey)
        }
    }
    
    private static func loadSelectedItems(from defaults: UserDefaults, key: String) -> [MenuBarQuotaItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([MenuBarQuotaItem].self, from: data) else {
            return []
        }
        return items.filter { $0.provider != "gemini-cli" }
    }
    
    func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        guard selectedItems.count < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    /// Check if item is selected
    func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if isSelected(item) {
            selectedItems.removeAll { $0.id == item.id }
        } else {
            addItem(item)
        }
    }
    
    /// Remove items that no longer exist in quota data
    func pruneInvalidItems(validItems: [MenuBarQuotaItem]) {
        let validIds = Set(validItems.map(\.id))
        selectedItems.removeAll { !validIds.contains($0.id) }
    }
    
    func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - selectedItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    @discardableResult
    private func enforceMaxItems() -> Bool {
        guard selectedItems.count > menuBarMaxItems else { return false }
        selectedItems = Array(selectedItems.prefix(menuBarMaxItems))
        return true
    }

    private static func clampedMenuBarMax(_ value: Int) -> Int {
        min(max(value, minMenuBarItems), maxMenuBarItems)
    }
}
