import XCTest
@testable import Quotio

@MainActor
final class DashboardQuotaSummaryTests: XCTestCase {
    func testAccountCountUsesTrackedAccountsWhenSomeQuotasAreMissing() {
        XCTAssertEqual(
            QuotaOverviewSummary.accountCount(tracked: 2, withQuota: 1),
            2
        )
    }

    func testAccountCountFallsBackToQuotaRowsBeforeDiscoveryCompletes() {
        XCTAssertEqual(
            QuotaOverviewSummary.accountCount(tracked: 0, withQuota: 2),
            2
        )
    }

    func testDefaultSummaryAveragesExhaustedAndFullModelQuotas() {
        withSettings { settings, _ in
            let quota = ProviderQuotaData(models: [
                ModelQuota(name: "first", percentage: 0, resetTime: ""),
                ModelQuota(name: "second", percentage: 100, resetTime: ""),
            ])

            XCTAssertEqual(settings.totalUsagePercent(for: quota), 50)
        }
    }

    func testProviderSummaryGivesEachAccountEqualWeight() {
        withSettings { settings, _ in
            let accounts = [
                ProviderQuotaData(models: [
                    ModelQuota(name: "first", percentage: 0, resetTime: ""),
                    ModelQuota(name: "second", percentage: 100, resetTime: ""),
                ]),
                ProviderQuotaData(models: [
                    ModelQuota(name: "only", percentage: 100, resetTime: ""),
                ]),
            ]

            XCTAssertEqual(settings.summaryUsagePercent(for: accounts), 75)
            settings.modelAggregationMode = .lowest
            XCTAssertEqual(settings.summaryUsagePercent(for: accounts), 0)
        }
    }

    func testExplicitLowestSelectionSurvivesSettingsReload() {
        withSettings { settings, defaults in
            settings.modelAggregationMode = .lowest
            defaults.register(defaults: ["modelAggregationMode": ModelAggregationMode.average.rawValue])
            let restored = MenuBarSettingsManager(defaults: defaults)
            let quota = ProviderQuotaData(models: [
                ModelQuota(name: "first", percentage: 0, resetTime: ""),
                ModelQuota(name: "second", percentage: 100, resetTime: ""),
            ])

            XCTAssertEqual(restored.totalUsagePercent(for: quota), 0)
        }
    }

    func testSummaryExcludesForbiddenStandaloneAndInvalidQuotaData() {
        withSettings { settings, _ in
            let validQuota = ProviderQuotaData(models: [
                ModelQuota(name: "grok-weekly", percentage: 75, resetTime: ""),
                ModelQuota(name: "grok-extra-usage", percentage: 0, resetTime: "", presentation: .status(text: "Disabled")),
                ModelQuota(name: "unknown", percentage: -1, resetTime: ""),
                ModelQuota(name: "out-of-range", percentage: 101, resetTime: ""),
                ModelQuota(name: "nan", percentage: .nan, resetTime: ""),
                ModelQuota(name: "infinite", percentage: .infinity, resetTime: ""),
            ])
            let forbidden = ProviderQuotaData(models: [
                ModelQuota(name: "session", percentage: 0, resetTime: ""),
            ], isForbidden: true)
            let failed = ProviderQuotaData(models: [
                ModelQuota(name: "Error", percentage: -1, resetTime: ""),
            ])

            XCTAssertEqual(settings.totalUsagePercent(for: validQuota), 75)
            XCTAssertEqual(settings.summaryUsagePercent(for: [validQuota, forbidden, failed]), 75)
        }
    }

    func testNoAvailableQuotaStaysUnknownAndDisplaysDashInBothModes() {
        withSettings { settings, _ in
            let unavailable = ProviderQuotaData(models: [
                ModelQuota(name: "unknown", percentage: -1, resetTime: ""),
                ModelQuota(name: "invalid", percentage: 101, resetTime: ""),
                ModelQuota(name: "nan", percentage: .nan, resetTime: ""),
                ModelQuota(name: "infinite", percentage: .infinity, resetTime: ""),
                ModelQuota(name: "status", percentage: 0, resetTime: "", presentation: .status(text: "Disabled")),
            ])
            let total = settings.totalUsagePercent(for: unavailable)

            XCTAssertEqual(total, -1)
            XCTAssertNil(settings.summaryUsagePercent(for: [unavailable]))
            XCTAssertNil(settings.summaryUsagePercent(for: [ProviderQuotaData]()))
            XCTAssertEqual(QuotaDisplayHelper(displayMode: .used).formattedPercent(remainingPercent: total), "—")
            XCTAssertEqual(QuotaDisplayHelper(displayMode: .remaining).formattedPercent(remainingPercent: total), "—")
        }
    }

    func testSessionExtraPolicyKeepsRealZeroAndFallsBackOnlyWhenUnavailable() {
        withSettings { settings, _ in
            let quota = ProviderQuotaData(models: [
                ModelQuota(name: "session", percentage: 0, resetTime: ""),
                ModelQuota(name: "extra-usage", percentage: 80, resetTime: ""),
            ])
            XCTAssertEqual(settings.totalUsagePercent(for: quota), 0)
            settings.totalUsageMode = .combined
            XCTAssertEqual(settings.totalUsagePercent(for: quota), 80)

            settings.totalUsageMode = .sessionOnly
            let extraOnly = ProviderQuotaData(models: [
                ModelQuota(name: "session", percentage: -1, resetTime: ""),
                ModelQuota(name: "extra-usage", percentage: 80, resetTime: ""),
            ])
            XCTAssertEqual(settings.totalUsagePercent(for: extraOnly), 80)
        }
    }

    private func withSettings(_ body: (MenuBarSettingsManager, UserDefaults) -> Void) {
        let suiteName = "DashboardQuotaSummaryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated settings")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(MenuBarSettingsManager(defaults: defaults), defaults)
    }
}
