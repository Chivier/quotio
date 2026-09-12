import Foundation
import XCTest
import os

@testable import Quotio

final class ClaudeCodeQuotaFetcherTests: XCTestCase {
    func testRepeatedExpiryRenewsOriginalGrantAndPersistsRotatedTokens() async throws {
        let vault = ClaudeTestVault(expired: true)
        let server = ClaudeTestServer(vault: vault, rejectsExpandedScope: true)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)

        let first = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(first?.models.first?.percentage, 75)
        await vault.expire()
        let second = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(second?.models.first?.percentage, 50)
        let stored = await vault.credential(for: vault.account.id)
        XCTAssertEqual(stored?.refreshToken, "refresh-2")
        XCTAssertGreaterThan(try XCTUnwrap(stored?.expiresAt).timeIntervalSinceNow, 300)
    }

    func testRefreshRejectionReloadsCredentialsRotatedByAnotherClient() async {
        let vault = ClaudeTestVault(expired: true)
        let server = ClaudeTestServer(vault: vault, rotateExternally: true)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)

        let result = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(result?.models.first?.percentage, 75)
        XCTAssertEqual(result?.isForbidden, false)
    }

    func testPermissionFailureDoesNotConsumeRefreshToken() async {
        let vault = ClaudeTestVault()
        let server = ClaudeTestServer(vault: vault, usageStatus: 403)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)

        let denied = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(denied?.isForbidden, true)
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 0, "A usage permission failure must not rotate a valid login")
        await server.setUsageStatus(200)
        let recovered = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(recovered?.models.first?.percentage, 100)
    }

    func testTransientRefreshFailurePreservesLastGoodFileQuota() async throws {
        let vault = ClaudeTestVault()
        let server = ClaudeTestServer(vault: vault)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("claude-fixture.json")
        try writeCredential(to: file, expired: false)
        let first = await fetcher.fetchQuotaFromAuthFile(at: file.path, forceRefresh: true)?.data

        try writeCredential(to: file, expired: true)
        await server.setRefreshStatus(503)
        await server.setUsageStatus(401)
        let failed = await fetcher.fetchQuotaFromAuthFile(at: file.path, forceRefresh: true)?.data
        XCTAssertEqual(failed?.models.first?.percentage, 100)
        XCTAssertEqual(failed?.lastUpdated, first?.lastUpdated)
        XCTAssertEqual(failed?.isForbidden, false)

        await server.setRefreshStatus(200)
        await server.setUsageStatus(200)
        let recovered = await fetcher.fetchQuotaFromAuthFile(at: file.path, forceRefresh: true)?.data
        XCTAssertEqual(recovered?.models.first?.percentage, 75)
    }

    func testRevokedOwnedCredentialKeepsQuotaAndRequiresAuthentication() async {
        let vault = ClaudeTestVault()
        let server = ClaudeTestServer(vault: vault)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)
        let first = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)

        await vault.expire()
        await server.setRefreshStatus(400)
        await server.setUsageStatus(401)
        let revoked = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(revoked?.isForbidden, true)
        XCTAssertEqual(revoked?.models.first?.percentage, first?.models.first?.percentage)
        XCTAssertEqual(revoked?.lastUpdated, first?.lastUpdated)
    }

    func testFailedPersistenceDoesNotLoseRotatedCredential() async {
        let vault = ClaudeTestVault(expired: true)
        await vault.setRejectWrites(true)
        let server = ClaudeTestServer(vault: vault)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)

        let first = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(first?.models.first?.percentage, 75)
        await vault.setRejectWrites(false)
        let second = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(second?.models.first?.percentage, 75)
        let stored = await vault.credential(for: vault.account.id)
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
        await vault.expire()
        let third = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(third?.models.first?.percentage, 50)
    }

    func testCredentialAccessRequiresExplicitForegroundConsentAndRecovers() async {
        let vault = ClaudeTestVault()
        await vault.requireAuthorization()
        let server = ClaudeTestServer(vault: vault)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let fetcher = ClaudeCodeQuotaFetcher(vault: vault, session: fixture.session)

        let background = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertNil(background)
        let promptCount = await vault.interactiveReadCount
        XCTAssertEqual(promptCount, 0)
        let foreground = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true, allowUserInteraction: true)
        XCTAssertEqual(foreground?.models.first?.percentage, 100)
        let later = await fetcher.fetchOwnedQuota(account: vault.account, forceRefresh: true)
        XCTAssertEqual(later?.models.first?.percentage, 100)
        let finalPromptCount = await vault.interactiveReadCount
        XCTAssertEqual(finalPromptCount, 1)
    }

    func testClaudeAuthorizationStateMismatchCanBeCorrected() async throws {
        let vault = ClaudeTestVault()
        let server = ClaudeLoginServer()
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let coordinator = MonitorOAuthCoordinator(claudeSession: fixture.session) {
            try await vault.save($0, metadata: $1)
        }
        let pending = try await coordinator.beginClaudeLogin()
        do {
            _ = try await coordinator.completeClaudeLogin(code: "fixture-code#wrong-state")
            XCTFail("An authorization from another login must not be accepted")
        } catch MonitorOAuthError.stateMismatch {}
        let stillPending = await coordinator.pendingClaudeLogin()
        XCTAssertEqual(stillPending?.state, pending.state)
        let account = try await coordinator.completeClaudeLogin(code: "fixture-code#" + pending.state)
        XCTAssertEqual(account.accountKey, "fixture@example.com")
        let credential = await vault.credential(for: account.id)
        XCTAssertEqual(credential?.accessToken, "login-access")
    }

    func testClaudeKeychainSaveRetryDoesNotReuseConsumedAuthorizationCode() async throws {
        let vault = ClaudeTestVault()
        await vault.setRejectWrites(true)
        let server = ClaudeLoginServer()
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let coordinator = MonitorOAuthCoordinator(claudeSession: fixture.session) {
            try await vault.save($0, metadata: $1)
        }
        let pending = try await coordinator.beginClaudeLogin()
        do {
            _ = try await coordinator.completeClaudeLogin(code: "fixture-code#" + pending.state)
            XCTFail("Expected the credential store to reject the write")
        } catch MonitorRuntimeError.credentialWriteFailed {}
        let retry = await coordinator.pendingClaudeLogin()
        XCTAssertEqual(retry?.credentialsReady, true)
        await vault.setRejectWrites(false)
        _ = try await coordinator.completeClaudeLogin(code: "")
        let credential = await vault.credential(for: vault.account.id)
        XCTAssertEqual(credential?.refreshToken, "login-refresh")
        let requests = await server.exchangeCount
        XCTAssertEqual(requests, 1, "A consumed authorization code cannot be exchanged twice")
    }

    func testClaudeTransientExchangeFailureRetainsPendingLogin() async throws {
        let vault = ClaudeTestVault()
        let server = ClaudeLoginServer()
        await server.setUnavailable(true)
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let coordinator = MonitorOAuthCoordinator(claudeSession: fixture.session) {
            try await vault.save($0, metadata: $1)
        }
        let pending = try await coordinator.beginClaudeLogin()
        do {
            _ = try await coordinator.completeClaudeLogin(code: "fixture-code#" + pending.state)
            XCTFail("Expected temporary provider rejection")
        } catch MonitorOAuthError.provider {}
        await server.setUnavailable(false)
        let account = try await coordinator.completeClaudeLogin(code: "fixture-code#" + pending.state)
        XCTAssertEqual(account.accountKey, "fixture@example.com")
    }

    func testClaudeReauthenticationCannotReplaceDifferentBrowserAccount() async throws {
        let vault = ClaudeTestVault()
        let server = ClaudeLoginServer()
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let coordinator = MonitorOAuthCoordinator(claudeSession: fixture.session) {
            try await vault.save($0, metadata: $1)
        }
        let pending = try await coordinator.beginClaudeLogin()
        do {
            _ = try await coordinator.completeClaudeLogin(
                code: "fixture-code#" + pending.state, expectedAccountKey: "different@example.com")
            XCTFail("A different browser account must not replace the selected login")
        } catch MonitorOAuthError.accountMismatch {}
        let credential = await vault.credential(for: vault.account.id)
        XCTAssertEqual(credential?.accessToken, "access-0")
    }

    func testCancelledClaudeExchangeCannotSaveOrClearNewLogin() async throws {
        let vault = ClaudeTestVault()
        let server = ClaudeLoginServer()
        await server.suspendNextExchange()
        let fixture = ClaudeHTTPFixture { request in await server.respond(to: request) }
        let coordinator = MonitorOAuthCoordinator(claudeSession: fixture.session) {
            try await vault.save($0, metadata: $1)
        }
        let first = try await coordinator.beginClaudeLogin()
        let exchange = Task { try await coordinator.completeClaudeLogin(code: "fixture-code#" + first.state) }
        await server.waitUntilSuspended()
        await coordinator.cancel()
        let replacement = try await coordinator.beginClaudeLogin()
        await server.release()
        do {
            _ = try await exchange.value
            XCTFail("Cancelled authorization must not complete")
        } catch {}
        let active = await coordinator.pendingClaudeLogin()
        XCTAssertEqual(active?.state, replacement.state)
        let credential = await vault.credential(for: vault.account.id)
        XCTAssertEqual(credential?.accessToken, "access-0")
    }

    func testClaudeCallbackURLRequiresExpectedState() throws {
        let code = try MonitorOAuthCoordinator.claudeAuthorizationCode(
            from: "https://platform.claude.com/oauth/code/callback?code=fixture-code&state=expected",
            expectedState: "expected"
        )
        XCTAssertEqual(code, "fixture-code")
        XCTAssertThrowsError(
            try MonitorOAuthCoordinator.claudeAuthorizationCode(
                from: "https://platform.claude.com/oauth/code/callback?code=fixture-code&state=other",
                expectedState: "expected"
            ))
    }

    private func writeCredential(to url: URL, expired: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "claude",
            "email": "fixture@example.com",
            "access_token": "access-0",
            "refresh_token": "refresh-0",
            "expired": Date().addingTimeInterval(expired ? -60 : 3600).ISO8601Format(),
        ])
        try data.write(to: url, options: .atomic)
    }
}

