import Foundation
import QuotioApplication
import QuotioDomain

public struct CompositeCodexQuotaCredentialLoader: CodexQuotaCredentialLoading {
  public static let keychainService = "Codex Auth"

  private let local: any CodexQuotaCredentialLoading
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let external: any ExternalCredentialReading

  public init(
    local: any CodexQuotaCredentialLoading = LocalCodexQuotaCredentialLoader(),
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    external: any ExternalCredentialReading = ExternalKeychainCredentialReader()
  ) {
    self.local = local
    self.vault = vault
    self.metadata = metadata
    self.external = external
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] {
    await credentials(for: QuotaFetchRequest(provider: .codex, mode: mode))
  }

  /// One credential per canonical key, Quotio-owned logins first.
  ///
  /// Keys are never merged by ChatGPT account ID alone: that ID names a workspace,
  /// and two people in one team workspace are two accounts. A scoped request that
  /// names a Quotio-owned login is answered by that login only, never by a
  /// same-named credential from another source, so one workspace's quota cannot
  /// appear on another workspace's row.
  public func credentials(for request: QuotaFetchRequest) async -> [CodexQuotaCredential] {
    let mode = request.mode
    let localCredentials = await local.credentials(for: mode)
    let legacyAliases = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases(localCredentials)
    let excludedIDs = mode == .monitor ? await metadata.excludedQuotaAccountIDs() : []
    var excludedKeys = Set<String>()
    var owned: [CodexQuotaCredential] = []
    var requestNamesOwnedAccount = false
    let requestedKey: String? = {
      if case .account(let key) = request.scope { return key }
      return nil
    }()

    if mode == .monitor {
      for account in await vault.accounts()
      where account.providerID.rawValue == QuotaProvider.codex.rawValue {
        let isExcluded = account.isDisabled || excludedIDs.contains(account.id)
        let mayIdentify = requestedKey.map {
          CodexAccountKey.mayIdentifyStoredAccount(
            $0, metadataKey: account.accountKey, displayName: account.displayName)
        } ?? false
        var stored = await vault.credential(for: account.id)
        if stored == nil, !isExcluded, mayIdentify, request.allowsUserInteraction {
          stored = await vault.credentialForUserInitiatedAccess(for: account.id)
        }
        let credential = stored.map {
          Self.ownedCredential($0, account: account, legacyAliases: legacyAliases)
        }
        if isExcluded {
          excludedKeys.insert(account.accountKey.lowercased())
          if let credential { excludedKeys.insert(credential.accountKey.lowercased()) }
          continue
        }
        if mayIdentify { requestNamesOwnedAccount = true }
        if let credential { owned.append(credential) }
      }
    }

    var cli: [CodexQuotaCredential] = []
    if let record = await external.read(service: Self.keychainService, account: nil),
      let credential = LocalCodexQuotaCredentialLoader.loadNative(
        data: record.data, fallbackAccountKey: "Codex")
    {
      cli.append(LocalCodexQuotaCredentialLoader.applyingLegacyAlias(
        credential, aliases: legacyAliases))
    }

    let candidates = Self.markingCopiedCLITokensReadOnly(owned + cli + localCredentials)
    var merged: [CodexQuotaCredential] = []
    var positions: [String: Int] = [:]
    for credential in candidates {
      let key = credential.accountKey.lowercased()
      guard !excludedKeys.contains(key), !Self.isExcluded(credential, excludedIDs: excludedIDs)
      else { continue }
      if let index = positions[key] {
        let selected = merged[index]
        merged[index] = selected.replacing(
          aliases: selected.aliases.union(credential.aliases)
            .union([credential.accountKey]).subtracting([selected.accountKey]))
      } else {
        positions[key] = merged.count
        merged.append(credential)
      }
    }
    guard requestNamesOwnedAccount else { return merged }
    return merged.filter { $0.source.ownedAccountID != nil }
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    _ = await persist(
      refresh, replacing: expectedRefreshToken, for: credential,
      request: QuotaFetchRequest(provider: .codex, mode: mode))
  }

