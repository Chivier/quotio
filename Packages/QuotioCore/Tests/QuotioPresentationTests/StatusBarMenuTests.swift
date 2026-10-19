import AppKit
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class StatusBarMenuSnapshotMapperTests: XCTestCase {
    static let metrics = [QuotaMetric(name: "seven-day-weekly", percentage: 60, resetTime: "")]

    func testProvidersWithOnlyEmptyRowsAreHidden() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [],
            monitorAccounts: [Account.make(
                providerID: AccountProviderID(rawValue: QuotaProvider.grok.rawValue),
                accountKey: "pending@example.com",
                source: .nativeCredential
            )],
            quota: QuotaSnapshot(quotas: [.claude: ["empty": ProviderQuota()]]),
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english
        )

        XCTAssertTrue(snapshot.providers.isEmpty)
    }

    func testDisabledTrackedAccountHidesItsQuotaRow() {
        let rows = StatusBarMenuSnapshotMapper.accountRows(
            quotaRows: [
                (accountKey: "Off@example.com", email: "off@example.com", data: ProviderQuota(models: Self.metrics)),
                (accountKey: "on@example.com", email: "on@example.com", data: ProviderQuota(models: Self.metrics)),
            ],
            trackedAccounts: [
                Account.make(
                    providerID: AccountProviderID(rawValue: "codex"),
                    accountKey: "off@example.com",
                    source: .nativeCredential,
                    status: .disabled
                ),
                Account.make(
                    providerID: AccountProviderID(rawValue: "codex"),
                    accountKey: "failing@example.com",
                    source: .quotioKeychain
                ),
            ],
            provider: .codex,
            statusMessages: [QuotaAccountID(provider: .codex, accountKey: "FAILING@example.com"): "Keychain access required"]
        )

        XCTAssertEqual(rows.map(\.accountKey), ["on@example.com", "failing@example.com"])
        XCTAssertEqual(rows.last?.statusMessage, "Keychain access required")
    }

    func testMonitorSnapshotMapsProvidersAccountsStateAndDisplaySettings() throws {
        let enabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.amp.rawValue),
            accountKey: "monitor@example.com",
            source: .nativeCredential
        )
        let disabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let tunnel = CloudflareTunnelSnapshot(
            status: .active,
            publicURL: "https://example.trycloudflare.com",
            startTime: Date(timeIntervalSince1970: 1_000),
            installation: CloudflaredInstallation(
                isInstalled: true,
                path: "/usr/local/bin/cloudflared",
                version: "2026.9.0"
            )
        )
        let quota = QuotaSnapshot(
            quotas: [
                .antigravity: [
                    "alpha-key": ProviderQuota(models: Self.metrics, accountDisplayName: "alpha@example.com"),
                    "zulu-key": ProviderQuota(models: Self.metrics, accountDisplayName: "Zulu@example.com"),
                ],
                .claude: [
                    "claude-key": ProviderQuota(models: Self.metrics, accountDisplayName: "claude@example.com"),
                ],
            ],
            refreshingProviders: [.antigravity]
        )
        let preferences = MenuBarPreferences(
            selectedProvider: .amp,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .ring,
            hideSensitiveInfo: true,
            modelAggregationMode: .average
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: true,
            tunnel: tunnel,
            directAuthProviders: [.antigravity, .claude, .copilot],
            monitorAccounts: [enabledMonitorAccount, disabledMonitorAccount],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: "zulu@example.com",
            menuBarPreferences: preferences,
            appearanceMode: .dark,
            language: .vietnamese,
            accountStatusMessages: [
                QuotaAccountID(provider: .amp, accountKey: "monitor@example.com"): "Sign in again",
            ]
        )

        XCTAssertFalse(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.proxyPort, 8317)
        XCTAssertTrue(snapshot.isProxyRunning)
        XCTAssertEqual(snapshot.tunnel, tunnel)
        // Raw auth files (Copilot) do not add providers in Monitor mode, and the disabled
        // Codex account is not listed.
        XCTAssertEqual(snapshot.providers.map(\.provider), [.amp, .antigravity, .claude])
        let amp = try XCTUnwrap(snapshot.providers.first { $0.provider == .amp })
        XCTAssertNil(amp.accounts.first?.quota, "A tracked account without quota keeps its row")
        XCTAssertEqual(amp.accounts.first?.statusMessage, "Sign in again")
        XCTAssertEqual(snapshot.selectedProvider, .amp)
        XCTAssertTrue(snapshot.isLoadingQuotas)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayMode, .remaining)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayStyle, .ring)
        XCTAssertTrue(snapshot.displaySettings.hideSensitiveInfo)
        XCTAssertEqual(snapshot.displaySettings.modelAggregationMode, .average)
        XCTAssertEqual(snapshot.appearanceMode, .dark)
        XCTAssertEqual(snapshot.language, .vietnamese)

        let antigravity = try XCTUnwrap(snapshot.providers.first { $0.provider == .antigravity })
        XCTAssertTrue(antigravity.isRefreshing)
        XCTAssertTrue(antigravity.supportsScopedRefresh)
        XCTAssertEqual(antigravity.accounts.map(\.email), [
            "Zulu@example.com",
            "alpha@example.com",
        ])
        XCTAssertTrue(antigravity.accounts[0].isActiveInIDE)
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshing))
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshBlocked))
    }

    func testLocalProxySnapshotFiltersCLIProvidersByInstalledAgents() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .localProxy,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.antigravity, .claude, .codex],
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .antigravity: ["a": ProviderQuota(models: Self.metrics)],
                .claude: ["c": ProviderQuota(models: Self.metrics)],
                .codex: ["x": ProviderQuota(models: Self.metrics)],
            ]),
            installedAgents: [.codexCLI],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            appearanceMode: .system,
            language: .english
        )

        XCTAssertTrue(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .codex])
        XCTAssertNil(snapshot.selectedProvider)
    }
}