private actor ClaudeTestVault: MonitorCredentialStore {
    nonisolated let account = MonitorAccount.make(
        provider: .claude,
        accountKey: "fixture@example.com",
        source: .quotioKeychain
    )
    private var stored: MonitorOAuthCredential
    private var rejectWrites = false
    private var authorized = true
    private(set) var interactiveReadCount = 0

    init(expired: Bool = false) {
        stored = MonitorOAuthCredential(
            accessToken: "access-0", refreshToken: "refresh-0",
            expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), extra: [:]
        )
    }

    func accounts() -> [MonitorAccount] { [account] }
    func credential(for accountID: String) -> MonitorOAuthCredential? { authorized ? stored : nil }
    func reloadLatest(accountID: String) -> MonitorOAuthCredential? { authorized ? stored : nil }
    func credentialForUserInitiatedAccess(for accountID: String) -> MonitorOAuthCredential? {
        interactiveReadCount += 1
        authorized = true
        return stored
    }
    func requireAuthorization() { authorized = false }
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) throws {
        if rejectWrites { throw MonitorRuntimeError.credentialWriteFailed }
        stored = credential
    }
    func delete(accountID: String) {}
    func expire() { stored.expiresAt = Date().addingTimeInterval(-60) }
    func setRejectWrites(_ value: Bool) { rejectWrites = value }
    func rotate(to generation: Int) {
        stored.accessToken = "access-\(generation)"
        stored.refreshToken = "refresh-\(generation)"
        stored.expiresAt = Date().addingTimeInterval(3600)
    }
}

