import AppKit
import SwiftUI
import XCTest
@testable import Quotio

final class MenuBarQuotaPairTests: XCTestCase {
    func testClaudeUsesFiveHourAndLowestWeeklyLimit() throws {
        let models = [
            ModelQuota(name: "five-hour-session", percentage: 81, resetTime: ""),
            ModelQuota(name: "seven-day-weekly", percentage: 63, resetTime: ""),
            ModelQuota(name: "seven-day-sonnet", percentage: 12, resetTime: ""),
            ModelQuota(name: "seven-day-opus", percentage: 27, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .claude, from: models, aggregationMode: .lowest))

        XCTAssertEqual(pair.top, MenuBarQuotaMetric(labelKey: "quota.metric.fiveHour", remainingPercentage: 81))
        XCTAssertEqual(pair.bottom, MenuBarQuotaMetric(labelKey: "quota.metric.weekly", remainingPercentage: 12))
    }

    func testCodexUsesLowestStandardOrSparkLimitForEachWindow() throws {
        let models = [
            ModelQuota(name: "codex-session", percentage: 78, resetTime: ""),
            ModelQuota(name: "codex-spark", percentage: 43, resetTime: ""),
            ModelQuota(name: "codex-weekly", percentage: 51, resetTime: ""),
            ModelQuota(name: "codex-spark-weekly", percentage: 66, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .codex, from: models, aggregationMode: .lowest))

        XCTAssertEqual(pair.top.remainingPercentage, 43)
        XCTAssertEqual(pair.bottom.remainingPercentage, 51)
    }

    func testAverageKeepsSessionAndWeeklyLimitsSeparate() throws {
        let models = [
            ModelQuota(name: "codex-session", percentage: 0, resetTime: ""),
            ModelQuota(name: "codex-spark", percentage: 100, resetTime: ""),
            ModelQuota(name: "codex-weekly", percentage: 40, resetTime: ""),
            ModelQuota(name: "codex-spark-weekly", percentage: 80, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .codex, from: models, aggregationMode: .average))

        XCTAssertEqual(pair.top.remainingPercentage, 50)
        XCTAssertEqual(pair.bottom.remainingPercentage, 60)
    }

    func testAmpUsesAgentAndOrbUsage() throws {
        let models = [
            ModelQuota(name: "amp-agent-usage", percentage: 64, resetTime: ""),
            ModelQuota(name: "amp-orb-usage", percentage: 98, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .amp, from: models, aggregationMode: .average))

        XCTAssertEqual(pair.top, MenuBarQuotaMetric(labelKey: "amp.quota.agent", remainingPercentage: 64))
        XCTAssertEqual(pair.bottom, MenuBarQuotaMetric(labelKey: "amp.quota.orb", remainingPercentage: 98))
    }

    func testAmpWithOneMetricDoesNotUseStackedLayout() {
        let models = [
            ModelQuota(name: "amp-agent-usage", percentage: 64, resetTime: ""),
        ]

        XCTAssertNil(MenuBarQuotaPair.resolve(for: .amp, from: models, aggregationMode: .average))
    }

    func testAntigravityUsesLowestProviderLimitForEachWindow() throws {
        let models = [
            ModelQuota(name: "antigravity-gemini-session", percentage: 72, resetTime: ""),
            ModelQuota(name: "antigravity-gemini-weekly", percentage: 55, resetTime: ""),
            ModelQuota(name: "antigravity-claude-gpt-session", percentage: 31, resetTime: ""),
            ModelQuota(name: "antigravity-claude-gpt-weekly", percentage: 67, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models, aggregationMode: .lowest))

        XCTAssertEqual(pair.top.remainingPercentage, 31)
        XCTAssertEqual(pair.bottom.remainingPercentage, 55)
    }

    func testDevinUsesDailyAndWeeklyUsage() throws {
        let models = [
            ModelQuota(name: "devin-daily", percentage: 84, resetTime: ""),
            ModelQuota(name: "devin-weekly", percentage: 49, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .devin, from: models, aggregationMode: .average))

        XCTAssertEqual(pair.top, MenuBarQuotaMetric(labelKey: "quota.metric.daily", remainingPercentage: 84))
        XCTAssertEqual(pair.bottom, MenuBarQuotaMetric(labelKey: "quota.metric.weekly", remainingPercentage: 49))
    }

    func testDevinWithoutDailyDoesNotUseStackedLayout() {
        let models = [
            ModelQuota(name: "devin-weekly", percentage: 49, resetTime: ""),
        ]

        XCTAssertNil(MenuBarQuotaPair.resolve(for: .devin, from: models, aggregationMode: .average))
    }