@MainActor
final class StatusBarMenuRendererTests: XCTestCase {
    static let metrics = StatusBarMenuSnapshotMapperTests.metrics

    func testSelectedProviderRendersOnlyItsAccountGroup() {
        let unfiltered = makeSnapshot(selectedProvider: nil)
        let filtered = makeSnapshot(selectedProvider: .claude)
        let dispatcher = makeNoopDispatcher()

        let unfilteredMenu = StatusBarMenuRenderer(
            snapshot: unfiltered,
            commands: dispatcher
        ).buildMenu()
        let filteredMenu = StatusBarMenuRenderer(
            snapshot: filtered,
            commands: dispatcher
        ).buildMenu()

        let unfilteredItems = unfilteredMenu.items.filter { !$0.isHidden }
        let filteredItems = filteredMenu.items.filter { !$0.isHidden }
        // Compact layout: no separators between provider groups.
        XCTAssertEqual(unfilteredItems.count, 10)
        XCTAssertEqual(unfilteredItems.filter(\.isSeparatorItem).count, 3)
        XCTAssertEqual(filteredItems.count, 7)
        XCTAssertEqual(filteredItems.filter(\.isSeparatorItem).count, 3)
    }

    func testProviderFilterHidesItemsWithoutReplacingTrackedMenuContents() {
        var selections: [QuotaProvider?] = []
        let controller = StatusBarProviderFilterController(selectedProvider: nil) {
            selections.append($0)
        }
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        let codexItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        let providerHeader = NSMenuItem(title: "Header", action: nil, keyEquivalent: "")
        menu.items = [providerHeader, claudeItem, codexItem]
        controller.register(providerHeader, scope: .allProvidersOnly)
        controller.register(claudeItem, scope: .provider(.claude))
        controller.register(codexItem, scope: .provider(.codex))
        controller.activate(in: menu)
        let originalItems = menu.items.map(ObjectIdentifier.init)

        controller.select(.claude)

        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), originalItems)
        XCTAssertTrue(providerHeader.isHidden)
        XCTAssertFalse(claudeItem.isHidden)
        XCTAssertTrue(codexItem.isHidden)
        XCTAssertEqual(selections, [.claude])
    }

    private func makeSnapshot(selectedProvider: QuotaProvider?) -> StatusBarMenuSnapshot {
        StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude, .codex],
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .claude: [
                    "claude-key": ProviderQuota(models: Self.metrics, accountDisplayName: "claude@example.com"),
                ],
                .codex: [
                    "codex-key": ProviderQuota(models: Self.metrics, accountDisplayName: "codex@example.com"),
                ],
            ]),
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: selectedProvider),
            appearanceMode: .system,
            language: .english
        )
    }

    private func makeNoopDispatcher() -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {},
            refreshProvider: { _ in },
            refreshAccount: { _ in },
            toggleProxy: {},
            toggleTunnel: { _ in },
            copyText: { _ in },
            switchAntigravityAccount: { _ in },
            isAntigravityIDERunning: { false },
            confirmAntigravitySwitch: { _, _ in true },
            selectProvider: { _ in },
            openApp: {},
            quit: {},
            menuNeedsRebuild: {}
        ))
    }
}

