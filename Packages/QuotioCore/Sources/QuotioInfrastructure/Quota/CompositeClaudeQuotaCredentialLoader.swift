import Foundation
import QuotioApplication
import QuotioDomain

public protocol ClaudeDesktopCredentialLoading: Sendable {
  func credential() async -> ClaudeQuotaCredential?
}

public struct CompositeClaudeQuotaCredentialLoader: ClaudeQuotaCredentialLoading {
  private let local: any ClaudeQuotaCredentialLoading
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let external: any ExternalCredentialReading
  private let desktop: (any ClaudeDesktopCredentialLoading)?

  public init(
    local: any ClaudeQuotaCredentialLoading = LocalClaudeQuotaCredentialLoader(),
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    external: any ExternalCredentialReading = ExternalKeychainCredentialReader(),
    desktop: (any ClaudeDesktopCredentialLoading)? = ClaudeDesktopCredentialReader()
  ) {
    self.local = local
    self.vault = vault
    self.metadata = metadata
    self.external = external
    self.desktop = desktop
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    await credentials(for: QuotaFetchRequest(provider: .claude, mode: mode))
  }

  public func credentials(for request: QuotaFetchRequest) async -> [ClaudeQuotaCredential] {
    var result: [ClaudeQuotaCredential] = []
    var unreadable: [ClaudeQuotaCredential] = []
    if request.mode == .monitor {
      let excluded = await metadata.excludedQuotaAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == QuotaProvider.claude.rawValue
        && !account.isDisabled && !excluded.contains(account.id)
      {
        var credential = await vault.credential(for: account.id)
        if credential == nil, request.allowsUserInteraction,
          case .account(let key) = request.scope, key == account.accountKey
        {
          credential = await vault.credentialForUserInitiatedAccess(for: account.id)
        }
        guard let credential else {
          if await vault.credentialState(for: account.id) == .unreadable {
            unreadable.append(
              .init(
                accountKey: account.accountKey, accessToken: "", ownedAccountID: account.id,
                isReadable: false))
          }
          continue
        }
        result.append(
          .init(
            accountKey: account.accountKey,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt,
            ownedAccountID: account.id
          ))
      }
    }

    // The CLI's own keychain item: read-only. Its refresh token is single-use and
    // shared with a running `claude`, so Quotio must never spend it.
    if let record = await external.read(service: "Claude Code-credentials", account: nil),
      let credential = LocalClaudeQuotaCredentialLoader.load(
        data: record.data, allowsRefresh: false)
    {
      result.append(credential)
    }
    result.append(contentsOf: await local.credentials(for: request.mode))
    if let credential = await desktop?.credential() {
      result.append(credential)
    }

    // An unreadable owned account stays visible, but never hides a readable
    // credential for the same account.
    let unique = ClaudeQuotaCredential.uniqueByAccountKey(result)
    let keys = Set(unique.map(\.accountKey))
    return unique + unreadable.filter { !keys.contains($0.accountKey) }
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    _ = await persist(
      refresh, replacing: expectedRefreshToken, for: credential,
      request: QuotaFetchRequest(provider: .claude, mode: mode))
  }

  /// A Quotio-owned login is written to the vault only; anything else goes to the
  /// local loader, which refuses CLI-owned files.
  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    guard let accountID = credential.ownedAccountID else {
      guard credential.allowsRefresh else { return false }
      return await local.persist(
        refresh, replacing: expectedRefreshToken, for: credential, request: request)
    }
    guard let account = await vault.accounts().first(where: { $0.id == accountID }) else {
      return false
    }
    var stored: StoredCredential
    if let latest = await vault.reloadLatest(accountID: accountID) {
      // A newer login or another client's rotation already replaced the token.
      guard latest.refreshToken == expectedRefreshToken else { return false }
      stored = latest
    } else {
      stored = StoredCredential(
        accessToken: credential.accessToken, refreshToken: expectedRefreshToken, idToken: nil,
        accountID: nil, expiresAt: credential.expiresAt, extra: [:])
    }
    stored.accessToken = refresh.accessToken
    stored.refreshToken = refresh.refreshToken ?? expectedRefreshToken
    stored.expiresAt = refresh.expiresAt ?? stored.expiresAt
    do {
      if request.allowsUserInteraction {
        try await vault.saveUserInitiated(stored, metadata: account)
      } else {
        try await vault.save(stored, metadata: account)
      }
      return true
    } catch {
      return false
    }
  }
}
