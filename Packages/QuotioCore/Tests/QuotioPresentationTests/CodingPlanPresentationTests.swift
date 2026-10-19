import Foundation
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class CodingPlanPresentationTests: XCTestCase {
    func testCodingPlansPairFiveHourOverWeeklyInTheMenuBar() throws {
        for provider in [QuotaProvider.kimi, .minimax] {
            let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: provider, from: [
                QuotaMetric(name: "\(provider.rawValue)-weekly", percentage: 80, resetTime: ""),
                QuotaMetric(name: "\(provider.rawValue)-five-hour", percentage: 30, resetTime: ""),
            ]))
            XCTAssertEqual(pair.top.labelKey, "quota.metric.session")
            XCTAssertEqual(pair.top.remainingPercentage, 30)
            XCTAssertEqual(pair.bottom.labelKey, "quota.metric.weekly")
            XCTAssertEqual(pair.bottom.remainingPercentage, 80)
        }
    }

    func testCodingPlanProvidersHaveDistinctPresentation() {
        XCTAssertEqual(QuotaProvider.kimi.displayName, "Kimi Code")
        XCTAssertEqual(QuotaProvider.minimax.displayName, "MiniMax")
        XCTAssertEqual(QuotaProvider.kimi.menuBarIconAsset, "kimi-menubar")
        XCTAssertEqual(QuotaProvider.minimax.logoAssetName, "minimax")
        XCTAssertEqual(QuotaProvider.kimi.oauthEndpoint, "/kimi-auth-url")
    }

    func testZAIChinaEndpointUsesDocumentedOpenBigmodelHost() {
        XCTAssertEqual(GLMEndpoint.bigmodel.baseURL, "https://open.bigmodel.cn")
    }
}
