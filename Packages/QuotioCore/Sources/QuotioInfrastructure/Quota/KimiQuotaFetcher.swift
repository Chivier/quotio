import Foundation
import QuotioApplication
import QuotioDomain

/// Kimi Code subscription usage from the Kimi Code CLI login, the legacy Kimi CLI config,
/// CLIProxyAPI `kimi` auth files, and (in Monitor mode) Quotio-owned API keys.
public actor KimiQuotaFetcher: QuotaFetching {
  public static let defaultEndpoints = [
    URL(string: "https://api.kimi.com/coding/v1/usages")!,
    URL(string: "https://api.moonshot.ai/v1/usages")!,
  ]

  private struct Candidate {
    let account: Account
    let token: String
    let expiresAt: Date?
    /// The device ID recorded by the tool that owns the token, if any.
    let deviceID: String?
    /// OAuth tokens need the CLI device headers; API keys are sent without them.
    let usesDeviceIdentity: Bool
  }

  public nonisolated let provider = QuotaProvider.kimi
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let authFiles: any AuthFileRepository
  private let localCredentials: KimiLocalCredentialReader
  private let deviceIdentity: KimiDeviceIdentity
  private let probe: CodingPlanEndpointProbe
  private let appVersion: String
  private let now: @Sendable () -> Date
  /// The regional host that last answered for each account ID.
  private var preferredEndpoints: [String: URL] = [:]

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    authFiles: any AuthFileRepository,
    deviceIdentity: KimiDeviceIdentity,
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    endpoints: [URL] = KimiQuotaFetcher.defaultEndpoints,
    appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? "development",
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.authFiles = authFiles
    self.localCredentials = KimiLocalCredentialReader(homeDirectory: homeDirectory, files: files)
    self.deviceIdentity = deviceIdentity
    self.probe = CodingPlanEndpointProbe(endpoints: endpoints, session: session)
    self.appVersion = appVersion
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let disabled = await metadata.disabledAccountIDs()
    var candidates: [Candidate] = []
    var credentialAccountKeys = Set<String>()
    let inScope: (Account) -> Bool = {
      !disabled.contains($0.id) && Self.includes($0.accountKey, in: request.scope)
    }

    for local in await localCredentials.loadAll() where inScope(local.account) {
      candidates.append(
        Candidate(
          account: local.account, token: local.accessToken, expiresAt: local.expiresAt,
          deviceID: local.deviceID, usesDeviceIdentity: local.origin == .codeCLI))
    }

    for file in await authFiles.scanAllAuthFiles()
    where file.providerID.rawValue == provider.rawValue {
      let account = LocalAccountDiscovery.legacyAccount(file)
      guard inScope(account), let credential = await authFiles.readCredential(from: file),
        let token = KimiLocalCredentialReader.cleaned(credential.accessToken)
      else { continue }
      candidates.append(
        Candidate(
          account: account, token: token, expiresAt: file.expired,
          deviceID: credential.extras?["device_id"], usesDeviceIdentity: true))
    }

    if request.mode == .monitor {
      for account in await vault.accounts()
      where account.providerID.rawValue == provider.rawValue && inScope(account) {
        var credential = await vault.credential(for: account.id)
        if credential == nil, request.allowsUserInteraction, case .account = request.scope {
          credential = await vault.credentialForUserInitiatedAccess(for: account.id)
        }
        guard let token = KimiLocalCredentialReader.cleaned(credential?.accessToken) else {
          // An item this build cannot read still names a live account; keep its last
          // quota instead of purging it.
          if await vault.credentialState(for: account.id) == .unreadable {
            credentialAccountKeys.insert(account.accountKey)
          }
          continue
        }
        candidates.append(
          Candidate(
            account: account, token: token, expiresAt: nil, deviceID: nil,
            usesDeviceIdentity: false))
      }
    }

    var quotas: [String: ProviderQuota] = [:]
    for candidate in candidates where quotas[candidate.account.accountKey] == nil {
      credentialAccountKeys.insert(candidate.account.accountKey)
      if let quota = await quota(for: candidate) {
        quotas[candidate.account.accountKey] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: credentialAccountKeys.isEmpty ? .missing : .present,
      credentialAccountKeys: credentialAccountKeys
    )
  }

  private func quota(for candidate: Candidate) async -> ProviderQuota? {
    let date = now()
    if let expiresAt = candidate.expiresAt, expiresAt <= date.addingTimeInterval(60) {
      // The token cannot work until the owning tool signs in again; surface that.
      return ProviderQuota(lastUpdated: date, isForbidden: true, tokenExpiresAt: expiresAt)
    }
    var headers = ["User-Agent": "Quotio-KimiMonitor/1.0"]
    if candidate.usesDeviceIdentity {
      let deviceID = await deviceIdentity.deviceID(preferring: candidate.deviceID)
      headers = KimiDeviceIdentity.headers(deviceID: deviceID, appVersion: appVersion)
    }
    let outcome = await probe.run(
      preferred: preferredEndpoints[candidate.account.id],
      makeRequest: { endpoint in
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(candidate.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
      },
      interpret: { data in
        KimiQuotaMapper.map(data, now: date).map { .quota($0) } ?? .failure
      }
    )
    switch outcome {
    case .quota(var quota, let endpoint):
      preferredEndpoints[candidate.account.id] = endpoint
      quota.tokenExpiresAt = candidate.expiresAt
      return quota
    case .forbidden:
      return ProviderQuota(lastUpdated: date, isForbidden: true, tokenExpiresAt: candidate.expiresAt)
    case .failed:
      return nil
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
