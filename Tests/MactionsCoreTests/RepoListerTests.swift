import XCTest

@testable import MactionsCore

final class RepoListerTests: XCTestCase {
  func testReposRequestShape() {
    let req = GitHubRepoLister(token: "tok_x").reposRequest(page: 2)
    XCTAssertEqual(req.httpMethod, "GET")
    let url = req.url?.absoluteString ?? ""
    XCTAssertTrue(url.hasPrefix("https://api.github.com/user/repos?"))
    XCTAssertTrue(url.contains("per_page=100"))
    XCTAssertTrue(url.contains("page=2"))
    XCTAssertTrue(url.contains("affiliation=owner,collaborator,organization_member"))
    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_x")
  }

  func testDecodeAdminReposKeepsOnlyAdminRepos() throws {
    let json = """
      [
        {"name":"sweep-collector","private":true,"owner":{"login":"Kyter-com"},"permissions":{"admin":true}},
        {"name":"read-only","private":false,"owner":{"login":"someorg"},"permissions":{"admin":false}},
        {"name":"no-perms","private":false,"owner":{"login":"x"}}
      ]
      """
    let repos = try GitHubRepoLister.decodeAdminRepos(Data(json.utf8))
    XCTAssertEqual(repos.map(\.fullName), ["Kyter-com/sweep-collector"])
    XCTAssertEqual(repos.first?.isPrivate, true)
  }

  func testRepoRefIdentityIgnoresPrivacy() {
    // Equality is owner/name only, so a persisted selection (privacy unknown)
    // still matches the fetched repo.
    let persisted = RepoRef(fullName: "Kyter-com/sweep-collector")
    let fetched = RepoRef(owner: "Kyter-com", name: "sweep-collector", isPrivate: true)
    XCTAssertEqual(persisted, fetched)
    XCTAssertTrue([fetched].contains(persisted!))
  }
}
