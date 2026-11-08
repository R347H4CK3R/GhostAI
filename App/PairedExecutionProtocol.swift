import Foundation
import CryptoKit

enum PairedExecutionFailure: Error, Equatable { case malformed, oversized, duplicate, unsupportedOrigin, expired, invalidSignature, cryptoUnavailable }
struct PairedExecutionInvitation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let hostID: String; let origin: String; let tlsLeafSHA256: String; let inviteID: String; let expiresAtMilliseconds: Int64
    fileprivate let secret: Data
    var description: String { "PairedExecutionInvitation(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["invitation": "redacted"]) }
    static func parse(_ data: Data, nowMilliseconds: Int64) throws -> Self {
        guard data.count <= 4096 else { throw PairedExecutionFailure.oversized }
        let value = try PairedDesktopJSON.parse(data)
        try value.exact(["v", "host_id", "origin", "tls_leaf_sha256", "invite_id", "invite_secret", "expires_at_ms"])
        let expiry = try value.integer("expires_at_ms")
        guard try value.integer("v") == 1, nowMilliseconds >= 0, (0...253402300799999).contains(expiry) else { throw PairedExecutionFailure.malformed }
        guard expiry > nowMilliseconds else { throw PairedExecutionFailure.expired }
        return try Self(hostID: PairedExecutionWire.canonicalUUID(value.string("host_id")), origin: PairedExecutionWire.localIPv4Origin(value.string("origin")),
            tlsLeafSHA256: PairedExecutionWire.sha256Hex(value.string("tls_leaf_sha256")), inviteID: PairedExecutionWire.canonicalUUID(value.string("invite_id")),
            expiresAtMilliseconds: expiry, secret: PairedExecutionWire.decodeBase64URL(value.string("invite_secret"), byteCount: 32))
    }
}
enum PairedExecutionWire {
    static let order: [UInt8] = [255,255,255,255,0,0,0,0,255,255,255,255,255,255,255,255,188,230,250,173,167,23,158,132,243,185,202,194,252,99,37,81]
    static let halfOrder: [UInt8] = [127,255,255,255,128,0,0,0,127,255,255,255,255,255,255,255,222,115,125,86,211,139,207,66,121,220,229,97,126,49,146,168]
    static func localIPv4Origin(_ value: String) throws -> String {
        guard value.utf8.count <= 128, value.utf8.allSatisfy({ (33...126).contains($0) }),
              let url = URLComponents(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty, let host = url.host, let port = url.port,
              (1...65535).contains(port), value == "https://\(host):\(port)" else { throw PairedExecutionFailure.unsupportedOrigin }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw PairedExecutionFailure.unsupportedOrigin }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part), (0...255).contains(number), String(number) == part else { throw PairedExecutionFailure.unsupportedOrigin }
            octets.append(number)
        }
        guard (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)),
              (1...254).contains(octets[3]) else { throw PairedExecutionFailure.unsupportedOrigin }; return value
    }
    static func canonicalUUID(_ value: String) throws -> String {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { throw PairedExecutionFailure.malformed }; return value
    }
    static func sequence(_ value: String) throws -> Int64 {
        guard !value.isEmpty, value.utf8.count <= 19, value.first != "0", value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int64(value), n > 0 else { throw PairedExecutionFailure.malformed }; return n
    }
    static func sha256Hex(_ value: String) throws -> String {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PairedExecutionFailure.malformed }; return value
    }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decodeBase64URL(_ value: String, byteCount: Int) throws -> Data {
        guard (1...65).contains(byteCount), value.utf8.count == (byteCount * 8 + 5) / 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw PairedExecutionFailure.malformed }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count == byteCount, base64URL(data) == value else { throw PairedExecutionFailure.malformed }; return data
    }
    static func publicKeyBytes(_ value: String) throws -> Data {
        let data = try decodeBase64URL(value, byteCount: 65)
        guard data.first == 4 else { throw PairedExecutionFailure.malformed }
        do { _ = try P256.Signing.PublicKey(x963Representation: data) } catch { throw PairedExecutionFailure.malformed }; return data
    }
    static func signatureBytes(_ value: String) throws -> Data {
        let data = try decodeBase64URL(value, byteCount: 64)
        let r = Array(data.prefix(32)); let s = Array(data.suffix(32))
        guard r.contains(where: { $0 != 0 }), r.lexicographicallyPrecedes(order), s.contains(where: { $0 != 0 }),
              !halfOrder.lexicographicallyPrecedes(s) else { throw PairedExecutionFailure.invalidSignature }; return data
    }
    static func deviceName(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= 64, value.utf8.count <= 256 else { throw PairedExecutionFailure.malformed }
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: throw PairedExecutionFailure.malformed
            default: break
            }
        }
        return value // Preserve exact bytes, never normalize.
    }
    static func pairFrame(hostID: String, inviteID: String, clientNonce: String, clientPublicKey: String, deviceNameSHA256: String) throws -> Data {
        _ = try canonicalUUID(hostID); _ = try canonicalUUID(inviteID); _ = try decodeBase64URL(clientNonce, byteCount: 32)
        _ = try publicKeyBytes(clientPublicKey); _ = try sha256Hex(deviceNameSHA256)
        return Data("VEYRA-PAIR-V1\n\(hostID)\n\(inviteID)\n\(clientNonce)\n\(clientPublicKey)\n\(deviceNameSHA256)\n".utf8)
    }
    static func requestFrame(hostID: String, deviceID: String, sequence: String, requestID: String, route: String, bodySHA256: String) throws -> Data {
        _ = try canonicalUUID(hostID); _ = try canonicalUUID(deviceID); _ = try self.sequence(sequence); _ = try canonicalUUID(requestID); _ = try sha256Hex(bodySHA256)
        guard ["/v1/pair/status", "/v1/jobs/submit", "/v1/jobs/get", "/v1/jobs/cancel"].contains(route) else { throw PairedExecutionFailure.malformed }
        return Data("VEYRA-REQUEST-V1\n\(hostID)\n\(deviceID)\n\(sequence)\n\(requestID)\nPOST\n\(route)\n\(bodySHA256)\n".utf8)
    }
}
struct PairedExecutionHeaders {
    let hostID: String; let deviceID: String; let sequence: Int64; let requestID: String; let signature: Data
    init(securityHeaders: [(String, String)]) throws {
        guard securityHeaders.count == 5 else { throw PairedExecutionFailure.malformed }
        var fields: [String: String] = [:]; var count = 0
        for (name, value) in securityHeaders {
            count += name.utf8.count + value.utf8.count + 4; guard count <= 8192 else { throw PairedExecutionFailure.oversized }
            let key = name.lowercased(); guard fields[key] == nil else { throw PairedExecutionFailure.duplicate }; fields[key] = value
        }
        guard Set(fields.keys) == Set(["x-veyra-host", "x-veyra-device", "x-veyra-sequence", "x-veyra-request", "x-veyra-signature"]),
              let host = fields["x-veyra-host"], let device = fields["x-veyra-device"], let sequence = fields["x-veyra-sequence"], let request = fields["x-veyra-request"], let signature = fields["x-veyra-signature"] else { throw PairedExecutionFailure.malformed }
        hostID = try PairedExecutionWire.canonicalUUID(host); deviceID = try PairedExecutionWire.canonicalUUID(device)
        self.sequence = try PairedExecutionWire.sequence(sequence); requestID = try PairedExecutionWire.canonicalUUID(request); self.signature = try PairedExecutionWire.signatureBytes(signature)
    }
}
struct PairedExecutionProof: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let proof: String; let signedBytes: Data; let safetyCode: String
    var description: String { "PairedExecutionProof(redacted)" }; var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["proof": "redacted"]) }
}
enum PairedExecutionCrypto {
    static var isAvailable: Bool { true }
    static func sha256Hex(_ bytes: Data) throws -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func pairProof(invitation: PairedExecutionInvitation, clientNonce: String, clientPublicKey: String, deviceName: String) throws -> PairedExecutionProof {
        let name = try PairedExecutionWire.deviceName(deviceName)
        let frame = try PairedExecutionWire.pairFrame(hostID: invitation.hostID, inviteID: invitation.inviteID, clientNonce: clientNonce, clientPublicKey: clientPublicKey, deviceNameSHA256: sha256Hex(Data(name.utf8)))
        let proof = PairedExecutionWire.base64URL(Data(HMAC<SHA256>.authenticationCode(for: frame, using: SymmetricKey(data: invitation.secret))))
        let signed = frame + Data((proof + "\n").utf8)
        return try PairedExecutionProof(proof: proof, signedBytes: signed, safetyCode: String(sha256Hex(signed).prefix(16)))
    }
    static func requestFrame(hostID: String, deviceID: String, sequence: String, requestID: String, route: String, body: Data) throws -> Data {
        guard body.count <= 262144 else { throw PairedExecutionFailure.oversized }
        return try PairedExecutionWire.requestFrame(hostID: hostID, deviceID: deviceID, sequence: sequence, requestID: requestID, route: route, bodySHA256: sha256Hex(body))
    }
    static func sign(message: Data, using key: P256.Signing.PrivateKey) throws -> String {
        var bytes = Array(try key.signature(for: message).rawRepresentation)
        let s = Array(bytes[32..<64])
        if PairedExecutionWire.halfOrder.lexicographicallyPrecedes(s) {
            var borrow = 0
            for index in stride(from: 31, through: 0, by: -1) {
                let difference = Int(PairedExecutionWire.order[index]) - Int(s[index]) - borrow
                bytes[index + 32] = UInt8((difference + 256) % 256); borrow = difference < 0 ? 1 : 0
            }
        }
        let result = PairedExecutionWire.base64URL(Data(bytes)); _ = try PairedExecutionWire.signatureBytes(result); return result
    }
    static func verify(signature: String, publicKey: String, message: Data) throws {
        do {
            let key = try P256.Signing.PublicKey(x963Representation: PairedExecutionWire.publicKeyBytes(publicKey))
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: PairedExecutionWire.signatureBytes(signature))
            guard key.isValidSignature(signature, for: message) else { throw PairedExecutionFailure.invalidSignature }
        } catch { throw PairedExecutionFailure.invalidSignature }
    }
}
