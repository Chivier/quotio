import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class MonitorOAuthAccountIdentityTests: XCTestCase {
  private let codex = AccountProviderID(rawValue: QuotaProvider.codex.rawValue)
  private let claude = AccountProviderID(rawValue: QuotaProvider.claude.rawValue)

  // MARK: - Sanitizing

  func testCallbackErrorIsSurfacedAsASanitizedProviderCode() {
    let denied = URL(string: "http://localhost:1455/auth/callback?state=s&error=access_denied")!
    let hostile = URL(string: "http://localhost:1455/auth/callback?state=s&error=%3Cscript%3E")!

    XCTAssertThrowsError(try MonitorOAuthAuthorizer.authorizationCode(from: denied, expectedState: "s")) {
      XCTAssertEqual($0 as? OAuthFlowFailure, .provider("access_denied"))
    }
    XCTAssertThrowsError(try MonitorOAuthAuthorizer.authorizationCode(from: hostile, expectedState: "s")) {
      XCTAssertEqual($0 as? OAuthFlowFailure, .provider("authorization_failed"))
    }
  }

  func testProviderErrorCodesAreSanitized() {
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(json: ["error": "invalid_grant"], statusCode: 400),
      .provider("invalid_grant"))
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(
        json: ["error": ["type": "rate_limit_error", "message": "token abc"]], statusCode: 429),
      .provider("rate_limit_error"))
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(json: ["errorCode": "slow_down"], statusCode: 400),
      .provider("slow_down"))
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(json: ["error": "has spaces: secret"], statusCode: 400),
      .provider("http_400"))
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(
        json: ["error": String(repeating: "a", count: 81)], statusCode: 401),
      .provider("http_401"))
    XCTAssertEqual(
      MonitorOAuthAuthorizer.providerFailure(json: nil, statusCode: 502), .provider("http_502"))
  }

  // MARK: - Codex account selection

  func testCodexSelectionRejectsAnotherAccountOnReconnectAndAnExistingOneOnAdd() {
    XCTAssertThrowsError(try MonitorOAuthAuthorizer.validateCodexAccountSelection(
      accountID: "other", existingIDs: ["original", "other"],
      expectedAccountID: "original", addingNewAccount: false
    )) { XCTAssertEqual($0 as? OAuthFlowFailure, .accountMismatch) }
    XCTAssertThrowsError(try MonitorOAuthAuthorizer.validateCodexAccountSelection(
      accountID: "existing", existingIDs: ["existing"],
      expectedAccountID: nil, addingNewAccount: true
    )) { XCTAssertEqual($0 as? OAuthFlowFailure, .accountAlreadyConnected) }
    XCTAssertNoThrow(try MonitorOAuthAuthorizer.validateCodexAccountSelection(
      accountID: "existing", existingIDs: ["existing"],
      expectedAccountID: "existing", addingNewAccount: false))
  }

  func testReauthenticationMatchesOnlyTheSameUser() {
    XCTAssertTrue(MonitorOAuthAuthorizer.sameCodexUser(
      existingEmail: " Alice@example.com ", loginEmail: "alice@EXAMPLE.com"))
    XCTAssertFalse(MonitorOAuthAuthorizer.sameCodexUser(
      existingEmail: "alice@example.com", loginEmail: "bob@example.com"))
    XCTAssertFalse(MonitorOAuthAuthorizer.sameCodexUser(
      existingEmail: "alice@example.com", loginEmail: nil))
  }

  func testCodexReloginRenewsAnUnreadableEmailKeyedAccountInPlace() async throws {
    // Created by an older build: keyed by the email alone, item now unreadable
    // without a prompt.
    let existing = Account.make(
      providerID: codex, accountKey: "a@b.c", displayName: "a@b.c", source: .quotioKeychain)
    let vault = CodexTestVault(accounts: [existing], readable: [:], userInitiated: [
      existing.id: StoredCredential(
        accessToken: "old", refreshToken: "old-refresh", idToken: nil, accountID: "account-1",
        expiresAt: nil, extra: [:])
    ])

    let account = try await codexLogin(
      vault: vault, email: "a@b.c", workspace: "account-1",
      request: OAuthAuthorizationRequest(providerID: codex))

    XCTAssertEqual(account.id, existing.id)
    XCTAssertEqual(account.accountKey, "a@b.c • 07e99801")
    XCTAssertEqual(account.displayName, "a@b.c")
    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.userInitiated), [true])
    XCTAssertEqual(saves.map(\.account.id), [existing.id])
  }

  func testCodexLoginToAnotherWorkspaceOnTheSameEmailAddsASecondAccount() async throws {
    let existing = CodexQuotaFetcherTests.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(accounts: [existing], readable: [
      existing.id: StoredCredential(
        accessToken: "old", refreshToken: nil, idToken: nil, accountID: "account-1",
        expiresAt: nil, extra: [:])
    ])

    let account = try await codexLogin(
      vault: vault, email: "a@b.c", workspace: "workspace-team",
      request: OAuthAuthorizationRequest(providerID: codex, addingNewAccount: true))

    XCTAssertNotEqual(account.id, existing.id)
    XCTAssertEqual(account.accountKey, "a@b.c • d782057d")
    let accounts = await vault.accounts()
    XCTAssertEqual(accounts.count, 2)
  }

  func testCodexAddRejectsAnAlreadyConnectedAccountWithoutSaving() async throws {
    let existing = CodexQuotaFetcherTests.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(accounts: [existing], readable: [
      existing.id: StoredCredential(
        accessToken: "old", refreshToken: nil, idToken: nil, accountID: "account-1",
        expiresAt: nil, extra: [:])
    ])

    do {
      _ = try await codexLogin(
        vault: vault, email: "a@b.c", workspace: "account-1",
        request: OAuthAuthorizationRequest(providerID: codex, addingNewAccount: true))
      XCTFail("Expected an already-connected failure")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .accountAlreadyConnected)
    }
    let saves = await vault.saves()
    XCTAssertTrue(saves.isEmpty)
  }

  func testCodexReconnectPinsTheWorkspaceAndRejectsADifferentAccount() async throws {
    let existing = CodexQuotaFetcherTests.ownedAccount(key: "a@b.c • 07e99801", email: "a@b.c")
    let vault = CodexTestVault(accounts: [existing], readable: [
      existing.id: StoredCredential(
        accessToken: "old", refreshToken: nil, idToken: nil, accountID: "account-1",
        expiresAt: nil, extra: [:])
    ])
    let opener = RecordingURLOpener()

    do {
      _ = try await codexLogin(
        vault: vault, email: "a@b.c", workspace: "workspace-team",
        request: OAuthAuthorizationRequest(providerID: codex, expectedAccountID: existing.id),
        opener: opener)
      XCTFail("Expected an account mismatch")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .accountMismatch)
    }
    let opened = try XCTUnwrap(opener.lastURL)
    let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "allowed_workspace_id" }?.value, "account-1")
    let saves = await vault.saves()
    XCTAssertTrue(saves.isEmpty)
  }

  func testCodexReconnectToAnUnknownAccountFailsBeforeOpeningTheBrowser() async throws {
    let opener = RecordingURLOpener()
    do {
      _ = try await codexLogin(
        vault: CodexTestVault(accounts: [], readable: [:]), email: "a@b.c", workspace: "account-1",
        request: OAuthAuthorizationRequest(providerID: codex, expectedAccountID: "unknown"),
        opener: opener)
      XCTFail("Expected an account mismatch")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .accountMismatch)
    }
    XCTAssertNil(opener.lastURL)
  }

  // MARK: - Claude

  func testClaudeRetriesADeniedKeychainWriteWithoutASecondCodeExchange() async throws {
    let vault = CodexTestVault(accounts: [], readable: [:], deniedUserInitiatedSaves: 1)
    let http = ClaudeTokenTransport(refreshToken: "refresh")
    let authorizer = makeAuthorizer(vault: vault, http: http)
    let attempt = OAuthAttemptID()
    let state = try await beginClaude(authorizer, attempt: attempt)

    do {
      _ = try await authorizer.completeManualCode("code#\(state)", providerID: claude, attemptID: attempt)
      XCTFail("Expected the denied write to surface")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .credentialStorageDenied)
    }
    let account = try await authorizer.completeManualCode(
      "code#\(state)", providerID: claude, attemptID: attempt)

    XCTAssertEqual(account.accountKey, "person@example.com")
    let exchanges = await http.exchangeCount()
    XCTAssertEqual(exchanges, 1)
    let saves = await vault.saves()
    XCTAssertEqual(saves.map(\.credential.refreshToken), ["refresh"])
  }

  func testClaudeReconnectRejectsADifferentAccount() async throws {
    let vault = CodexTestVault(accounts: [], readable: [:])
    let authorizer = makeAuthorizer(vault: vault, http: ClaudeTokenTransport(refreshToken: "refresh"))
    let attempt = OAuthAttemptID()
    let expected = Account.make(providerID: claude, accountKey: "other@example.com", source: .quotioKeychain)
    let state = try await beginClaude(
      authorizer, attempt: attempt,
      request: OAuthAuthorizationRequest(providerID: claude, expectedAccountID: expected.id))

    do {
      _ = try await authorizer.completeManualCode("code#\(state)", providerID: claude, attemptID: attempt)
      XCTFail("Expected an account mismatch")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .accountMismatch)
    }
    let saves = await vault.saves()
    XCTAssertTrue(saves.isEmpty)
  }

  func testClaudeLoginWithoutARefreshTokenIsRejected() async throws {
    let vault = CodexTestVault(accounts: [], readable: [:])
    let authorizer = makeAuthorizer(vault: vault, http: ClaudeTokenTransport(refreshToken: nil))
    let attempt = OAuthAttemptID()
    let state = try await beginClaude(authorizer, attempt: attempt)

    do {
      _ = try await authorizer.completeManualCode("code#\(state)", providerID: claude, attemptID: attempt)
      XCTFail("Expected an invalid response")
    } catch {
      XCTAssertEqual(error as? OAuthFlowFailure, .invalidResponse)
    }
  }

  // MARK: - Helpers

  private func makeAuthorizer(
    vault: any CredentialVault,
    http: any OAuthHTTPTransport,
    opener: RecordingURLOpener = RecordingURLOpener()
  ) -> MonitorOAuthAuthorizer {
    MonitorOAuthAuthorizer(
      vault: vault, urlOpener: opener, callbackTransport: AuthorizingCallbackTransport(opener: opener),
      httpTransport: http
    ) { _, _, _, _, _ in nil }
  }

  private func beginClaude(
    _ authorizer: MonitorOAuthAuthorizer,
    attempt: OAuthAttemptID,
    request: OAuthAuthorizationRequest? = nil
  ) async throws -> String {
    let outcome = try await authorizer.begin(
      request: request ?? OAuthAuthorizationRequest(providerID: claude), attemptID: attempt,
      progress: { _ in })
    guard case .awaitingManualCode(_, let state) = outcome else {
      XCTFail("Expected a manual code prompt")
      return ""
    }
    return state
  }

  private func codexLogin(
    vault: CodexTestVault,
    email: String,
    workspace: String,
    request: OAuthAuthorizationRequest,
    opener: RecordingURLOpener = RecordingURLOpener()
  ) async throws -> Account {
    let authorizer = makeAuthorizer(
      vault: vault, http: CodexTokenTransport(email: email, workspace: workspace), opener: opener)
    let outcome = try await authorizer.begin(
      request: request, attemptID: OAuthAttemptID(), progress: { _ in })
    guard case .completed(let account) = outcome else {
      XCTFail("Expected a completed login")
      throw OAuthFlowFailure.unknown
    }
    return account
  }
}

