import XCTest
@testable import Quotio

final class CodingPlanQuotaFetcherTests: XCTestCase {
    func testKimiScopedRefreshUsesInteractiveCredentialOnlyWhenAllowed() async {
        let account = MonitorAccount.make(
            provider: .kimi,
            accountKey: "Personal",
            source: .quotioKeychain
        )
        let vault = InteractiveCredentialVault(account: account)
        let fetcher = KimiQuotaFetcher(vault: vault)

        let backgroundCredential = await fetcher.credential(
            for: account,
            allowUserInteraction: false
        )
        XCTAssertNil(backgroundCredential)
        let backgroundInteractiveReadCount = await vault.interactiveReadCount
        XCTAssertEqual(backgroundInteractiveReadCount, 0)

        let credential = await fetcher.credential(
            for: account,
            allowUserInteraction: true
        )
        XCTAssertEqual(credential?.accessToken, "fixture-kimi-key")
        let foregroundInteractiveReadCount = await vault.interactiveReadCount
        XCTAssertEqual(foregroundInteractiveReadCount, 1)
    }

    func testKimiMapperKeepsRollingWindowBeforeWeeklyWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"""
        {
          "data": {
            "plan": "Coding Pro",
            "user": { "email": "coder@example.com" },
            "usage": { "used": 10, "limit": 100, "reset_in": 86400 },
            "limits": [
              {
                "name": "rolling",
                "detail": { "used": 35, "limit": 50, "reset_in": 18000 },
                "window": { "duration": 5, "timeUnit": "HOUR" }
              }
            ]
          }
        }
        """#.utf8)

        let quota = try XCTUnwrap(KimiQuotaMapper.map(data, now: now))

        XCTAssertEqual(quota.models.map(\.name), ["kimi-five-hour", "kimi-weekly"])
        XCTAssertEqual(quota.models.map(\.percentage), [30, 90])
        XCTAssertEqual(quota.models[0].used, 35)
        XCTAssertEqual(quota.models[0].limit, 50)
        XCTAssertEqual(quota.planType, "Coding Pro")
        XCTAssertEqual(quota.accountDisplayName, "coder@example.com")
        XCTAssertTrue(quota.models.allSatisfy { !$0.resetTime.isEmpty })
    }

    func testMiniMaxMapperUsesPercentageWhenCountsAreZero() throws {
        let data = Data(#"""
        {
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": "96",
              "remains_time": 3600000,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 99,
              "weekly_remains_time": 7200000
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """#.utf8)

        let quota = try XCTUnwrap(MiniMaxQuotaMapper.map(data, now: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertEqual(quota.models.map(\.name), ["minimax-five-hour", "minimax-weekly"])
        XCTAssertEqual(quota.models.map(\.percentage), [96, 99])
        XCTAssertEqual(quota.planType, "Token Plan")
        XCTAssertTrue(quota.models.allSatisfy { !$0.resetTime.isEmpty })
    }

    func testMiniMaxMapperPrefersCountsWhenEntitlementIsKnown() throws {
        let data = Data(#"""
        {
          "model_remains": [{
            "model_name": "general",
            "current_interval_total_count": 100,
            "current_interval_usage_count": 25,
            "current_interval_remaining_percent": 1
          }]
        }
        """#.utf8)

        let quota = try XCTUnwrap(MiniMaxQuotaMapper.map(data))
        let interval = try XCTUnwrap(quota.models.first)

        XCTAssertEqual(interval.percentage, 75)
        XCTAssertEqual(interval.used, 25)
        XCTAssertEqual(interval.limit, 100)
        XCTAssertEqual(interval.remaining, 75)
    }

    func testKimiLegacyDiscoveryIgnoresUnrelatedProviders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-kimi-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        try Data(#"""
        [providers.kimi]
        type = "kimi"
        api_key = "sk-kimi-fixture"

        [providers.other]
        type = "openai"
        api_key = "sk-unrelated-fixture"
        """#.utf8).write(to: config)

        let credentials = KimiCredentialReader.loadLegacyConfig(path: config.path)

        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credentials[0].displayName, "providers.kimi")
        XCTAssertEqual(credentials[0].sourcePath, config.path)
    }

    func testKimiCLIIdentityHeadersIncludeStableDeviceContext() {
        let headers = KimiCredentialReader.identityHeaders(
            accessToken: "fixture-access-token",
            deviceID: "fixture-device-id"
        )

        XCTAssertEqual(headers["X-Msh-Platform"], "kimi_code_cli")
        XCTAssertEqual(headers["X-Msh-Device-Id"], "fixture-device-id")
        XCTAssertFalse(headers["X-Msh-Device-Name", default: ""].isEmpty)
        XCTAssertTrue(headers["X-Msh-Device-Model", default: ""].contains("macOS"))
        XCTAssertFalse(headers["X-Msh-Os-Version", default: ""].isEmpty)
    }

    @MainActor
    func testZAIChinaEndpointUsesDocumentedOpenBigmodelHost() {
        XCTAssertEqual(GLMEndpoint.bigmodel.baseURL, "https://open.bigmodel.cn")
    }
}

private actor InteractiveCredentialVault: MonitorCredentialStore {
    let account: MonitorAccount
    private(set) var interactiveReadCount = 0

    init(account: MonitorAccount) {
        self.account = account
    }

    func accounts() -> [MonitorAccount] { [account] }
    func credential(for accountID: String) -> MonitorOAuthCredential? { nil }

    func credentialForUserInitiatedAccess(for accountID: String) -> MonitorOAuthCredential? {
        interactiveReadCount += 1
        guard accountID == account.id else { return nil }
        return MonitorOAuthCredential(
            accessToken: "fixture-kimi-key",
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
    }

    func reloadLatest(accountID: String) -> MonitorOAuthCredential? { nil }
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) throws {}
    func delete(accountID: String) {}
}
