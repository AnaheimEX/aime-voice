public import Foundation

public enum VoiceModelDiscovery {
    public static func supportsModelDiscovery(endpoint: VoiceEndpoint) -> Bool {
        ![.apple, .volcStreaming, .volcFlash, .fishASR, .layaPredict].contains(endpoint.resolvedProtocol)
    }

    public enum Failure: LocalizedError {
        case unsupported, empty

        public var errorDescription: String? {
            switch self {
            case .unsupported: "此识别服务使用固定协议，不提供可拉取的模型列表"

            case .empty: "服务返回的模型列表为空，请检查账号权限和接口地址"
            }
        }
    }

    public static func models(endpoint: VoiceEndpoint, speech: Bool = false) async throws -> [String] {

        guard supportsModelDiscovery(endpoint: endpoint) else { throw Failure.unsupported }
        let models: [String]
        if endpoint.resolvedProtocol == .bailianStreaming {
            models = try await BailianModelDiscovery.models(endpoint: endpoint)
        } else if endpoint.resolvedProtocol == .codex {
            models = try await CodexSubscriptionClient.shared.models()
        } else {
            var discoveryEndpoint = endpoint
            if endpoint.usesMiMo {
                discoveryEndpoint.baseURL = "https://api.xiaomimimo.com/v1"
                discoveryEndpoint.protocolType = "openai"
            }
            let data = try await VoiceHTTP.request(endpoint: discoveryEndpoint, path: "models", body: nil, timeout: 15)
            struct Model: Decodable { let id: String }
            struct Response: Decodable { let data: [Model] }
            models = try JSONDecoder().decode(Response.self, from: data).data.map(\.id)
        }
        let candidates: [String]
        if endpoint.resolvedProtocol == .mimoASR {
            candidates = models.filter { $0.lowercased().contains("asr") }
        } else if speech && endpoint.usesFishCompatible {
            candidates = models.filter { $0 == "fish-audio/transcribe-1" }
        } else {
            candidates = models
        }
        let available = Array(Set(candidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
        guard !available.isEmpty else { throw Failure.empty }
        return available
    }
}

enum VoiceHTTP {
    /// Transport timings in seconds, with no URL, headers, body, or credentials.
    /// Missing phases (including connection setup on reused connections) stay nil.
    struct Metrics: Sendable {
        struct Transaction: Sendable {
            let dnsDuration: TimeInterval?
            /// Connection setup before TLS; unavailable for HTTP/3 (which uses QUIC).
            let tcpDuration: TimeInterval?
            let tlsDuration: TimeInterval?
            /// From finishing the request upload to receiving the first response byte.
            let responseWaitDuration: TimeInterval?
            let downloadDuration: TimeInterval?
            let isReusedConnection: Bool

            fileprivate init(_ transaction: URLSessionTaskTransactionMetrics) {
                dnsDuration = Self.duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
                tcpDuration = transaction.networkProtocolName?.hasPrefix("h3") == true ? nil : Self.duration(
                    transaction.connectStartDate, transaction.secureConnectionStartDate ?? transaction.connectEndDate
                )
                tlsDuration = Self.duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
                responseWaitDuration = Self.duration(transaction.requestEndDate, transaction.responseStartDate)
                downloadDuration = Self.duration(transaction.responseStartDate, transaction.responseEndDate)
                isReusedConnection = transaction.isReusedConnection
            }

            private static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
                guard let start, let end, end >= start else { return nil }
                return end.timeIntervalSince(start)
            }
        }

        /// URLSession task lifetime, including scheduling and all transactions.
        /// This excludes request validation and response decoding in the caller.
        let totalDuration: TimeInterval
        let transactions: [Transaction]

        fileprivate init(_ metrics: URLSessionTaskMetrics) {
            totalDuration = metrics.taskInterval.duration
            transactions = metrics.transactionMetrics.map(Transaction.init)
        }
    }

    // Reuse transport connections without retaining cookies, cached responses,
    // or session-level credentials. Authentication stays on each URLRequest.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    enum Failure: LocalizedError {
        case endpoint, credential, credentialFormat, response, status(Int), requestRejected(Int, String, String?), empty
        var errorDescription: String? {
            switch self {
            case .endpoint: "接口地址必须为 HTTP 或 HTTPS，远程接口请使用 HTTPS"
            case .credential: "API Key 含有换行，请重新粘贴完整密钥"
            case .credentialFormat: "模型接口返回 HTTP 401：服务确认 API Key 格式错误。请从当前服务的 API Key 管理页面复制完整密钥，不要填写密钥名称、ID 或 Access Key"
            case .response: "模型接口未返回有效 HTTP 响应"
            case .status(let code): "模型接口返回 HTTP \(code)，请检查地址、密钥和模型"
            case .requestRejected(let code, let operation, let serviceCode):
            "模型接口返回 HTTP \(code)（\(operation)）"
                + (code == 401 ? "：密钥鉴权失败，请重新填写当前服务的 API Key；方舟、语音服务与套餐专属密钥不可混用" : code == 403 ? "：服务拒绝访问，请核对该模型和接口的调用权限、订阅及账户状态" : "：请检查接口地址、密钥、模型及请求协议")
                + (serviceCode.map { "；服务错误代码：\($0)" } ?? "")
        case .empty: "模型接口返回空文本"
            }
        }
    }

