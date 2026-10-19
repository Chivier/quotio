import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3
import XCTest

@testable import QuotioInfrastructure

final class DevinQuotaFetcherTests: XCTestCase {
  func testDevinParsesQuotedCommentsAndRejectsInsecureServerURL() {
    let native = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native-token"
      api_server_url = "https://server.codeium.test/"
      """)
    let insecure = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native-token"
      api_server_url = "http://server.codeium.test"
      """)
    let quotedHash = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native#token" # account credential
      api_server_url = "https://server.codeium.test/path#fragment" # API endpoint
      """)

    XCTAssertEqual(
      native,
      DevinCredential(apiKey: "native-token", apiServerURL: "https://server.codeium.test"))
    XCTAssertNil(insecure?.apiServerURL)
    XCTAssertEqual(
      quotedHash,
      DevinCredential(
        apiKey: "native#token", apiServerURL: "https://server.codeium.test/path#fragment"))
  }

  func testDevinPreservesNativeSourcesScopeMappingAndRequestInBothModes() async throws {
    let files = ProviderFileReader(
      data: Data(
        "windsurf_api_key = \"native#token\" # comment\napi_server_url = \"https://server.test/\""
          .utf8))
    let session = ProviderSession { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://server.test/exa.seat_management_pb.SeatManagementService/GetUserStatus")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
      let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertEqual((body["metadata"] as? [String: Any])?["apiKey"] as? String, "native#token")
      return (
        #"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max","hideDailyQuota":true},"dailyQuotaRemainingPercent":30,"overageBalanceMicros":"1250000"}}}"#,
        200
      )
    }
    let fetcher = DevinQuotaFetcher(
      files: files, database: ProviderDevinDatabase(nil), session: session)
    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .devin, scope: .account("Devin"), mode: mode))
      XCTAssertEqual(output.credentialAvailability, .present)
      XCTAssertEqual(output.quotas["Devin"]?.planType, "Max")
      XCTAssertEqual(
        output.quotas["Devin"]?.models.first { $0.name == "devin-weekly" }?.percentage, 30)
      XCTAssertEqual(
        output.quotas["Devin"]?.models.first { $0.name == "devin-extra-balance" }?.presentation,
        .amount(value: 1.25, unit: .usd, semantics: .balance))
    }
    let excluded = try await fetcher.fetch(
      .init(provider: .devin, scope: .account("Other"), mode: .monitor))
    XCTAssertEqual(excluded.credentialAvailability, .missing)
  }

  func testDevinFallsBackAfterForbiddenAndReadsSQLiteReadOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.vscdb").path
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{\"apiKey\":\"db-token\"}')",
        nil, nil, nil), SQLITE_OK)
    sqlite3_close(database)
    XCTAssertEqual(
      LocalDevinCredentialDatabaseReader().credential(path: path),
      DevinCredential(apiKey: "db-token", apiServerURL: nil))

    let files = ProviderFileReader(data: Data("windsurf_api_key = \"bad\"".utf8))
    let session = ProviderSession { request in
      let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      let token = (body["metadata"] as! [String: Any])["apiKey"] as! String
      return token == "bad"
        ? ("", 403) : (#"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":72}}}"#, 200)
    }
    let output = try await DevinQuotaFetcher(
      files: files, database: LocalDevinCredentialDatabaseReader(), session: session,
      stateDBPath: path
    ).fetch(.init(provider: .devin, mode: .monitor))
    XCTAssertEqual(output.quotas["Devin"]?.isForbidden, false)
    XCTAssertEqual(output.quotas["Devin"]?.models.first?.percentage, 72)
  }

  func testDevinMapsRejectedCredentialsButIgnoresOtherHTTPFailures() async throws {
    for status in [401, 403] {
      let output = try await DevinQuotaFetcher(
        files: ProviderFileReader(data: Data("windsurf_api_key = \"token\"".utf8)),
        database: ProviderDevinDatabase(nil),
        session: ProviderSession { _ in ("", status) }
      ).fetch(.init(provider: .devin, mode: .monitor))
      XCTAssertEqual(output.quotas["Devin"]?.isForbidden, true)
      XCTAssertEqual(output.credentialAvailability, .present)
    }

    let failed = try await DevinQuotaFetcher(
      files: ProviderFileReader(data: Data("windsurf_api_key = \"token\"".utf8)),
      database: ProviderDevinDatabase(nil),
      session: ProviderSession { _ in ("", 500) }
    ).fetch(.init(provider: .devin, mode: .monitor))
    XCTAssertTrue(failed.quotas.isEmpty)
    XCTAssertEqual(failed.credentialAvailability, .present)
  }
}

private actor ProviderFileReader: QuotaCredentialFileReading {
  let data: Data?
  init(data: Data?) { self.data = data }
  func read(path: String) -> Data? { data }
}

private struct ProviderDevinDatabase: DevinCredentialDatabaseReading {
  let value: DevinCredential?
  init(_ value: DevinCredential?) { self.value = value }
  func credential(path: String) -> DevinCredential? { value }
}

private actor ProviderSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  let handler: Handler
  init(_ handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) -> (Data, URLResponse) {
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}
