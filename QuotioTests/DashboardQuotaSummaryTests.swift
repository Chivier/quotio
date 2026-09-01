import XCTest
@testable import Quotio

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

    func testLowestAvailablePercentageIgnoresStandaloneStatusMetrics() {
        let accounts = [
            "grok": ProviderQuotaData(models: [
                ModelQuota(name: "grok-weekly", percentage: 75, resetTime: ""),
                ModelQuota(
                    name: "grok-extra-usage",
                    percentage: -1,
                    resetTime: "",
                    presentation: .status(text: "Disabled")
                ),
            ]),
        ]

        XCTAssertEqual(
            QuotaOverviewSummary.lowestAvailablePercentage(in: accounts),
            75
        )
    }

    func testLowestAvailablePercentageReturnsNilWithoutValidPercentageData() {
        let accounts = [
            "unknown": ProviderQuotaData(models: [
                ModelQuota(name: "unknown", percentage: -1, resetTime: ""),
                ModelQuota(name: "invalid", percentage: 101, resetTime: ""),
            ]),
        ]

        XCTAssertNil(QuotaOverviewSummary.lowestAvailablePercentage(in: accounts))
    }
}