    /// Optional callback runs on the URLSession delegate queue; keep it short.
    /// Also reports failed/cancelled tasks when URLSession supplies metrics; validation
    /// failures before task creation have none. No logging or extra session is enabled.
    static func request(
        endpoint: VoiceEndpoint, path: String, body: Data?, timeout: TimeInterval,
        onMetrics: (@Sendable (Metrics) -> Void)? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              (scheme == "https" || isLocalHost(host)) else {
            throw Failure.endpoint
        }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        // Accept a service root or a complete operation URL without duplicating paths.
        for suffix in ["/chat/completions", "/audio/transcriptions", "/messages", "/models", "/systemone", "/decisions", "/predict"] {
            if components.path.hasSuffix(suffix) {
                components.path.removeLast(suffix.count)
                break
            }
        }
        guard let baseURL = components.url else { throw Failure.endpoint }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.contains("\r"), !apiKey.contains("\n") else { throw Failure.credential }
        if !apiKey.isEmpty {
            if endpoint.resolvedProtocol == .layaPredict {
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            } else if endpoint.usesMiMo {
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
            } else if endpoint.resolvedProtocol == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if endpoint.resolvedProtocol == .anthropic && !endpoint.usesMiMo {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Refuse redirects so a misconfigured API cannot forward a user's credential to another origin.
        // URLRequest timeout is an inactivity timer: a trickle of bytes can reset it.
        // Bound the whole operation as well, using the same caller-supplied budget.
        guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
        let preparedRequest = request
        let delegate = onMetrics.map { NoRedirect(onMetrics: $0) }
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: preparedRequest, delegate: delegate) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
        guard let response = response as? HTTPURLResponse else { throw Failure.response }
        guard (200..<300).contains(response.statusCode) else { let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            // Map only a known provider diagnostic. Never display the arbitrary
            // response message, which may echo credentials or request contents.
            if response.statusCode == 401,
               let message = error?["message"] as? String,
               message.lowercased().contains("api key format is incorrect") {
                throw Failure.credentialFormat
            }
            let code = (error?["code"] as? String) ?? (json?["code"] as? String)
            let safeCode = code.flatMap { value -> String? in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
                guard !value.isEmpty, value.count <= 80, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
                return value
            }
            throw Failure.requestRejected(response.statusCode, "\(request.httpMethod ?? "POST") /\(path)", safeCode) }
        return data
    }

    static func isLocalHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        private let onMetrics: (@Sendable (Metrics) -> Void)?

        init(onMetrics: (@Sendable (Metrics) -> Void)? = nil) {
            self.onMetrics = onMetrics
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            onMetrics?(Metrics(metrics))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
