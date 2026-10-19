import Darwin
import Foundation

/// The device identity Kimi Code expects on OAuth-token requests.
///
/// The CLI's own `device_id` is preferred. Otherwise Quotio sends a random install
/// identifier persisted under its Application Support directory, so the value is stable
/// across launches and never derived from a credential.
public actor KimiDeviceIdentity {
  private let url: URL
  private let makeIdentifier: @Sendable () -> String
  private var cached: String?

  public init(
    url: URL? = nil,
    makeIdentifier: @escaping @Sendable () -> String = {
      UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
  ) {
    self.url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Quotio/Monitor/kimi-device-id")
    self.makeIdentifier = makeIdentifier
  }

  /// Quotio's install identifier, created on first use.
  public func installIdentifier() -> String {
    if let cached { return cached }
    if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
      values.isSymbolicLink != true,
      let data = try? Data(contentsOf: url),
      let stored = KimiLocalCredentialReader.cleaned(String(data: data, encoding: .utf8))
    {
      cached = stored
      return stored
    }
    let identifier = makeIdentifier()
    // Best effort: an unwritable directory still yields a stable value for this run.
    try? SecureAtomicFileWriter.write(Data(identifier.utf8), to: url)
    cached = identifier
    return identifier
  }

  public func deviceID(preferring cliDeviceID: String?) -> String {
    KimiLocalCredentialReader.cleaned(cliDeviceID) ?? installIdentifier()
  }

  /// Headers the Kimi Code CLI sends; the service rejects OAuth tokens without them.
  nonisolated static func headers(deviceID: String, appVersion: String) -> [String: String] {
    let version = asciiHeaderValue(appVersion)
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    return [
      "User-Agent": "Quotio/\(version)",
      "X-Msh-Platform": "kimi_code_cli",
      "X-Msh-Version": version,
      "X-Msh-Device-Name": asciiHeaderValue(hostName),
      "X-Msh-Device-Model": asciiHeaderValue("macOS \(osVersion) \(architectureName)"),
      "X-Msh-Os-Version": asciiHeaderValue(osVersion),
      "X-Msh-Device-Id": asciiHeaderValue(deviceID),
    ]
  }

  private nonisolated static func asciiHeaderValue(_ raw: String) -> String {
    var ascii = ""
    for scalar in raw.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
      ascii.unicodeScalars.append(scalar)
    }
    let value = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "unknown" : value
  }

  private nonisolated static var architectureName: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }

  private nonisolated static var hostName: String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
