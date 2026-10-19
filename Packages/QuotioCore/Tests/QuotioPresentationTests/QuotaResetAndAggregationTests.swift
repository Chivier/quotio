import Foundation
import QuotioDomain
import XCTest

@testable import QuotioPresentation

final class QuotaResetAndAggregationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testUpcomingResetHasCompactCountdown() {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 86_400 + 60))
        let state = QuotaResetState.evaluate(resetTime: reset, lastUpdated: now, now: now)
        XCTAssertEqual(state.compactLabel, "5d0h")
    }

    func testResetThatPassedAfterTheFetchIsExplicit() {
        // Fetched two weeks ago; the weekly window reset five days ago.
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 86_400))
        let state = QuotaResetState.evaluate(
            resetTime: reset,
            lastUpdated: now.addingTimeInterval(-14 * 86_400),
            now: now
        )
        XCTAssertEqual(state, .passedSinceFetch)
        XCTAssertNil(state.compactLabel)
    }

    func testPastResetFromAFetchMadeAfterItIsNotAWindowReset() {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let state = QuotaResetState.evaluate(resetTime: reset, lastUpdated: now, now: now)
        XCTAssertEqual(state, .unknown)
    }

    func testAggregationIgnoresUnknownAndOutOfRangeValues() {
        XCTAssertEqual(ModelAggregationMode.average.aggregate([40, 60, -1, .nan, 140]), 50)
        XCTAssertEqual(ModelAggregationMode.lowest.aggregate([40, 60, -1]), 40)
        XCTAssertNil(ModelAggregationMode.average.aggregate([-1]))
    }

    func testRemainingDisplayNeverOverstatesAFraction() {
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 74.9), 74)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 74.9), 26)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: -1), -1)
    }

    func testPairsIgnoreAmountMetricsAndHonorAggregation() throws {
        let models = [
            QuotaMetric(name: "seven-day-weekly", percentage: 20, resetTime: ""),
            QuotaMetric(name: "seven-day-sonnet", percentage: 80, resetTime: ""),
            QuotaMetric(
                name: "five-hour-session",
                percentage: -1,
                resetTime: "",
                presentation: .amount(value: 5, unit: .usd, semantics: .balance)
            ),
        ]
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .claude, from: models, aggregationMode: .average))
        XCTAssertEqual(pair.bottom.remainingPercentage, 50)
        XCTAssertEqual(pair.top.remainingPercentage, -1)
    }
}
