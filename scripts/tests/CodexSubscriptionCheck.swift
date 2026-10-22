import Foundation

// URLProtocol intercepts every request. No account files, real tokens, sockets or paid calls.
private final class SubscriptionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard request.url?.absoluteString == "https://api.openai.com/v1/responses",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token",
                  request.value(forHTTPHeaderField: "Accept") == "text/event-stream" else {
                throw CheckError.failed("unexpected endpoint or synthetic authorization")
            }
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let scenario = object["model"] as! String
            var status = 200
            var mime = "text/event-stream; charset=utf-8"
            var payload: String
            let delta = #"data: {"type":"response.output_text.delta","delta":"不可提前上屏"}"# + "\n\n"
            let completed = #"data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[{"type":"reasoning","summary":[{"text":"不能输出"}]},{"type":"message","content":[{"type":"output_text","text":"完成润色"}]}]}}"# + "\n\n"
            if object["stream"] as? Bool != true {
                status = 400
                payload = #"{"error":{"message":"stream must be true","param":"stream","code":"invalid_request_error"}}"#
            } else if object["max_output_tokens"] != nil {
                status = 400
                payload = #"{"error":{"message":"unsupported capability","param":"max_output_tokens","code":"subscription_sharing_unsupported_capability"}}"#
            } else {
                switch scenario {
                case "success": payload = ": keepalive\n\nevent: response.output_text.delta\n" + delta + completed
                case "crlf": payload = completed.replacingOccurrences(of: "\n", with: "\r\n")
                case "multiline": payload = completed.replacingOccurrences(of: ",\"response\"", with: ",\ndata: \"response\"")
                case "truncated": payload = delta
                case "done-only": payload = delta + "data: [DONE]\n\n"
                case "text-done-only": payload = delta + #"data: {"type":"response.output_text.done","text":"不可提前上屏"}"# + "\n\n"
                case "failed": payload = delta + #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"PRIVATE TRANSCRIPT TOKEN"}}}"# + "\n\n"
                case "error": payload = #"data: {"type":"error","code":"server_error","message":"PRIVATE TRANSCRIPT TOKEN"}"# + "\n\n"
                case "unknown-error": payload = #"data: {"type":"error","code":"PRIVATE_TRANSCRIPT_TOKEN"}"# + "\n\n"
                case "incomplete": payload = delta + #"data: {"type":"response.incomplete","response":{"status":"incomplete"}}"# + "\n\n"
                case "empty": payload = #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
                case "malformed": payload = "data: {bad json}\n\n"
                case "wrong-mime": mime = "application/json"; payload = "{}"
                case "bad-parameter": status = 400; payload = #"{"error":{"param":"reasoning.effort","message":"PRIVATE TRANSCRIPT TOKEN"}}"#
                case "private-parameter": status = 400; payload = #"{"error":{"param":"PRIVATE_TRANSCRIPT_TOKEN","message":"PRIVATE TRANSCRIPT TOKEN"}}"#
                case "expired": status = 401; payload = "PRIVATE TRANSCRIPT TOKEN"
                case "unavailable": status = 503; payload = "PRIVATE TRANSCRIPT TOKEN"
                case "cancel": payload = delta
                default: throw CheckError.failed("unknown fixture")
                }
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
            // Split inside UTF-8 text and SSE boundaries; parsing must not depend on packet size.
            for byte in payload.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
            if scenario != "cancel" { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private enum CheckError: Error { case failed(String) }

@main struct CodexSubscriptionCheck {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckError.failed(message) }
    }

    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CodexSubscriptionClient(session: session)
        func request(_ model: String) throws -> URLRequest {
            try CodexSubscriptionClient.completionRequest(token: "synthetic-test-token", model: model, instructions: "只整理原文", text: "合成测试")
        }
        let original = try request("success")
        var object = try JSONSerialization.jsonObject(with: original.httpBody!) as! [String: Any]
        try require(object["stream"] as? Bool == true && object["store"] as? Bool == false, "plan usage requires streaming and no storage")
        try require((object["reasoning"] as? [String: String])?["effort"] == "none", "do not enable thinking to work around a protocol error")
        try require(object["model"] as? String == "success", "preserve selected model")
        try require(object["max_output_tokens"] == nil, "plan usage rejects max_output_tokens")
        // Regression reproduction: the previous stream:false body is rejected by the documented contract.
        var legacy = original
        object["stream"] = false
        legacy.httpBody = try JSONSerialization.data(withJSONObject: object)
        do { _ = try await client.complete(request: legacy); throw CheckError.failed("legacy body should fail") }
        catch CodexSubscriptionClient.Failure.requestRejected(let parameter) { try require(parameter == "stream", "400 must diagnose request, not subscription") }
        object["stream"] = true
        object["max_output_tokens"] = 16384
        legacy.httpBody = try JSONSerialization.data(withJSONObject: object)
        do { _ = try await client.complete(request: legacy); throw CheckError.failed("unsupported token cap should fail") }
        catch CodexSubscriptionClient.Failure.requestRejected(let parameter) { try require(parameter == "max_output_tokens", "diagnose unsupported token cap") }
        print("PASS both legacy HTTP400 causes: stream:false and unsupported max_output_tokens")

        for scenario in ["success", "crlf", "multiline"] {
            let text = try await client.complete(request: request(scenario))
            try require(text == "完成润色", "only final output_text is used: \(scenario)")
        }
        print("PASS completed SSE, UTF-8 packet splitting, CRLF and multiline data")

        for scenario in ["truncated", "done-only", "text-done-only", "incomplete"] {
            do { _ = try await client.complete(request: request(scenario)); throw CheckError.failed("must reject \(scenario)") }
            catch CodexSubscriptionClient.Failure.incomplete {}
        }
        for scenario in ["malformed", "wrong-mime"] {
            do { _ = try await client.complete(request: request(scenario)); throw CheckError.failed("must reject \(scenario)") }
            catch CodexSubscriptionClient.Failure.invalidResponse {}
        }
        // An empty completed reply is its own failure so polish can fall back to the transcript.
        do { _ = try await client.complete(request: request("empty")); throw CheckError.failed("must reject empty") }
        catch CodexSubscriptionClient.Failure.emptyOutput {}
        for (scenario, expected) in [("failed", "subscription_sharing_usage_limit_exceeded"), ("error", "server_error"), ("unknown-error", nil)] as [(String, String?)] {
            do { _ = try await client.complete(request: request(scenario)); throw CheckError.failed("must reject \(scenario)") }
            catch CodexSubscriptionClient.Failure.responseFailed(let code) { try require(code == expected, "safe error code") }
        }
        print("PASS late failures, incomplete/interrupted streams and malformed responses never commit partial text")

        for (scenario, expected) in [("bad-parameter", "reasoning.effort"), ("private-parameter", nil)] as [(String, String?)] {
            do { _ = try await client.complete(request: request(scenario)); throw CheckError.failed("must reject \(scenario)") }
            catch let failure as CodexSubscriptionClient.Failure {
                guard case .requestRejected(let parameter) = failure else { throw failure }
                try require(parameter == expected, "only allowlisted parameters may be shown")
                try require(!failure.localizedDescription.contains("PRIVATE"), "do not disclose error bodies")
            }
        }
        do { _ = try await client.complete(request: request("expired")); throw CheckError.failed("401 must fail") }
        catch CodexSubscriptionClient.Failure.expired {}
        do { _ = try await client.complete(request: request("unavailable")); throw CheckError.failed("503 must fail") }
        catch CodexSubscriptionClient.Failure.http(let code) { try require(code == 503, "preserve HTTP status") }
        print("PASS HTTP400 parameter diagnosis, 401/503 handling and credential/body redaction")

        let pending = Task { try await client.complete(request: request("cancel")) }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; throw CheckError.failed("cancellation must fail") }
        catch is CancellationError {}
        catch let error as URLError where error.code == .cancelled {}
        print("PASS cancellation interrupts streaming without returning partial text")
    }
}