private actor ClaudeLoginServer {
    private var unavailable = false
    private var shouldSuspend = false
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var exchangeCount = 0

    func setUnavailable(_ value: Bool) { unavailable = value }
    func suspendNextExchange() { shouldSuspend = true }
    func waitUntilSuspended() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { gate?.resume(); gate = nil }

    func respond(to request: URLRequest) async -> (Int, Data) {
        guard request.url?.path == "/v1/oauth/token" else { return (404, Data()) }
        exchangeCount += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                gate = continuation
                started?.resume()
                started = nil
            }
        }
        if unavailable { return (503, Data(#"{"error":"temporarily_unavailable"}"#.utf8)) }
        return (
            200,
            Data(
                #"{"access_token":"login-access","refresh_token":"login-refresh","expires_in":3600,"account":{"email_address":"fixture@example.com","uuid":"fixture-id"}}"#
                    .utf8)
        )
    }
}

private actor ClaudeTestServer {
    private let vault: ClaudeTestVault
    private let rejectsExpandedScope: Bool
    private var rotateExternally: Bool
    private var generation = 0
    private var usageStatus: Int
    private var refreshStatus = 200
    private(set) var refreshCount = 0

    init(vault: ClaudeTestVault, rejectsExpandedScope: Bool = false, rotateExternally: Bool = false, usageStatus: Int = 200) {
        self.vault = vault
        self.rejectsExpandedScope = rejectsExpandedScope
        self.rotateExternally = rotateExternally
        self.usageStatus = usageStatus
    }

    func setUsageStatus(_ value: Int) { usageStatus = value }
    func setRefreshStatus(_ value: Int) { refreshStatus = value }

    func respond(to request: URLRequest) async -> (Int, Data) {
        if request.url?.path == "/v1/oauth/token" {
            refreshCount += 1
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            if rejectsExpandedScope, body?["scope"] != nil {
                return (400, Data(#"{"error":"invalid_scope"}"#.utf8))
            }
            if rotateExternally {
                rotateExternally = false
                generation += 1
                await vault.rotate(to: generation)
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            if refreshStatus != 200 {
                return (refreshStatus, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            guard body?["refresh_token"] as? String == "refresh-\(generation)" else {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            generation += 1
            return (
                200,
                Data("{\"access_token\":\"access-\(generation)\",\"refresh_token\":\"refresh-\(generation)\",\"expires_in\":3600}".utf8)
            )
        }
        guard request.url?.path == "/api/oauth/usage" else { return (404, Data()) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(generation)" else {
            return (401, Data())
        }
        guard usageStatus == 200 else { return (usageStatus, Data()) }
        return (200, Data("{\"five_hour\":{\"utilization\":\(generation * 25),\"resets_at\":null}}".utf8))
    }
}

private final class ClaudeHTTPFixture {
    let session: URLSession
    private let id = UUID().uuidString

    init(handler: @escaping ClaudeTestURLProtocol.Handler) {
        ClaudeTestURLProtocol.handlers.withLock { [id] in $0[id] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeTestURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Quotio-Test-ID": id]
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
        _ = ClaudeTestURLProtocol.handlers.withLock { [id] in $0.removeValue(forKey: id) }
    }
}

private final class ClaudeTestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async -> (Int, Data)
    static let handlers = OSAllocatedUnfairLock(initialState: [String: Handler]())
    private let loadingTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Quotio-Test-ID"),
            let handler = Self.handlers.withLock({ $0[id] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            request.httpBody = body
        }
        let capturedRequest = request
        loadingTask.withLock { task in
            task = Task { @Sendable [self, handler, capturedRequest] in
                let (status, data) = await handler(capturedRequest)
                guard !Task.isCancelled,
                    let url = capturedRequest.url,
                    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
                else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { loadingTask.withLock { $0?.cancel() } }
}
