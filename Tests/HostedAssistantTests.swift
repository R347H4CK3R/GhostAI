import XCTest
@testable import AsterionVeyra

final class HostedAssistantTests: XCTestCase {
    private let token = "sk-SYNTHETIC_NOT_A_REAL_OPENAI_KEY_123456789"
    private func session() throws -> HostedAuthSession {
        try HostedAuthSession(token: token, directlyInstalled: true)
    }
    private func consent(_ session: HostedAuthSession) throws -> HostedConsent {
        try session.prepare(question: "Explain this function", context: "func sum() {}", model: "user-selected-model")
    }

    func testOnlyExactOfficialResponsesEndpointIsAccepted() throws {
        XCTAssertNoThrow(try HostedRequestPolicy.validate(URL(string: "https://api.openai.com/v1/responses")!))
        for value in ["http://api.openai.com/v1/responses", "https://api.openai.com.evil.example/v1/responses",
                      "https://evil.example/v1/responses", "https://api.openai.com/v1/chat/completions",
                      "https://api.openai.com:444/v1/responses", "https://user:password@api.openai.com/v1/responses",
                      "https://api.openai.com/v1/responses?token=x", "https://api.openai.com/v1/responses#fragment",
                      "https://api.openai.com/v1/%72esponses", "https://api.openai.com/v1/responses/"] {
            XCTAssertThrowsError(try HostedRequestPolicy.validate(URL(string: value)!), value)
        }
    }

    func testSessionRequiresDirectInstallationAndRejectsHeaderInjection() {
        XCTAssertThrowsError(try HostedAuthSession(token: token, directlyInstalled: false))
        for invalid in ["", "sk-short", "not-a-provider-key-1234567890", token + "\r\nOther: secret", token + " ", String(repeating: "a", count: 1000)] {
            XCTAssertThrowsError(try HostedAuthSession(token: invalid, directlyInstalled: true))
        }
    }

    func testPreviewPreservesExactTextAndRequiresExplicitModel() throws {
        let auth = try session()
        let preview = try auth.prepare(question: "  Question?\n", context: "\nContext\n", model: "chosen-model")
        XCTAssertEqual(preview.question, "  Question?\n")
        XCTAssertEqual(preview.context, "\nContext\n")
        XCTAssertEqual(preview.model, "chosen-model")
        XCTAssertEqual(preview.recipient, "https://api.openai.com/v1/responses")
        for model in ["", " ", "model\n", "../model", String(repeating: "m", count: 129)] {
            XCTAssertThrowsError(try auth.prepare(question: "hello", context: "", model: model))
        }
    }

    func testQuestionAndContextByteBoundsRejectRatherThanTruncate() throws {
        let auth = try session()
        XCTAssertNoThrow(try auth.prepare(question: String(repeating: "a", count: 8000), context: String(repeating: "b", count: 24000), model: "chosen-model"))
        XCTAssertThrowsError(try auth.prepare(question: String(repeating: "a", count: 8001), context: "", model: "chosen-model"))
        XCTAssertThrowsError(try auth.prepare(question: "Q", context: String(repeating: "b", count: 24001), model: "chosen-model"))
        XCTAssertThrowsError(try auth.prepare(question: String(repeating: "🙂", count: 2001), context: "", model: "chosen-model"))
        XCTAssertThrowsError(try auth.prepare(question: "  \n", context: "", model: "chosen-model"))
    }

    func testCredentialLikeTextIsBlockedInBothInputFields() throws {
        let auth = try session()
        for secret in [token, "github_pat_SYNTHETIC_123", "ghp_SYNTHETIC_123456", "password = example", "Authorization: Bearer example", "-----BEGIN RSA PRIVATE KEY-----", "AKIAABCDEFGHIJKLMNOP"] {
            XCTAssertThrowsError(try auth.prepare(question: secret, context: "", model: "chosen-model"))
            XCTAssertThrowsError(try auth.prepare(question: "Q", context: secret, model: "chosen-model"))
        }
    }

