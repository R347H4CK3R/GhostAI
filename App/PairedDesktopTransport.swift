import Foundation
import Security

/// Dedicated fresh sessions avoid cached trust, credentials and TLS tickets.
/// Security must finish the pinned TLS challenge before HTTP authentication/body
/// can leave. Actual iOS handshake/ATS/proxy tests remain a release gate.
final class PairedDesktopPinnedTransport: PairedDesktopTransport, @unchecked Sendable {
    private let lock = NSLock(); private var exchange: PairedDesktopExchange?
    func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse {
        let value = try install(request); defer { clear(value) }
        return try await withTaskCancellationHandler(operation: { try await value.run() }, onCancel: { value.cancel() })
    }
    private func install(_ request: PairedDesktopRequest) throws -> PairedDesktopExchange {
        lock.lock(); defer { lock.unlock() }; guard exchange == nil else { throw PairedDesktopFailure.busy }
        let value = try PairedDesktopExchange(request); exchange = value; return value
    }
    private func clear(_ value: PairedDesktopExchange) { lock.lock(); defer { lock.unlock() }; if exchange === value { exchange = nil } }
    func cancel() { lock.lock(); let value = exchange; lock.unlock(); value?.cancel() }
}
private final class PairedDesktopExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let input: PairedDesktopRequest; private let url: URL; private let host: String; private let port: Int
    private let lock = NSLock(); private let maximum = 524288
    private var session: URLSession?; private var continuation: CheckedContinuation<PairedDesktopResponse, Error>?
    private var finished = false; private var trusted = false; private var status: Int?; private var length: Int?; private var bytes = Data()
    init(_ request: PairedDesktopRequest) throws {
        _ = try PairedExecutionWire.localIPv4Origin(request.origin); _ = try PairedExecutionWire.sha256Hex(request.pin)
        guard ["/v1/pair/begin", "/v1/pair/status", "/v1/jobs/submit", "/v1/jobs/get", "/v1/jobs/cancel"].contains(request.route),
              request.body.count <= (request.route == "/v1/pair/begin" ? 4096 : 262144),
              let url = URL(string: request.origin + request.route), let host = url.host, let port = url.port else { throw PairedDesktopFailure.malformed }
        if request.route == "/v1/pair/begin" { guard request.headers.isEmpty else { throw PairedDesktopFailure.malformed } }
        else { _ = try PairedExecutionHeaders(securityHeaders: request.headers.map { ($0.key, $0.value) }) }
        input = request; self.url = url; self.host = host; self.port = port
    }
    func run() async throws -> PairedDesktopResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); guard !finished else { lock.unlock(); continuation.resume(throwing: PairedDesktopFailure.cancelled); return }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never; config.urlCredentialStorage = nil
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
            config.proxyConfigurations = []; config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25; config.waitsForConnectivity = false
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue); self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "POST"; request.httpBody = input.body; request.httpShouldHandleCookies = false
            request.setValue("\(host):\(port)", forHTTPHeaderField: "Host")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding"); request.setValue(String(input.body.count), forHTTPHeaderField: "Content-Length")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control"); request.setValue("close", forHTTPHeaderField: "Connection")
            input.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let task = session.dataTask(with: request); lock.unlock(); task.resume()
        }
    }
    func cancel() { finish(.failure(PairedDesktopFailure.cancelled)) }
    private func finish(_ result: Result<PairedDesktopResponse, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let value = continuation; continuation = nil; let session = self.session; self.session = nil; lock.unlock()
        session?.invalidateAndCancel(); value?.resume(with: result)
    }
    private func challenge(_ challenge: URLAuthenticationChallenge, completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard challenge.previousFailureCount == 0, space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.protocol == "https", space.host == host, space.port == port, !space.isProxy(), let trust = space.serverTrust else {
            completion(.cancelAuthenticationChallenge, nil); finish(.failure(PairedDesktopFailure.untrusted)); return
        }
        do {
            let credential = try PairedDesktopTLS.credential(trust: trust, hostname: host, pin: input.pin)
            lock.lock(); let allowed = !finished; if allowed { trusted = true }; lock.unlock()
            completion(allowed ? .useCredential : .cancelAuthenticationChallenge, allowed ? credential : nil)
        } catch { completion(.cancelAuthenticationChallenge, nil); finish(.failure(PairedDesktopFailure.untrusted)) }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { self.challenge(challenge, completion: completionHandler) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { self.challenge(challenge, completion: completionHandler) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil); finish(.failure(PairedDesktopFailure.untrusted)) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let allowed = trusted && !finished; lock.unlock()
        guard allowed, let http = response as? HTTPURLResponse, http.url == url,
              http.value(forHTTPHeaderField: "Content-Type") == "application/json", http.value(forHTTPHeaderField: "Content-Encoding") == nil,
              http.value(forHTTPHeaderField: "Transfer-Encoding") == nil, let text = http.value(forHTTPHeaderField: "Content-Length"),
              !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(text), String(count) == text,
              count <= maximum, !(300...399).contains(http.statusCode) else { completionHandler(.cancel); finish(.failure(PairedDesktopFailure.malformed)); return }
        lock.lock(); status = http.statusCode; length = count; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        guard data.count <= maximum - bytes.count else { lock.unlock(); finish(.failure(PairedDesktopFailure.limit)); return }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let status = self.status; let length = self.length; let data = bytes; let trusted = self.trusted; lock.unlock()
        guard error == nil, trusted, let status, length == data.count else { finish(.failure(PairedDesktopFailure.unavailable)); return }
        finish(.success(PairedDesktopResponse(status: status, body: data)))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
}

enum PairedDesktopTLS {
    static func credential(trust: SecTrust, hostname: String, pin: String, now: Date = Date()) throws -> URLCredential {
        guard let leaf = SecTrustGetCertificateAtIndex(trust, 0) else { throw PairedDesktopFailure.untrusted }
        let der = SecCertificateCopyData(leaf) as Data
        guard try PairedExecutionCrypto.sha256Hex(der) == pin else { throw PairedDesktopFailure.untrusted }
        try validateLeaf(der: der, hostname: hostname, now: now)
        var checked: SecTrust?
        guard SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &checked) == errSecSuccess,
              let checked, SecTrustSetAnchorCertificates(checked, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(checked, true) == errSecSuccess, SecTrustSetNetworkFetchAllowed(checked, false) == errSecSuccess,
              SecTrustSetVerifyDate(checked, now as CFDate) == errSecSuccess, SecTrustEvaluateWithError(checked, nil) else { throw PairedDesktopFailure.untrusted }
        return URLCredential(trust: checked)
    }
    /// Bounded DER subset requires IP SAN, explicit serverAuth EKU and leaf dates
    /// independently of trust-anchor exemptions. SecTrust still evaluates SSL.
    static func validateLeaf(der: Data, hostname: String, now: Date) throws {
        guard der.count <= 16384 else { throw PairedDesktopFailure.untrusted }
        var top = DER(bytes: Array(der)); let certificate = try top.node(tag: 0x30); try top.end()
        var envelope = DER(bytes: certificate); let tbs = try envelope.node(tag: 0x30)
        _ = try envelope.node(tag: 0x30); _ = try envelope.node(tag: 0x03); try envelope.end()
        var body = DER(bytes: tbs); if body.peek == 0xa0 { _ = try body.node(tag: 0xa0) }
        _ = try body.node(tag: 0x02); _ = try body.node(tag: 0x30); _ = try body.node(tag: 0x30)
        var validity = DER(bytes: try body.node(tag: 0x30)); let start = try validity.date(); let end = try validity.date(); try validity.end()
        guard start <= now, now < end else { throw PairedDesktopFailure.untrusted }
        _ = try body.node(tag: 0x30); _ = try body.node(tag: 0x30)
        if body.peek == 0x81 { _ = try body.node(tag: 0x81) }; if body.peek == 0x82 { _ = try body.node(tag: 0x82) }
        var wrapper = DER(bytes: try body.node(tag: 0xa3)); try body.end()
        var extensions = DER(bytes: try wrapper.node(tag: 0x30)); try wrapper.end()
        let octets = hostname.split(separator: ".").compactMap { UInt8($0) }; guard octets.count == 4 else { throw PairedDesktopFailure.untrusted }
        var namesOK = false; var usageOK = false; var seen = Set<Data>()
        while extensions.peek != nil {
            var item = DER(bytes: try extensions.node(tag: 0x30)); let oid = try item.node(tag: 0x06)
            guard seen.insert(Data(oid)).inserted else { throw PairedDesktopFailure.untrusted }
            if item.peek == 0x01 { _ = try item.node(tag: 0x01) }
            let payload = try item.node(tag: 0x04); try item.end()
            if oid == [0x55,0x1d,0x11] {
                var wrapped = DER(bytes: payload); var names = DER(bytes: try wrapped.node(tag: 0x30)); try wrapped.end()
                while let tag = names.peek { let name = try names.node(tag: tag); if tag == 0x87, name == octets { namesOK = true } }
            }
            if oid == [0x55,0x1d,0x25] {
                var wrapped = DER(bytes: payload); var usages = DER(bytes: try wrapped.node(tag: 0x30)); try wrapped.end()
                while usages.peek != nil { if try usages.node(tag: 0x06) == [0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01] { usageOK = true } }
            }
        }
        guard namesOK, usageOK else { throw PairedDesktopFailure.untrusted }
    }
    private struct DER {
        let bytes: [UInt8]; var offset = 0
        var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }
        mutating func node(tag: UInt8) throws -> [UInt8] {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw PairedDesktopFailure.untrusted }
            offset += 1; let first = Int(bytes[offset]); offset += 1; var length = first
            if first >= 128 {
                let count = first & 0x7f
                guard (1...3).contains(count), offset + count <= bytes.count, bytes[offset] != 0 else { throw PairedDesktopFailure.untrusted }
                length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }; guard length >= 128 else { throw PairedDesktopFailure.untrusted }
            }
            guard length <= bytes.count - offset else { throw PairedDesktopFailure.untrusted }
            let value = Array(bytes[offset..<(offset + length)]); offset += length; return value
        }
        func end() throws { guard offset == bytes.count else { throw PairedDesktopFailure.untrusted } }
        mutating func date() throws -> Date {
            guard let tag = peek, [0x17,0x18].contains(tag) else { throw PairedDesktopFailure.untrusted }
            let raw = try node(tag: tag)
            guard raw.count == (tag == 0x17 ? 13 : 15), raw.last == 90, raw.dropLast().allSatisfy({ (48...57).contains($0) }) else { throw PairedDesktopFailure.untrusted }
            var text = String(decoding: raw, as: UTF8.self); if tag == 0x17 { text = ((Int(text.prefix(2)) ?? 100) >= 50 ? "19" : "20") + text }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"; formatter.isLenient = false
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw PairedDesktopFailure.untrusted }; return date
        }
    }
}