@MainActor
final class StatusBarCommandDispatcherTests: XCTestCase {
    func testAsyncCommandsRouteAndRebuildAfterCompletion() async {
        let recorder = StatusBarCommandRecorder()
        let rebuilds = expectation(description: "menu rebuilt after async commands")
        rebuilds.expectedFulfillmentCount = 6
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
            rebuilds.fulfill()
        }

        dispatcher.dispatch(.refreshAll)
        dispatcher.dispatch(.refreshProvider(.claude))
        dispatcher.dispatch(.refreshAccount(QuotaAccountID(provider: .codex, accountKey: "person@example.com")))
        dispatcher.dispatch(.toggleProxy)
        dispatcher.dispatch(.toggleTunnel(port: 8317))
        dispatcher.dispatch(.useAntigravityAccount(email: "active@example.com"))

        await fulfillment(of: [rebuilds], timeout: 1)
        XCTAssertEqual(Set(recorder.asyncCommands), Set([
            "refreshAll",
            "refreshProvider:claude",
            "refreshAccount:codex:person@example.com",
            "toggleProxy",
            "toggleTunnel:8317",
            "switchAntigravity:active@example.com",
        ]))
        XCTAssertEqual(recorder.rebuildCount, 6)
    }

    func testSynchronousCommandsRouteWithoutUnnecessaryRebuilds() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.copyProxyURL("http://localhost:8317"))
        dispatcher.dispatch(.copyTunnelURL("https://example.trycloudflare.com"))
        dispatcher.dispatch(.openApp)
        dispatcher.dispatch(.quit)
        dispatcher.dispatch(.selectProvider(.claude))
        dispatcher.dispatch(.selectProvider(nil))

        XCTAssertEqual(recorder.copiedText, [
            "http://localhost:8317",
            "https://example.trycloudflare.com",
        ])
        XCTAssertEqual(recorder.selectedProviders, [.claude, nil])
        XCTAssertEqual(recorder.openAppCount, 1)
        XCTAssertEqual(recorder.quitCount, 1)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    func testCancelledAntigravityConfirmationDoesNotSwitchOrRebuild() {
        let recorder = StatusBarCommandRecorder()
        recorder.confirmSwitch = false
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.useAntigravityAccount(email: "person@example.com"))

        XCTAssertEqual(recorder.ideRunningChecks, 1)
        XCTAssertEqual(recorder.confirmations, ["person@example.com:true"])
        XCTAssertTrue(recorder.asyncCommands.isEmpty)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    private func makeDispatcher(
        recorder: StatusBarCommandRecorder,
        menuNeedsRebuild: @escaping () -> Void
    ) -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: { recorder.asyncCommands.append("refreshAll") },
            refreshProvider: { provider in
                recorder.asyncCommands.append("refreshProvider:\(provider.rawValue)")
            },
            refreshAccount: { account in
                recorder.asyncCommands.append(
                    "refreshAccount:\(account.provider.rawValue):\(account.accountKey)"
                )
            },
            toggleProxy: { recorder.asyncCommands.append("toggleProxy") },
            toggleTunnel: { port in recorder.asyncCommands.append("toggleTunnel:\(port)") },
            copyText: { recorder.copiedText.append($0) },
            switchAntigravityAccount: { email in
                recorder.asyncCommands.append("switchAntigravity:\(email)")
            },
            isAntigravityIDERunning: {
                recorder.ideRunningChecks += 1
                return true
            },
            confirmAntigravitySwitch: { email, isRunning in
                recorder.confirmations.append("\(email):\(isRunning)")
                return recorder.confirmSwitch
            },
            selectProvider: { recorder.selectedProviders.append($0) },
            openApp: { recorder.openAppCount += 1 },
            quit: { recorder.quitCount += 1 },
            menuNeedsRebuild: menuNeedsRebuild
        ))
    }
}

@MainActor
private final class StatusBarCommandRecorder {
    var asyncCommands: [String] = []
    var copiedText: [String] = []
    var confirmations: [String] = []
    var selectedProviders: [QuotaProvider?] = []
    var confirmSwitch = true
    var ideRunningChecks = 0
    var openAppCount = 0
    var quitCount = 0
    var rebuildCount = 0
}
