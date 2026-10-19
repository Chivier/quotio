import Foundation
import QuotioApplication
import QuotioDomain

/// MiniMax Token Plan usage for Quotio-owned subscription keys (Monitor mode only).
public actor MiniMaxQuotaFetcher: QuotaFetching {
  public static let defaultEndpoints = [
    URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!,
    URL(string: "https://api.minimax.io/v1/token_plan/remains")!,
  ]

  public nonisolated let provider = QuotaProvider.minimax
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let probe: CodingPlanEndpointProbe
  private let now: @Sendable () -> Date
  /// The regional host that last answered for each account ID.
  private var preferredEndpoints: [String: URL] = [:]

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    endpoints: [URL] = MiniMaxQuotaFetcher.defaultEndpoints,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.probe = CodingPlanEndpointProbe(endpoints: endpoints, session: session)
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard request.mode == .monitor else {
      return QuotaProviderOutput(
        quotas: [:], credentialAvailability: .missing, credentialAccountKeys: [])
    }
    let disabled = await metadata.disabledAccountIDs()
    let accounts = await vault.accounts().filter {
      $0.providerID.rawValue == provider.rawValue && !disabled.contains($0.id)
        && Self.includes($0.accountKey, in: request.scope)
    }
    var quotas: [String: ProviderQuota] = [:]
    var credentialAccountKeys = Set<String>()
    for account in accounts {
      var credential = await vault.credential(for: account.id)
      if credential == nil, request.allowsUserInteraction, case .account = request.scope {
        credential = await vault.credentialForUserInitiatedAccess(for: account.id)
      }
      guard
        let key = credential?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
        !key.isEmpty
      else {
        // An item this build cannot read still names a live account; keep its last
        // quota instead of purging it.
        if await vault.credentialState(for: account.id) == .unreadable {
          credentialAccountKeys.insert(account.accountKey)
        }
        continue
      }
      credentialAccountKeys.insert(account.accountKey)
      if let quota = await quota(accountID: account.id, key: key) {
        quotas[account.accountKey] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: credentialAccountKeys.isEmpty ? .missing : .present,
      credentialAccountKeys: credentialAccountKeys
    )
  }

  private func quota(accountID: String, key: String) async -> ProviderQuota? {
    let date = now()
    let outcome = await probe.run(
      preferred: preferredEndpoints[accountID],
      makeRequest: { endpoint in
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quotio-MiniMaxMonitor/1.0", forHTTPHeaderField: "User-Agent")
        return request
      },
      interpret: Self.interpret(now: date)
    )
    switch outcome {
    case .quota(let quota, let endpoint):
      preferredEndpoints[accountID] = endpoint
      return quota
    case .forbidden:
      return ProviderQuota(lastUpdated: date, isForbidden: true)
    case .failed:
      return nil
    }
  }

  nonisolated static func interpret(now: Date) -> @Sendable (Data) -> CodingPlanEndpointProbe
    .Answer
  {
    { data in
      if let code = MiniMaxQuotaMapper.statusCode(data),
        MiniMaxQuotaMapper.authenticationFailureCodes.contains(code)
      {
        return .unauthorized
      }
      return MiniMaxQuotaMapper.map(data, now: now).map { .quota($0) } ?? .failure
    }
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