    func testCursorRequiresBoundedOnDemandUsage() throws {
        let models = [
            ModelQuota(name: "plan-usage", percentage: 80, resetTime: "", used: 20, limit: 100, remaining: 80),
            ModelQuota(name: "on-demand", percentage: 25, resetTime: "", used: 75, limit: 100, remaining: 25),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .cursor, from: models, aggregationMode: .average))

        XCTAssertEqual(pair.top, MenuBarQuotaMetric(labelKey: "quota.metric.planUsage", remainingPercentage: 80))
        XCTAssertEqual(pair.bottom, MenuBarQuotaMetric(labelKey: "quota.metric.onDemand", remainingPercentage: 25))
        XCTAssertNil(MenuBarQuotaPair.resolve(for: .cursor, from: Array(models.prefix(1)), aggregationMode: .average))

        let unboundedModels = [
            models[0],
            ModelQuota(name: "on-demand", percentage: 100, resetTime: "", used: 75),
        ]
        XCTAssertNil(MenuBarQuotaPair.resolve(for: .cursor, from: unboundedModels, aggregationMode: .average))
    }

    func testCodexWithoutSessionDoesNotUseStackedLayout() {
        let models = [
            ModelQuota(name: "codex-weekly", percentage: 42, resetTime: ""),
        ]

        XCTAssertNil(MenuBarQuotaPair.resolve(for: .codex, from: models, aggregationMode: .average))
    }

    func testInvalidValuesDoNotOverrideKnownAverage() throws {
        let models = [
            ModelQuota(name: "codex-session", percentage: -1, resetTime: ""),
            ModelQuota(name: "codex-spark", percentage: 38, resetTime: ""),
            ModelQuota(name: "codex-session", percentage: 0, resetTime: "", presentation: .status(text: "Disabled")),
            ModelQuota(name: "codex-spark", percentage: .nan, resetTime: ""),
            ModelQuota(name: "codex-weekly", percentage: .infinity, resetTime: ""),
            ModelQuota(name: "codex-spark-weekly", percentage: 101, resetTime: ""),
        ]

        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .codex, from: models, aggregationMode: .average))

        XCTAssertEqual(pair.top.remainingPercentage, 38)
        XCTAssertEqual(pair.bottom.remainingPercentage, -1)
    }

    func testPairRequiresAtLeastOneAvailableWindow() {
        let unavailable = [
            ModelQuota(name: "five-hour-session", percentage: -1, resetTime: ""),
            ModelQuota(name: "seven-day-weekly", percentage: .nan, resetTime: ""),
        ]
        XCTAssertNil(MenuBarQuotaPair.resolve(for: .claude, from: unavailable, aggregationMode: .average))
    }

    func testUnsupportedProviderDoesNotResolvePair() {
        let models = [ModelQuota(name: "copilot-chat", percentage: 70, resetTime: "")]

        XCTAssertNil(MenuBarQuotaPair.resolve(for: .copilot, from: models, aggregationMode: .average))
    }

    @MainActor
    func testAccessibilityUsesDisplayModeAndLocalizedUnknownValue() {
        let known = MenuBarQuotaMetric(labelKey: "quota.metric.weekly", remainingPercentage: 25)
        let unknown = MenuBarQuotaMetric(labelKey: "quota.metric.weekly", remainingPercentage: -1)

        XCTAssertEqual(
            StatusBarQuotaItemView.accessibilityValue(for: known, displayMode: .remaining),
            String(format: "%lld percent".localized(), Int64(25))
        )
        XCTAssertEqual(
            StatusBarQuotaItemView.accessibilityValue(for: known, displayMode: .used),
            String(format: "%lld percent".localized(), Int64(75))
        )
        XCTAssertEqual(
            StatusBarQuotaItemView.accessibilityValue(for: unknown, displayMode: .used),
            "quota.noDataYet".localized()
        )
    }

    @MainActor
    func testCompactQuotaPairViewFitsMenuBarHeight() {
        let item = MenuBarQuotaDisplayItem(
            id: "codex-test",
            providerSymbol: "O",
            accountShort: "test",
            percentage: 63,
            provider: .codex,
            quotaPair: MenuBarQuotaPair(
                top: MenuBarQuotaMetric(labelKey: "quota.metric.session", remainingPercentage: 81),
                bottom: MenuBarQuotaMetric(labelKey: "quota.metric.weekly", remainingPercentage: 63)
            )
        )
        let hostingView = NSHostingView(
            rootView: StatusBarQuotaItemView(item: item, colorMode: .monochrome)
        )

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 22)
        XCTAssertLessThan(hostingView.fittingSize.width, 40)
    }
}
