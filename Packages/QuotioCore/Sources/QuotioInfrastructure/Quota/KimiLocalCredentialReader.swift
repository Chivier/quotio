import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain

/// A Kimi credential owned by a tool on this Mac rather than by Quotio.
struct KimiLocalCredential: Equatable, Sendable {
  enum Origin: Equatable, Sendable {
    /// Kimi Code CLI OAuth login; requests must carry the CLI device identity.
    case codeCLI
    /// API key from the legacy Kimi CLI `config.toml`.
    case legacyConfig
  }

  let accountKey: String
  let displayName: String
  let accessToken: String
  let sourcePath: String
  let origin: Origin
  let deviceID: String?
  let expiresAt: Date?

  /// A token within a minute of expiry is treated as expired; the CLI refreshes it on use.
  func isExpired(at now: Date) -> Bool {
    expiresAt.map { $0 <= now.addingTimeInterval(60) } ?? false
  }

  var account: Account {
    Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.kimi.rawValue),
      accountKey: accountKey,
      displayName: displayName,
      source: .nativeCredential,
      credentialReference: sourcePath
    )
  }
}

/// Reads Kimi Code CLI (`~/.kimi-code`) and legacy Kimi CLI (`~/.kimi/config.toml`)
/// credentials. Expired CLI logins are still returned so the account stays visible and
/// can be reported as needing a new login instead of silently disappearing.
struct KimiLocalCredentialReader: Sendable {
  static let cliAccountKey = "Kimi Code"
  static let cliCredentialPath = ".kimi-code/credentials/kimi-code.json"
  static let cliDeviceIDPath = ".kimi-code/device_id"
  static let legacyConfigPath = ".kimi/config.toml"

  private let homeDirectory: URL
  private let files: any QuotaCredentialFileReading

  init(homeDirectory: URL, files: any QuotaCredentialFileReading) {
    self.homeDirectory = homeDirectory
    self.files = files
  }

  func loadAll() async -> [KimiLocalCredential] {
    var credentials: [KimiLocalCredential] = []
    if let cli = await loadCLICredential() { credentials.append(cli) }
    credentials.append(contentsOf: await loadLegacyConfig())
    return credentials
  }

  func accounts() async -> [Account] {
    await loadAll().map(\.account)
  }

  func loadCLICredential() async -> KimiLocalCredential? {
    let path = homeDirectory.appendingPathComponent(Self.cliCredentialPath).path
    guard let data = await files.read(path: path),
      let json = CodingPlanJSON.object(data),
      let token = Self.cleaned(json["access_token"] as? String)
    else { return nil }
    let expiresAt = CodingPlanJSON.number(json["expires_at"]).map(CodingPlanJSON.date(epoch:))
    let deviceIDPath = homeDirectory.appendingPathComponent(Self.cliDeviceIDPath).path
    let deviceID = await files.read(path: deviceIDPath).flatMap {
      Self.cleaned(String(data: $0, encoding: .utf8))
    }
    return KimiLocalCredential(
      accountKey: Self.cliAccountKey,
      displayName: "Kimi Code CLI",
      accessToken: token,
      sourcePath: path,
      origin: .codeCLI,
      deviceID: deviceID,
      expiresAt: expiresAt
    )
  }

  func loadLegacyConfig() async -> [KimiLocalCredential] {
    let path = homeDirectory.appendingPathComponent(Self.legacyConfigPath).path
    guard let data = await files.read(path: path),
      let content = String(data: data, encoding: .utf8)
    else { return [] }
    return Self.parseLegacyConfig(content, path: path)
  }

  static func parseLegacyConfig(_ content: String, path: String) -> [KimiLocalCredential] {
    var credentials: [KimiLocalCredential] = []
    var section: String?
    var sectionType: String?
    var sectionBaseURL: String?
    var sectionKey: String?

    func flush() {
      defer {
        sectionType = nil
        sectionBaseURL = nil
        sectionKey = nil
      }
      guard let token = cleaned(sectionKey) else { return }
      let normalizedSection = section?.lowercased() ?? ""
      let normalizedBaseURL = sectionBaseURL?.lowercased() ?? ""
      guard
        sectionType?.lowercased() == "kimi"
          || normalizedSection.contains("kimi")
          || normalizedBaseURL.contains("kimi.com/coding")
          || normalizedBaseURL.contains("moonshot")
          || token.hasPrefix("sk-kimi")
      else { return }
      let label = cleaned(section) ?? cliAccountKey
      credentials.append(
        KimiLocalCredential(
          accountKey: "\(label) · \(fingerprint(token))",
          displayName: label,
          accessToken: token,
          sourcePath: path,
          origin: .legacyConfig,
          deviceID: nil,
          expiresAt: nil
        ))
    }

    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        flush()
        section = String(line.dropFirst().dropLast())
        continue
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      let value = tomlString(String(line[line.index(after: equals)...]))
      switch key {
      case "api_key", "apikey": sectionKey = value
      case "type": sectionType = value
      case "base_url", "baseurl": sectionBaseURL = value
      default: break
      }
    }
    flush()

    var seen = Set<String>()
    return credentials.filter { seen.insert($0.accessToken).inserted }
  }

  /// A short, non-reversible label suffix that keeps two keys in one section apart.
  private static func fingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  private static func tomlString(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    guard let quote = value.first, quote == "\"" || quote == "'" else {
      if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
      return value.trimmingCharacters(in: .whitespaces)
    }
    value.removeFirst()
    return value.firstIndex(of: quote).map { String(value[..<$0]) } ?? value
  }

  static func cleaned(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