  /// Quotio-owned logins are written to the vault only, CLIProxyAPI files to their
  /// file only. Codex CLI credentials are never written.
  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    request: QuotaFetchRequest
  ) async -> Bool {
    switch credential.source {
    case .quotio(let accountID):
      return await persistOwned(
        refresh, replacing: expectedRefreshToken, credential: credential,
        accountID: accountID, userInitiated: request.allowsUserInteraction)
    case .cliProxy:
      return await local.persist(
        refresh, replacing: expectedRefreshToken, for: credential, request: request)
    case .codexCLI:
      return false
    }
  }

  private func persistOwned(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    credential: CodexQuotaCredential,
    accountID: String,
    userInitiated: Bool
  ) async -> Bool {
    guard let account = await vault.accounts().first(where: { $0.id == accountID }) else {
      return false
    }
    var stored: StoredCredential
    if let latest = await vault.reloadLatest(accountID: accountID) {
      // A newer login or another client's rotation already replaced the token.
      guard latest.refreshToken == expectedRefreshToken else { return false }
      stored = latest
    } else {
      // The stored item is unreadable and nothing is cached: the vault keeps this
      // rotation in memory until the user restores access.
      stored = StoredCredential(
        accessToken: credential.accessToken, refreshToken: expectedRefreshToken,
        idToken: credential.idToken, accountID: credential.accountID,
        expiresAt: credential.expiresAt, extra: [:])
    }
    stored.accessToken = refresh.accessToken
    stored.refreshToken = refresh.refreshToken ?? expectedRefreshToken
    stored.idToken = refresh.idToken ?? stored.idToken
    stored.expiresAt = refresh.expiresAt ?? stored.expiresAt
    do {
      if userInitiated {
        try await vault.saveRotationUserInitiated(stored, metadata: account)
      } else {
        try await vault.save(stored, metadata: account)
      }
      return true
    } catch {
      return false
    }
  }

  /// The quota key for a Quotio-owned login: its email qualified by the ChatGPT
  /// workspace, or the key of the single CLIProxyAPI file for that workspace. The
  /// metadata key and the plain email older builds used remain aliases.
  static func ownedCredential(
    _ stored: StoredCredential,
    account: Account,
    legacyAliases: [String: String]
  ) -> CodexQuotaCredential {
    let claims = LocalCodexQuotaCredentialLoader.claims(stored.idToken)
    let accountID = stored.accountID ?? claims["accountID"]
    let email = claims["email"]
      ?? (CodexAccountKey.hasFingerprintSuffix(account.displayName) ? nil : account.displayName)
    let key: String
    if email == nil, CodexAccountKey.hasFingerprintSuffix(account.accountKey) {
      key = accountID.flatMap { legacyAliases[$0] } ?? account.accountKey
    } else {
      key = CodexAccountKey.canonical(
        email: email, accountID: accountID, aliases: legacyAliases, fallback: account.accountKey)
    }
    var aliases: Set<String> = [account.accountKey]
    if let email { aliases.insert(email) }
    aliases.remove(key)
    return CodexQuotaCredential(
      accountKey: key, aliases: aliases, accessToken: stored.accessToken,
      refreshToken: stored.refreshToken, idToken: stored.idToken, accountID: accountID,
      source: .quotio(accountID: account.id), displayName: email, expiresAt: stored.expiresAt)
  }

  /// A refresh token copied from a Codex CLI login is still the CLI's, wherever the
  /// copy lives. Keep it readable, but never refresh it.
  private static func markingCopiedCLITokensReadOnly(
    _ credentials: [CodexQuotaCredential]
  ) -> [CodexQuotaCredential] {
    let cliTokens = Set(credentials.compactMap {
      $0.source == .codexCLI ? $0.refreshToken : nil
    })
    guard !cliTokens.isEmpty else { return credentials }
    return credentials.map { credential in
      guard credential.source == .cliProxy, let token = credential.refreshToken,
        cliTokens.contains(token)
      else { return credential }
      return credential.replacing(source: .codexCLI)
    }
  }

  private static func isExcluded(
    _ credential: CodexQuotaCredential,
    excludedIDs: Set<String>
  ) -> Bool {
    guard !excludedIDs.isEmpty else { return false }
    return credential.aliases.union([credential.accountKey]).contains { accountKey in
      excludedIDs.contains(AccountIdentity.make(
        providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
        accountKey: accountKey
      ).id)
    }
  }
}
