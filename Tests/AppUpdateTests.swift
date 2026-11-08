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
    func testRejectsMissingAndDuplicateIPAAssets() throws {
        let data = try fixture()
        var release = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let assets = try XCTUnwrap(release["assets"] as? [[String: Any]])
        for replacement in [[], assets + assets] {
            release["assets"] = replacement
            let changed = try JSONSerialization.data(withJSONObject: release)
            XCTAssertThrowsError(try AppUpdatePolicy.candidate(changed, installedBuild: "35"))
        }
    }

    func testRejectsTemporaryOrCredentialBearingAssetURLs() throws {
        for url in [
            "https://github.com/R347H4CK3R/GhostAI/actions/runs/40/artifacts/123",
            "https://github.com/R347H4CK3R/GhostAI/releases/download/ios-build-40/AsterionVeyra-unsigned.ipa?token=synthetic",
            "https://example@github.com/R347H4CK3R/GhostAI/releases/download/ios-build-40/AsterionVeyra-unsigned.ipa",
            "http://github.com/R347H4CK3R/GhostAI/releases/download/ios-build-40/AsterionVeyra-unsigned.ipa"
        ] {
            XCTAssertThrowsError(try AppUpdatePolicy.candidate(fixture(url: url), installedBuild: "35"))
        }
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

@MainActor final class AppUpdateCheckTaskTests: XCTestCase {
    func testRepeatedStartRetainsAndCancelsTheOriginalCheck() async {
        let task = AppUpdateCheckTask()
        let started = expectation(description: "Original update check started")
        let cancelled = expectation(description: "Original check received cancellation")
        var starts = 0
        task.start {
            starts += 1
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                XCTFail("The check must be cancelled before its timeout")
            } catch {
                XCTAssertTrue(Task.isCancelled)
                cancelled.fulfill()
            }
        }
        // Both starts occur before the first unstructured Task can be scheduled.
        task.start { starts += 1 }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(starts, 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCancellationBeforeTheCheckStartsIsRetained() async {
        let task = AppUpdateCheckTask()
        let cancelled = expectation(description: "Early cancellation reaches check")
        task.start {
            XCTAssertTrue(Task.isCancelled)
            cancelled.fulfill()
        }
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }
}
