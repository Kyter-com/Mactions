import XCTest

@testable import MactionsCore

final class GitHubRequestTests: XCTestCase {
  let client = GitHubClient(owner: "Kyter-com", repo: "sweep-collector", token: "tok_123")

  func testJITConfigRequestShape() throws {
    let req = try client.jitConfigRequest(name: "mactions-abc", labels: ["self-hosted", "macOS"])
    XCTAssertEqual(req.httpMethod, "POST")
    XCTAssertEqual(
      req.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners/generate-jitconfig"
    )
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
    XCTAssertEqual(req.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")

    let body = try XCTUnwrap(req.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["name"] as? String, "mactions-abc")
    XCTAssertEqual(json["runner_group_id"] as? Int, 1)
    XCTAssertEqual(json["work_folder"] as? String, "_work")
    XCTAssertEqual(json["labels"] as? [String], ["self-hosted", "macOS"])
  }

  func testListAndDeleteRequestShape() {
    let list = client.listRunnersRequest()
    XCTAssertEqual(list.httpMethod, "GET")
    XCTAssertEqual(
      list.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners?per_page=100"
    )

    let del = client.deleteRunnerRequest(id: 42)
    XCTAssertEqual(del.httpMethod, "DELETE")
    XCTAssertEqual(
      del.url?.absoluteString,
      "https://api.github.com/repos/Kyter-com/sweep-collector/actions/runners/42"
    )
    XCTAssertEqual(del.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
  }

  func testDeviceFlowRequestShapes() {
    let codeReq = GitHubAuth.deviceCodeRequest(clientId: "Iv1.abc", scope: "repo")
    XCTAssertEqual(codeReq.httpMethod, "POST")
    XCTAssertEqual(codeReq.url, GitHubAuth.deviceCodeURL)
    XCTAssertEqual(codeReq.value(forHTTPHeaderField: "Accept"), "application/json")
    let codeBody = (try? JSONSerialization.jsonObject(with: codeReq.httpBody ?? Data())) as? [String: String]
    XCTAssertEqual(codeBody?["client_id"], "Iv1.abc")
    XCTAssertEqual(codeBody?["scope"], "repo")

    let tokenReq = GitHubAuth.accessTokenRequest(clientId: "Iv1.abc", deviceCode: "dev_1")
    let tokenBody = (try? JSONSerialization.jsonObject(with: tokenReq.httpBody ?? Data())) as? [String: String]
    XCTAssertEqual(tokenBody?["device_code"], "dev_1")
    XCTAssertEqual(tokenBody?["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
  }

  func testRequestDeviceCodeRejectsEmptyClientId() async {
    do {
      _ = try await GitHubAuth.requestDeviceCode(clientId: "")
      XCTFail("expected noClientId")
    } catch {
      XCTAssertEqual(error as? GitHubAuth.AuthError, .noClientId)
    }
  }
}