final class RecordingURLOpener: URLOpening, @unchecked Sendable {
  private nonisolated(unsafe) var opened: URL?
  private let lock = NSLock()

  nonisolated var lastURL: URL? { lock.withLock { opened } }

  func open(_ url: URL) -> Bool {
    lock.withLock { opened = url }
    return true
  }
}

/// Answers the browser callback with the state and redirect URI the opened
/// authorization URL carried, as a browser completing the login would.
private actor AuthorizingCallbackTransport: OAuthCallbackTransport {
  private let opener: RecordingURLOpener

  init(opener: RecordingURLOpener) { self.opener = opener }

  func start(preferredPort: UInt16?) async throws -> UInt16 { preferredPort ?? 1455 }

  func waitForCallback(timeout: Duration) async throws -> URL {
    guard let opened = opener.lastURL,
      let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems,
      let state = items.first(where: { $0.name == "state" })?.value,
      let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
      var callback = URLComponents(string: redirect)
    else { throw OAuthFlowFailure.invalidResponse }
    callback.queryItems = [
      URLQueryItem(name: "code", value: "authorization-code"),
      URLQueryItem(name: "state", value: state),
    ]
    return callback.url!
  }

  func stop() async {}
}

private actor CodexTokenTransport: OAuthHTTPTransport {
  private let email: String
  private let workspace: String

  init(email: String, workspace: String) {
    self.email = email
    self.workspace = workspace
  }

  func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
    let idToken = CodexQuotaFetcherTests.jwt([
      "email": email,
      "https://api.openai.com/auth": ["chatgpt_account_id": workspace],
    ])
    let body = try JSONSerialization.data(withJSONObject: [
      "access_token": "access", "refresh_token": "refresh", "id_token": idToken, "expires_in": 3600,
    ])
    return OAuthHTTPResponse(statusCode: 200, body: body)
  }
}

private actor ClaudeTokenTransport: OAuthHTTPTransport {
  private let refreshToken: String?
  private var exchanges = 0

  init(refreshToken: String?) { self.refreshToken = refreshToken }

  func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
    exchanges += 1
    var tokens: [String: Any] = [
      "access_token": "access",
      "account": ["email_address": "person@example.com", "uuid": "uuid"],
    ]
    if let refreshToken { tokens["refresh_token"] = refreshToken }
    return OAuthHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: tokens))
  }

  func exchangeCount() -> Int { exchanges }
}
