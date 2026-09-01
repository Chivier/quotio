import XCTest
@testable import Quotio

final class AppIdentityTests: XCTestCase {
    func testProductionBundleIdentifierUsesByTrongDomain() {
        XCTAssertEqual(AppIdentity.productionBundleIdentifier, "app.bytrong.quotio")
    }

    func testDevelopmentBuildUsesSeparateKeychainNamespace() {
        XCTAssertEqual(
            AppIdentity.keychainService(
                suffix: "local-management",
                bundleIdentifier: AppIdentity.productionBundleIdentifier,
                isDevelopmentBuild: true
            ),
            "app.bytrong.quotio.debug.local-management"
        )
    }

    func testReleaseBuildKeepsProductionKeychainNamespace() {
        XCTAssertEqual(
            AppIdentity.keychainService(
                suffix: "local-management",
                bundleIdentifier: AppIdentity.productionBundleIdentifier,
                isDevelopmentBuild: false
            ),
            "app.bytrong.quotio.local-management"
        )
    }

    func testLegacyDefaultsMergePreservesCurrentValuesAndNewestLegacyDomain() {
        let merged = AppIdentity.mergingUserDefaults(
            current: ["existing": "current"],
            legacyDomains: [
                ["existing": "legacy", "legacyOnly": "newest"],
                ["legacyOnly": "oldest", "oldestOnly": true],
            ]
        )

        XCTAssertEqual(merged["existing"] as? String, "current")
        XCTAssertEqual(merged["legacyOnly"] as? String, "newest")
        XCTAssertEqual(merged["oldestOnly"] as? Bool, true)
    }
}
