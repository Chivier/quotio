import Foundation
import QuotioDomain

/// Queries a provider that serves the same account from several regional hosts.
///
/// A key belongs to exactly one region, so the host that last answered for an account is
/// tried first and the others are only a fallback. The account is reported as forbidden
/// only when every host that was tried refused the credential; a transport or server
/// failure on any host makes the outcome a plain failure, because that host might have
/// been the right one.
struct CodingPlanEndpointProbe: Sendable {
  enum Answer: Sendable {
    case quota(ProviderQuota)
    case unauthorized
    case failure
  }

  enum Outcome: Sendable {
    case quota(ProviderQuota, endpoint: URL)
    case forbidden
    case failed
  }

  let endpoints: [URL]
  let session: any QuotaHTTPSession

  func run(
    preferred: URL?,
    makeRequest: (URL) -> URLRequest,
    interpret: (Data) -> Answer
  ) async -> Outcome {
    var refused = 0
    var tried = 0
    for endpoint in Self.ordered(endpoints, preferred: preferred) {
      tried += 1
      guard let (data, response) = try? await session.data(for: makeRequest(endpoint)),
        let http = response as? HTTPURLResponse
      else { continue }
      if http.statusCode == 401 || http.statusCode == 403 {
        refused += 1
        continue
      }
      guard 200...299 ~= http.statusCode else { continue }
      switch interpret(data) {
      case .quota(let quota): return .quota(quota, endpoint: endpoint)
      case .unauthorized: refused += 1
      case .failure: continue
      }
    }
    return tried > 0 && refused == tried ? .forbidden : .failed
  }

  static func ordered(_ endpoints: [URL], preferred: URL?) -> [URL] {
    guard let preferred, endpoints.contains(preferred) else { return endpoints }
    return [preferred] + endpoints.filter { $0 != preferred }
  }
}
