import XCTest
import Security
@testable import AsterionVeyra

final class PairedDesktopTransportTests: XCTestCase {
    // Public scalar-one certificates, never live enrollment material. Positive
    // fixtures use the desktop's 30-day lifetime around the fixed test date.
    // The old five-year leaf stays below as a negative platform-policy fixture.
    private let good = Data(base64Encoded: "MIIBezCCASGgAwIBAgIBATAKBggqhkjOPQQDAjArMSkwJwYDVQQDDCBQVUJMSUMgc3ludGhldGljIHBhaXJpbmcgZml4dHVyZTAeFw0yNjExMDEwMDAwMDBaFw0yNjEyMDEwMDAwMDBaMCsxKTAnBgNVBAMMIFBVQkxJQyBzeW50aGV0aWMgcGFpcmluZyBmaXh0dXJlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9aM2MDQwDAYDVR0TAQH/BAIwADAPBgNVHREECDAGhwTAqAEUMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0gAMEUCIQDZJMV1qE0BrIfCciOPPLRVciuMrpPKw1R/QvEEKmzK6QIgfYtljYaCat/coq7O719JIQHPe3D1APu1ZatxvakYplA=")!
    private let overlong = Data(base64Encoded: "MIIBfDCCASGgAwIBAgIBATAKBggqhkjOPQQDAjArMSkwJwYDVQQDDCBQVUJMSUMgc3ludGhldGljIHBhaXJpbmcgZml4dHVyZTAeFw0yNTAxMDEwMDAwMDBaFw0zMDAxMDEwMDAwMDBaMCsxKTAnBgNVBAMMIFBVQkxJQyBzeW50aGV0aWMgcGFpcmluZyBmaXh0dXJlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9aM2MDQwDAYDVR0TAQH/BAIwADAPBgNVHREECDAGhwTAqAEUMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0kAMEYCIQDNErPdPA5TKbRKTou/bAOLw7xT9LG+hWsQo7DTaU0O+wIhANJ7eJV30FkEyGkEfD/jozF4fPdX091qG25YP2AzOzpT")!
    private let clientOnly = Data(base64Encoded: "MIIBezCCASGgAwIBAgIBATAKBggqhkjOPQQDAjArMSkwJwYDVQQDDCBQVUJMSUMgc3ludGhldGljIHBhaXJpbmcgZml4dHVyZTAeFw0yNjExMDEwMDAwMDBaFw0yNjEyMDEwMDAwMDBaMCsxKTAnBgNVBAMMIFBVQkxJQyBzeW50aGV0aWMgcGFpcmluZyBmaXh0dXJlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9aM2MDQwDAYDVR0TAQH/BAIwADAPBgNVHREECDAGhwTAqAEUMBMGA1UdJQQMMAoGCCsGAQUFBwMCMAoGCCqGSM49BAMCA0gAMEUCIQCJ3RDD+KriMK36Y56fFENIgz25hYRmzRuAise+r/Z64AIgCfYbk7VjTQuh4iKdkh8YNP3xo6UmK3v/hoJ9ya4eedk=")!
    private var date: Date { Date(timeIntervalSince1970: 1794096000) }
    func testExplicitIPSanAndServerAuthAreRequired() {
        XCTAssertNoThrow(try PairedDesktopTLS.validateLeaf(der: good, hostname: "192.168.1.20", now: date))
        XCTAssertThrowsError(try PairedDesktopTLS.validateLeaf(der: good, hostname: "192.168.1.21", now: date))
        XCTAssertThrowsError(try PairedDesktopTLS.validateLeaf(der: clientOnly, hostname: "192.168.1.20", now: date))
    }
    func testLeafDatesApplyEvenWhenLeafIsAnAnchor() {
        for time in [TimeInterval(0), TimeInterval(2_000_000_000)] { XCTAssertThrowsError(try PairedDesktopTLS.validateLeaf(der: good, hostname: "192.168.1.20", now: Date(timeIntervalSince1970: time))) }
    }
    func testTruncatedTrailingIndefiniteAndOversizedDERFail() {
        for bytes in [Data(), Data(good.dropLast()), good + Data([0]), Data([0x30,0x80,0,0]), Data(repeating: 0, count: 16385)] {
            XCTAssertThrowsError(try PairedDesktopTLS.validateLeaf(der: bytes, hostname: "192.168.1.20", now: date))
        }
    }
    func testExactLeafPinRequiredBeforeTrustCredential() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, good as CFData)); var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "192.168.1.20" as CFString), &trust), errSecSuccess)
        XCTAssertThrowsError(try PairedDesktopTLS.credential(trust: XCTUnwrap(trust), hostname: "192.168.1.20", pin: String(repeating: "0", count: 64), now: date))
    }
    func testAppLocalAnchorDoesNotPermitAnotherName() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, good as CFData)); var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "192.168.1.20" as CFString), &trust), errSecSuccess)
        let pin = try PairedExecutionCrypto.sha256Hex(good)
        XCTAssertNoThrow(try PairedDesktopTLS.credential(trust: XCTUnwrap(trust), hostname: "192.168.1.20", pin: pin, now: date))
        XCTAssertThrowsError(try PairedDesktopTLS.credential(trust: XCTUnwrap(trust), hostname: "192.168.1.21", pin: pin, now: date))
    }
    func testPlatformPolicyStillRejectsOverlongAppAnchoredLeaf() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, overlong as CFData)); var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "192.168.1.20" as CFString), &trust), errSecSuccess)
        // Its exact pin, SAN, EKU and current dates alone must not bypass the
        // platform SSL validity-period policy for an app-only trust anchor.
        XCTAssertNoThrow(try PairedDesktopTLS.validateLeaf(der: overlong, hostname: "192.168.1.20", now: date))
        let pin = try PairedExecutionCrypto.sha256Hex(overlong)
        XCTAssertThrowsError(try PairedDesktopTLS.credential(trust: XCTUnwrap(trust), hostname: "192.168.1.20", pin: pin, now: date))
    }
    func testUntrustedOriginsAndArbitraryRoutesNeverEnterNetwork() async {
        let transport = PairedDesktopPinnedTransport()
        for input in [PairedDesktopRequest(origin: "http://192.168.1.20:8443", pin: String(repeating: "a", count: 64), route: "/v1/pair/begin", headers: [:], body: Data()),
                      PairedDesktopRequest(origin: "https://192.168.1.20:8443", pin: String(repeating: "a", count: 64), route: "/v1/admin", headers: [:], body: Data())] {
            do { _ = try await transport.send(input); XCTFail("Invalid route entered networking") } catch {}
        }
    }
}
