import XCTest
import CryptoKit
@testable import AsterionVeyra

private actor SyncRequestRecorder {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    func count(_ method: String) -> Int { requests.filter { $0.httpMethod == method }.count }
}

final class PrivateMemorySyncTransportTests: XCTestCase {
    private let configuration = PrivateMemorySyncConfiguration(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false)
    private func authorization() throws -> GitHubAuthSession { try GitHubAuthSession(token: "github_pat_SYNTHETIC_NOT_A_REAL_CREDENTIAL") }
    private func repository(privateRepo: Bool = true, id: Int = 123) -> Data {
        Data("{\"id\":\(id),\"full_name\":\"owner/private-memory\",\"private\":\(privateRepo),\"default_branch\":\"main\",\"archived\":false,\"disabled\":false,\"owner\":{\"id\":456},\"permissions\":{\"push\":true}}".utf8)
    }
    func testPublicRepositoryDeniesBeforeAnyContentWrite() async throws {
        let recorder = SyncRequestRecorder(), data = repository(privateRepo: false)
        let transport = PrivateMemorySyncTransport { request, _, _ in await recorder.append(request); return .init(status: 200, data: data) }
        let client = PrivateMemorySyncClient(auth: try authorization(), transport: transport)
        do { _ = try await client.put(Data(repeating: 0, count: 100), configuration: configuration, expectedSHA: nil); XCTFail("Public destination must be blocked") }
        catch { XCTAssertEqual(error as? PrivateMemorySyncFailure, .privateRepository) }
        let writes = await recorder.count("PUT"); XCTAssertEqual(writes, 0)
    }
    func testReplacedRepositoryDeniesBeforeWrite() async throws {
        let recorder = SyncRequestRecorder(), data = repository(id: 999)
        let transport = PrivateMemorySyncTransport { request, _, _ in await recorder.append(request); return .init(status: 200, data: data) }
        let client = PrivateMemorySyncClient(auth: try authorization(), transport: transport)
        do { _ = try await client.put(Data(repeating: 0, count: 100), configuration: configuration, expectedSHA: nil); XCTFail("Changed identity must be blocked") }
        catch { XCTAssertEqual(error as? PrivateMemorySyncFailure, .repositoryChanged) }
        let writes = await recorder.count("PUT"); XCTAssertEqual(writes, 0)
    }
    func testCompareAndSwapConflictIsReturnedWithoutBlindRetry() async throws {
        let recorder = SyncRequestRecorder(), data = repository()
        let transport = PrivateMemorySyncTransport { request, _, _ in
            await recorder.append(request)
            if request.httpMethod == "PUT" {
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["sha"] as? String, String(repeating: "a", count: 40))
                XCTAssertEqual(object["branch"] as? String, "main")
                return .init(status: 409, data: Data())
            }
            return .init(status: 200, data: data)
        }
        let client = PrivateMemorySyncClient(auth: try authorization(), transport: transport)
        let committed = try await client.put(Data(repeating: 0, count: 100), configuration: configuration, expectedSHA: String(repeating: "a", count: 40))
        XCTAssertFalse(committed)
        let writes = await recorder.count("PUT"); XCTAssertEqual(writes, 1)
    }
    func testLargeFileUsesPinnedRawBlobAndVerifiesObjectHash() async throws {
        let encrypted = Data(repeating: 0x41, count: 1_100_000), repo = repository()
        let sha = Insecure.SHA1.hash(data: Data("blob \(encrypted.count)\0".utf8) + encrypted).map { String(format: "%02x", $0) }.joined()
        let metadata = try JSONSerialization.data(withJSONObject: ["type": "file", "path": "veyra-memory/v1.sync", "sha": sha, "size": encrypted.count, "encoding": "none", "content": ""])
        let transport = PrivateMemorySyncTransport { request, cap, _ in
            let path = try XCTUnwrap(request.url?.path)
            if path.contains("/git/blobs/") {
                XCTAssertEqual(path, "/repos/owner/private-memory/git/blobs/" + sha)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
                XCTAssertEqual(cap, PrivateMemorySyncPolicy.maximumDocumentBytes + 58)
                return .init(status: 200, data: encrypted)
            }
            return .init(status: 200, data: path.contains("/contents/") ? metadata : repo)
        }
        let value = try await PrivateMemorySyncClient(auth: authorization(), transport: transport).fetch(configuration)
        XCTAssertEqual(value.sha, sha); XCTAssertEqual(value.encrypted, encrypted)
    }
    func testServerCooldownParsesSafelyAndCapsExtremeValues() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PrivateMemorySyncCooldown.deadline(retryAfter: "900", reset: nil, now: now), now.addingTimeInterval(900))
        XCTAssertEqual(PrivateMemorySyncCooldown.deadline(retryAfter: "bad", reset: "1700001200", now: now), now.addingTimeInterval(1200))
        XCTAssertEqual(PrivateMemorySyncCooldown.deadline(retryAfter: "inf", reset: "nan", now: now), now.addingTimeInterval(300))
        XCTAssertEqual(PrivateMemorySyncCooldown.deadline(retryAfter: "999999999999", reset: nil, now: now), now.addingTimeInterval(86_400))
    }
    func testForeignURLNeverReceivesAuthorization() throws {
        let auth = try authorization()
        for url in ["http://api.github.com/user", "https://api.github.com.evil.example/user", "https://user@api.github.com/user"] {
            XCTAssertThrowsError(try GitHubRequestPolicy.request(url: XCTUnwrap(URL(string: url)), authentication: auth))
        }
    }
}