    func testRequestContainsOnlyReviewedTextAndNoHistoryToolsOrStorage() throws {
        let auth = try session()
        let preview = try consent(auth)
        let request = try HostedRequestPolicy.request(consent: preview, session: auth)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "input", "stream", "store", "max_output_tokens", "tools", "tool_choice"]))
        XCTAssertEqual(body["model"] as? String, "user-selected-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertEqual((body["tools"] as? [Any])?.count, 0)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "input_text", "text": "Explain this function"], ["type": "input_text", "text": "func sum() {}"]])
    }

    func testConsentIsSingleUseAndNewPreviewInvalidatesOldPreview() throws {
        let auth = try session()
        let old = try consent(auth)
        let current = try auth.prepare(question: "Replacement", context: "", model: "chosen-model")
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: old, session: auth))
        XCTAssertNoThrow(try HostedRequestPolicy.request(consent: current, session: auth))
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: current, session: auth))
    }

    func testInvalidReplacementCannotReuseAnEarlierConsent() throws {
        let auth = try session()
        let old = try consent(auth)
        XCTAssertThrowsError(try auth.prepare(question: "", context: "", model: "chosen-model"))
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: old, session: auth))
    }

    func testModelFieldCannotCarryACredential() throws {
        let auth = try session()
        XCTAssertThrowsError(try auth.prepare(question: "Q", context: "", model: token))
    }

    func testRedactionExpansionStillHonorsOutputSizeLimit() throws {
        let auth = try session()
        let text = String(repeating: "sk-abcdefgh ", count: 2500)
        XCTAssertThrowsError(try auth.redactAnswer(text))
    }

    func testConsentCannotMoveToAnotherSessionOrSurviveCancellation() throws {
        let auth = try session()
        let preview = try consent(auth)
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: try session()))
        auth.cancelPreview()
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: auth))
    }

    func testRevocationInvalidatesPreviewAndCancelsRegisteredTransport() throws {
        let auth = try session()
        let preview = try consent(auth)
        let cancelled = expectation(description: "transport cancelled")
        _ = try auth.registerCancellation { cancelled.fulfill() }
        auth.revoke()
        wait(for: [cancelled], timeout: 1)
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: auth))
        XCTAssertThrowsError(try auth.validate())
    }

    func testExpiredSessionCannotPrepareOrRegisterTransport() throws {
        let auth = try HostedAuthSession(token: token, directlyInstalled: true, expiresAt: Date(timeIntervalSince1970: 1))
        XCTAssertThrowsError(try consent(auth))
        let cancelled = expectation(description: "already expired registration is cancelled")
        XCTAssertThrowsError(try auth.registerCancellation { cancelled.fulfill() })
        wait(for: [cancelled], timeout: 1)
    }

    func testTokenIsRedactedFromDebuggingAndCompletedAnswer() throws {
        let auth = try session()
        XCTAssertFalse(String(describing: auth).contains(token))
        XCTAssertFalse(String(reflecting: auth).contains(token))
        var description = ""
        dump(auth, to: &description)
        XCTAssertFalse(description.contains(token))
        XCTAssertEqual(try auth.redactAnswer("Never use " + token), "Never use [redacted credential]")
        let error = NSError(domain: "private", code: 1, userInfo: [NSLocalizedDescriptionKey: token])
        XCTAssertFalse(HostedRequestPolicy.safeError(error).localizedDescription.contains(token))
    }

    func testConfigurationDisablesCookiesCacheCredentialsAndInheritedProxies() {
        let config = HostedRequestPolicy.configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.connectionProxyDictionary?["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(config.connectionProxyDictionary?["SOCKSEnable"] as? Int, 0)
        XCTAssertEqual(config.connectionProxyDictionary?["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 60)
    }

    func testRedirectsAreRejectedEvenOnTheSameHost() {
        let client = HostedHTTPTransport()
        let url = URL(string: "https://api.openai.com/v1/responses")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        client.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: url)) { redirected in
            XCTAssertNil(redirected)
        }
        task.cancel()
    }

    func testResponseValidationRejectsWrongMIMEHostStatusAndLength() throws {
        let auth = try session()
        func response(_ url: String = "https://api.openai.com/v1/responses", status: Int = 200, mime: String = "text/event-stream", length: String = "42") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime, "Content-Length": length])!
        }
        XCTAssertNoThrow(try HostedHTTPTransport.validateResponse(response(), session: auth))
        XCTAssertThrowsError(try HostedHTTPTransport.validateResponse(response("https://evil.example/"), session: auth))
        XCTAssertThrowsError(try HostedHTTPTransport.validateResponse(response(mime: "text/html"), session: auth))
        XCTAssertThrowsError(try HostedHTTPTransport.validateResponse(response(length: "524289"), session: auth))
        XCTAssertThrowsError(try HostedHTTPTransport.validateResponse(response(status: 429), session: auth))
        XCTAssertNoThrow(try auth.validate())
        XCTAssertThrowsError(try HostedHTTPTransport.validateResponse(response(status: 401), session: auth))
        XCTAssertThrowsError(try auth.validate())
    }

    func testSSEParsesAcrossEveryUTF8ByteAndIgnoresExecutableTools() throws {
        let parser = HostedEventAccumulator()
        let wire = ": heartbeat\r\n\r\n" + event(["type": "response.function_call_arguments.delta", "delta": "rm -rf private"]) + event(["type": "response.output_text.delta", "delta": "Hello 🙂"]) + completed()
        for byte in wire.utf8 { try parser.append(Data([byte])) }
        XCTAssertEqual(try parser.finish(), "Hello 🙂")
    }

    func testCompletionCanSupplyFinalTextWithoutDuplicatingDeltas() throws {
        let completion = event(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Answer"]]]]]])
        let parser = HostedEventAccumulator()
        try parser.append(Data(completion.utf8))
        XCTAssertEqual(try parser.finish(), "Answer")
        let streamed = HostedEventAccumulator()
        try streamed.append(Data((event(["type": "response.output_text.delta", "delta": "Answer"]) + completion).utf8))
        XCTAssertEqual(try streamed.finish(), "Answer")
    }

    func testIncompleteFailedMalformedAndTruncatedResponsesNeverYieldSuccess() throws {
        for wire in [event(["type": "response.failed"]), event(["type": "response.incomplete"]), "data: {broken}\n\n", event(["type": "response.output_text.delta", "delta": "partial"]), "data: [DONE]\n\n", event(["type": "response.completed", "response": ["status": "incomplete"]])] {
            let parser = HostedEventAccumulator()
            XCTAssertThrowsError(try { try parser.append(Data(wire.utf8)); _ = try parser.finish() }())
        }
    }

    func testStreamLineEventNetworkAndOutputBoundsAreEnforced() throws {
        let line = HostedEventAccumulator()
        XCTAssertThrowsError(try line.append(Data(String(repeating: "x", count: 65537).utf8)))
        let eventSize = HostedEventAccumulator()
        let multiline = String(repeating: "data: " + String(repeating: "x", count: 40000) + "\n", count: 4)
        XCTAssertThrowsError(try eventSize.append(Data(multiline.utf8)))
        let network = HostedEventAccumulator()
        XCTAssertThrowsError(try network.append(Data(String(repeating: ": ping\n\n", count: 70000).utf8)))
        let output = HostedEventAccumulator()
        XCTAssertThrowsError(try output.append(Data(event(["type": "response.output_text.delta", "delta": String(repeating: "z", count: 32769)]).utf8)))
    }

    func testClientUsesReviewedRequestAndRedactsProviderAnswer() async throws {
        let auth = try session()
        let preview = try consent(auth)
        let transport = HostedFixtureTransport { request, receive in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            let wire = self.event(["type": "response.output_text.delta", "delta": "Echo " + self.token]) + self.completed()
            try receive(Data(wire.utf8))
        }
        let answer = try await HostedResponsesClient(transport: transport).answer(consent: preview, session: auth)
        XCTAssertEqual(answer, "Echo [redacted credential]")
    }

    func testRevocationWithholdsLateTransportAnswer() async throws {
        let auth = try session()
        let preview = try consent(auth)
        let transport = HostedFixtureTransport { _, receive in
            try receive(Data((self.event(["type": "response.output_text.delta", "delta": "Late answer"]) + self.completed()).utf8))
            auth.revoke()
        }
        do {
            _ = try await HostedResponsesClient(transport: transport).answer(consent: preview, session: auth)
            XCTFail("A revoked session must not release a late answer")
        } catch { XCTAssertEqual(error as? HostedFailure, .expired) }
    }

    func testCancellationWithholdsLateTransportAnswerWithoutRetry() async throws {
        let auth = try session()
        let preview = try consent(auth)
        let reached = expectation(description: "transport reached")
        let gate = HostedTestGate()
        let transport = HostedFixtureTransport { _, receive in
            reached.fulfill()
            await gate.wait()
            try receive(Data((self.event(["type": "response.output_text.delta", "delta": "Late"]) + self.completed()).utf8))
        }
        let task = Task { try await HostedResponsesClient(transport: transport).answer(consent: preview, session: auth) }
        await fulfillment(of: [reached], timeout: 2)
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancellation must withhold late text") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: auth))
    }

    func testTransportFailureNeverLeaksResponseDetailsOrRetries() async throws {
        let auth = try session()
        let preview = try consent(auth)
        let transport = HostedFixtureTransport { _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: self.token])
        }
        do { _ = try await HostedResponsesClient(transport: transport).answer(consent: preview, session: auth); XCTFail("Must fail") }
        catch {
            XCTAssertEqual(error as? HostedFailure, .transport)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: auth))
    }

    func testTimeoutFailureIsGenericAndRequiresNewConsent() async throws {
        let auth = try session()
        let preview = try consent(auth)
        let transport = HostedFixtureTransport { _, _ in throw URLError(.timedOut) }
        do { _ = try await HostedResponsesClient(transport: transport).answer(consent: preview, session: auth); XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? HostedFailure, .transport) }
        XCTAssertThrowsError(try HostedRequestPolicy.request(consent: preview, session: auth))
    }

    @MainActor func testEndingScreenSessionRemovesKeyReviewAndAnswerAccess() throws {
        let controller = HostedAssistantController()
        try controller.begin(token: token, directlyInstalled: true)
        try controller.review(question: "Explain", context: "", model: "chosen-model")
        XCTAssertTrue(controller.connected)
        XCTAssertNotNil(controller.preview)
        controller.endSession()
        XCTAssertFalse(controller.connected)
        XCTAssertNil(controller.preview)
        XCTAssertTrue(controller.answer.isEmpty)
        XCTAssertThrowsError(try controller.review(question: "Explain", context: "", model: "chosen-model"))
    }

    @MainActor func testEditingInvalidatesPendingReview() throws {
        let controller = HostedAssistantController()
        try controller.begin(token: token, directlyInstalled: true)
        try controller.review(question: "Explain", context: "", model: "chosen-model")
        let old = try XCTUnwrap(controller.preview)
        controller.invalidateReview()
        controller.send(old)
        XCTAssertFalse(controller.working)
        XCTAssertTrue(controller.answer.isEmpty)
        XCTAssertNotNil(controller.message)
    }

    func testRefusalTextIsDisplayedButToolOnlyResponseHasNoAnswer() throws {
        let refusal = HostedEventAccumulator()
        try refusal.append(Data((event(["type": "response.refusal.delta", "delta": "I cannot help with that."]) + completed()).utf8))
        XCTAssertEqual(try refusal.finish(), "I cannot help with that.")
        let tool = HostedEventAccumulator()
        try tool.append(Data((event(["type": "response.function_call_arguments.delta", "delta": "execute()"] ) + completed()).utf8))
        XCTAssertThrowsError(try tool.finish())
    }

    private func event(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }
    private func completed() -> String { event(["type": "response.completed", "response": ["status": "completed", "output": []]]) }
}

private struct HostedFixtureTransport: HostedTransport, @unchecked Sendable {
    let action: (URLRequest, @escaping @Sendable (Data) throws -> Void) async throws -> Void
    func stream(_ request: URLRequest, session: HostedAuthSession, receive: @escaping @Sendable (Data) throws -> Void) async throws {
        try await action(request, receive)
    }
}

private actor HostedTestGate {
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func open() { isOpen = true; waiting?.resume(); waiting = nil }
}
