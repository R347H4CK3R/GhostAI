import XCTest
import CryptoKit
@testable import AsterionVeyra

final class PairedExecutionProtocolTests: XCTestCase {
    private let host = "11111111-1111-4111-8111-111111111111"
    private let device = "33333333-3333-4333-8333-333333333333"
    private let request = "44444444-4444-4444-8444-444444444444"
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "paired-execution-v1", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testIndependentPythonPairFrameProofAndSignatureFixture() throws {
        let values = try fixture()
        func text(_ key: String) throws -> String { try XCTUnwrap(values[key] as? String) }
        let descriptor: [String: Any] = ["v": 1, "host_id": try text("host_id"), "invite_id": try text("invite_id"),
            "invite_secret": try text("invite_secret"), "origin": "https://192.168.1.20:8443",
            "tls_leaf_sha256": String(repeating: "a", count: 64), "expires_at_ms": 253402300799999 as Int64]
        let invitation = try PairedExecutionInvitation.parse(JSONSerialization.data(withJSONObject: descriptor), nowMilliseconds: 0)
        let frame = try PairedExecutionWire.pairFrame(hostID: text("host_id"), inviteID: text("invite_id"), clientNonce: text("client_nonce"),
            clientPublicKey: text("client_public_key"), deviceNameSHA256: PairedExecutionCrypto.sha256Hex(Data(text("device_name").utf8)))
        XCTAssertEqual(frame, try Data(text("pair_frame").utf8))
        let proof = try PairedExecutionCrypto.pairProof(invitation: invitation, clientNonce: text("client_nonce"), clientPublicKey: text("client_public_key"), deviceName: text("device_name"))
        XCTAssertEqual(proof.proof, try text("proof")); XCTAssertEqual(proof.signedBytes, try Data(text("pair_signed_bytes").utf8))
        XCTAssertEqual(proof.safetyCode, try text("safety_code"))
        try PairedExecutionCrypto.verify(signature: text("pair_signature"), publicKey: text("client_public_key"), message: proof.signedBytes)
        XCTAssertFalse(String(reflecting: invitation).contains(try text("invite_secret")))
    }
    func testIndependentPythonRequestFrameAndSignatureFixture() throws {
        let values = try fixture()
        func text(_ key: String) throws -> String { try XCTUnwrap(values[key] as? String) }
        let frame = try PairedExecutionCrypto.requestFrame(hostID: text("host_id"), deviceID: text("device_id"), sequence: text("sequence"),
            requestID: text("request_id"), route: text("route"), body: Data(text("request_body").utf8))
        XCTAssertEqual(frame, try Data(text("request_frame").utf8))
        try PairedExecutionCrypto.verify(signature: text("request_signature"), publicKey: text("client_public_key"), message: frame)
        XCTAssertThrowsError(try PairedExecutionCrypto.verify(signature: text("request_signature"), publicKey: text("client_public_key"), message: frame + Data([0])))
    }
    func testSharedUnicodeDeviceNamePolicyFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "paired-device-names-v1", withExtension: "json"))
        let values = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        for name in try XCTUnwrap(values["accepted"]) { XCTAssertEqual(try PairedExecutionWire.deviceName(name), name) }
        for name in try XCTUnwrap(values["rejected"]) { XCTAssertThrowsError(try PairedExecutionWire.deviceName(name)) }
    }
    func testHighSMalleatedPythonSignatureIsRejected() throws {
        let values = try fixture(); let signature = try XCTUnwrap(values["request_signature"] as? String)
        var bytes = Array(try PairedExecutionWire.signatureBytes(signature)); let low = Array(bytes.suffix(32)); var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            let difference = Int(PairedExecutionWire.order[index]) - Int(low[index]) - borrow
            bytes[index + 32] = UInt8((difference + 256) % 256); borrow = difference < 0 ? 1 : 0
        }
        XCTAssertThrowsError(try PairedExecutionWire.signatureBytes(PairedExecutionWire.base64URL(Data(bytes))))
    }
    func testOriginIsCanonicalPrivateIPv4HTTPSOnly() throws {
        XCTAssertEqual(try PairedExecutionWire.localIPv4Origin("https://192.168.1.20:8443"), "https://192.168.1.20:8443")
        for origin in ["http://192.168.1.20:8443", "https://localhost:8443", "https://127.0.0.1:8443", "https://8.8.8.8:8443", "https://192.168.01.20:8443", "https://192.168.1.20", "https://192.168.1.20:08443", "https://192.168.1.20:8443/", "https://192.168.1.20:8443?q=1", "https://u@192.168.1.20:8443", "https://192.168.1.255:8443"] {
            XCTAssertThrowsError(try PairedExecutionWire.localIPv4Origin(origin))
        }
    }
    func testExactRequestDomainAndTrailingNewline() throws {
        let digest = String(repeating: "a", count: 64)
        let bytes = try PairedExecutionWire.requestFrame(hostID: host, deviceID: device, sequence: "1", requestID: request, route: "/v1/jobs/get", bodySHA256: digest)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "VEYRA-REQUEST-V1\n\(host)\n\(device)\n1\n\(request)\nPOST\n/v1/jobs/get\n\(digest)\n")
    }
    func testUnknownRoutesAndNoncanonicalSequencesFail() {
        for sequence in ["0", "01", "-1", "1.0", "9223372036854775808"] { XCTAssertThrowsError(try PairedExecutionWire.sequence(sequence)) }
        XCTAssertThrowsError(try PairedExecutionWire.requestFrame(hostID: host, deviceID: device, sequence: "1", requestID: request, route: "/v1/admin", bodySHA256: String(repeating: "a", count: 64)))
    }
    func testBase64URLIsUnpaddedAndCanonical() throws {
        let data = Data([255]); XCTAssertEqual(PairedExecutionWire.base64URL(data), "_w")
        XCTAssertEqual(try PairedExecutionWire.decodeBase64URL("_w", byteCount: 1), data)
        for value in ["/w", "_w=", "_x", "_w\n"] { XCTAssertThrowsError(try PairedExecutionWire.decodeBase64URL(value, byteCount: 1)) }
    }
    func testDeviceNameRejectsAllCategoryC() throws {
        XCTAssertEqual(try PairedExecutionWire.deviceName("Phone café"), "Phone café")
        for name in ["", " ", "x\n", "x\u{200d}", "x\u{e000}", "x\u{0378}", String(repeating: "x", count: 65)] { XCTAssertThrowsError(try PairedExecutionWire.deviceName(name)) }
    }
    func testSyntheticSignaturesAreLowSAndBindMessage() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        let message = Data("Public fixture only".utf8)
        let signature = try PairedExecutionCrypto.sign(message: message, using: key)
        _ = try PairedExecutionWire.signatureBytes(signature)
        try PairedExecutionCrypto.verify(signature: signature, publicKey: PairedExecutionWire.base64URL(key.publicKey.x963Representation), message: message)
        XCTAssertThrowsError(try PairedExecutionCrypto.verify(signature: signature, publicKey: PairedExecutionWire.base64URL(key.publicKey.x963Representation), message: Data("changed".utf8)))
    }
    func testDuplicateSecurityHeadersFailBeforeDictionaryCoalescing() {
        XCTAssertThrowsError(try PairedExecutionHeaders(securityHeaders: [("X-Veyra-Host", host), ("x-veyra-host", host)]))
    }
}
