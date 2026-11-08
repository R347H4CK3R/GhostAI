import XCTest
@testable import AsterionVeyra

final class AppUpdateTests: XCTestCase {
    private func fixture(tag: String = "ios-build-40", url: String? = nil,
                         draft: Bool = false, prerelease: Bool = false, size: Int = 100) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [["name": "AsterionVeyra-unsigned.ipa", "size": size,
                        "browser_download_url": url ?? "https://github.com/R347H4CK3R/GhostAI/releases/download/\(tag)/AsterionVeyra-unsigned.ipa"]]
        ])
    }
    func testNewBuildProducesExactSideStoreHandoff() throws {
        let update = try XCTUnwrap(AppUpdatePolicy.candidate(fixture(), installedBuild: "35"))
        XCTAssertEqual(update.build, 40)
        let components = try XCTUnwrap(URLComponents(url: update.installURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "sidestore")
        XCTAssertEqual(components.host, "install")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "url", value: update.downloadURL.absoluteString)])
    }
    func testEqualAndOlderBuildsAreNotOffered() throws {
        XCTAssertNil(try AppUpdatePolicy.candidate(fixture(), installedBuild: "40"))
        XCTAssertNil(try AppUpdatePolicy.candidate(fixture(), installedBuild: "41"))
    }
    func testRejectsUnpublishedOrMalformedCandidates() throws {
        for data in [
            try fixture(draft: true), try fixture(prerelease: true),
            try fixture(tag: "ios-build-040"), try fixture(tag: "unrelated-40"),
            try fixture(url: "https://example.com/app.ipa"),
            try fixture(url: "https://github.com/R347H4CK3R/GhostAI/releases/download/ios-build-39/AsterionVeyra-unsigned.ipa"),
            try fixture(size: 0), try fixture(size: 536_870_913),
            Data(repeating: 32, count: 262_145), Data("{}".utf8)
        ] {
            XCTAssertThrowsError(try AppUpdatePolicy.candidate(data, installedBuild: "35"))
        }
        XCTAssertThrowsError(try AppUpdatePolicy.candidate(fixture(), installedBuild: "unknown"))
    }
}
