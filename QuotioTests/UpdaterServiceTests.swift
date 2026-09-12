import XCTest
@testable import Quotio

@MainActor
final class UpdaterServiceTests: XCTestCase {
    func testDevelopmentBuildCannotStartReleaseUpdates() throws {
        guard AppIdentity.isDevelopmentBuild else {
            throw XCTSkip("Distribution builds intentionally support release updates.")
        }
        let updater = UpdaterService()
        updater.checkForUpdatesInBackground()
        updater.checkForUpdates()

        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.isCheckingForUpdates)
    }
}
