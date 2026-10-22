public import Foundation
import CryptoKit
import Darwin
import Security

/// Official Sign in with ChatGPT public-client OAuth and the public Responses API.
/// Authentication belongs to AIME; this never reads Codex CLI credential files.
/// References: developers.openai.com/siwc/token-sharing-open-source/sign-in
/// and developers.openai.com/siwc/token-sharing-open-source/models-and-inference.
public actor CodexSubscriptionClient {
    public static let shared = CodexSubscriptionClient()

    public enum Failure: LocalizedError, Sendable {
        case loginRequired, permission, invalidResponse, invalidIdentity, denied, timedOut
        case http(Int), loginFailed, expired, storage, incomplete
        case requestRejected(parameter: String?), responseFailed(code: String?)
        public var errorDescription: String? {
            switch self {
            case .loginRequired: "请先登录 ChatGPT 订阅"
            case .permission: "此账户未授权 ChatGPT 计划使用权限，请重新登录并授权"
            case .invalidResponse: "ChatGPT 接口未返回有效文本或模型列表"
            case .invalidIdentity: "ChatGPT 登录身份校验失败，未保存凭据"
            case .denied: "用户取消了 ChatGPT 登录授权"
            case .timedOut: "ChatGPT 登录超时，请重新登录"
            case .http(let status): "ChatGPT 官方接口返回 HTTP \(status)，请求未成功；此状态不能单独确定订阅权限问题"
            case .requestRejected(let parameter):
                "ChatGPT 官方接口返回 HTTP 400：请求参数或模型能力不匹配" + (parameter.map { "（参数：\($0)）" } ?? "")
            case .responseFailed(let code):
                "ChatGPT 文本处理失败" + (code.map { "（错误代码：\($0)）" } ?? "，服务未返回可安全显示的错误代码")
            case .loginFailed: "ChatGPT 登录失败，请重试"
            case .expired: "ChatGPT 登录已失效，请重新登录"
            case .storage: "无法安全保存 ChatGPT 登录凭据"
            case .incomplete: "ChatGPT 未完成文本处理，已拒绝采用不完整结果，请重试或缩短录音"
            }
        }
    }

    private struct Credentials: Codable, Sendable {
        var clientID: String
        var subject: String
        var idToken: String
        var accessToken: String
        var refreshToken: String?
        var scopes: [String]
        var expiresAt: Date
    }
    private struct Record: Codable, Sendable {
        var hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
        var credentials: Credentials?
    }
    private struct Attempt: Sendable {
        var verifier: String
        var nonce: String
        var clientID: String?
        var expectedSubject: String?
        var redirectURI: String
        var generation: UUID
    }
    private var record: Record?
    private var listener: CodexOAuthCallbackListener?
    private var loginTask: Task<Void, any Error>?
    private var loginGeneration: UUID?
    private var loginStatus: String?
    private var loginError: Failure?
    private var refreshTask: Task<Credentials, any Error>?
    var jwks: [[String: String]] = []
    var jwksFetchedAt: Date?
    let session: URLSession
    static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    private static let credentialURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AIME/chatgpt-oauth.json")

    public init() {
        session = URLSession(configuration: .ephemeral, delegate: CodexOAuthHTTPDelegate(), delegateQueue: nil)
    }

    // Internal transport seam: protocol tests use synthetic credentials without touching login storage.
    init(session: URLSession) { self.session = session }

    /// The caller opens the returned official URL only after the user's login action.
    public func login() async throws -> URL {
        await cancelLogin()
        let saved = try loadRecord()
        if record == nil { record = saved }
        // The host identifier is stable even if the first authorization is cancelled.
        try save(saved)
        let state = try randomSecret()
        let nonce = try randomSecret()
        let verifier = try randomSecret()
        let callback = try await CodexOAuthCallbackListener.start(state: state)
        let current = UUID()
        let attempt = Attempt(verifier: verifier, nonce: nonce,
                              clientID: saved.credentials?.clientID,
                              expectedSubject: saved.credentials?.subject,
                              redirectURI: callback.redirectURI, generation: current)
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var values: [String: String] = [
            "client_id": attempt.clientID ?? "dynamic_agent_client",
            "ext_agent_host_id": saved.hostID, "response_type": "code",
            "redirect_uri": attempt.redirectURI,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": Self.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
        ]
        if attempt.clientID == nil { values["agent_name_hint"] = "AIME" }
        if let idToken = saved.credentials?.idToken { values["id_token_hint"] = idToken }
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { await callback.cancel(); throw Failure.loginFailed }
        listener = callback
        loginGeneration = current
        loginStatus = "正在等待浏览器完成 ChatGPT 登录"
        loginError = nil
        loginTask = Task {
            do {
                let result = try await callback.authorization()
                try await self.finishLogin(result, attempt: attempt, previous: saved)
            } catch {
                if self.loginGeneration == current {
                    let safeError = (error as? Failure) ?? .loginFailed
                    self.loginError = safeError
                    self.loginStatus = safeError.errorDescription
                    self.listener = nil
                    self.loginTask = nil
                    self.loginGeneration = nil
                }
                await callback.cancel()
                throw error is CancellationError ? CancellationError() : (error as? Failure) ?? .loginFailed
            }
            await callback.cancel()
            if self.loginGeneration == current {
                self.listener = nil
                self.loginTask = nil
                self.loginGeneration = nil
            }
        }
        return url
    }

    /// Waits for an already-started browser login; it never opens a browser or
    /// starts a fresh authorization. The settings UI can then fetch models once.
    public func waitForLogin() async throws {
        if let task = loginTask { try await task.value }
        if let loginError { throw loginError }
        guard let credentials = try loadRecord().credentials else { throw Failure.loginRequired }
        guard credentials.scopes.contains("chatgpt.tokens.use.direct") else { throw Failure.permission }
    }

    public func cancelLogin() async {
        loginGeneration = nil
        loginTask?.cancel()
        loginTask = nil
        if let listener { await listener.cancel() }
        listener = nil
        loginStatus = nil
        loginError = nil
    }

    public func accountStatus() async throws -> String {
        if let loginStatus { return loginStatus }
        guard let credentials = try loadRecord().credentials else { return "尚未登录 ChatGPT 订阅" }
        guard credentials.scopes.contains("chatgpt.tokens.use.direct") else { return "ChatGPT 已登录，但尚未授权计划使用权限" }
        if credentials.expiresAt < Date(), credentials.refreshToken == nil { return "ChatGPT 登录已失效，请重新登录" }
        return "ChatGPT 订阅已登录"
    }

    public func models() async throws -> [String] {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await json(request)
        guard let rows = response["models"] as? [[String: Any]] else { throw Failure.invalidResponse }
        // The subscription catalog differs from API-key /v1/models: it uses slugs.
        return rows.compactMap { row in
            guard row["visibility"] as? String == "list", let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            return slug
        }
    }

    public func complete(model: String, instructions: String, text: String) async throws -> String {
        let token = try await accessToken()
        let request = try Self.completionRequest(token: token, model: model, instructions: instructions, text: text)
        return try await complete(request: request)
    }

    private func finishLogin(_ result: CodexOAuthCallbackListener.Authorization, attempt: Attempt, previous: Record) async throws {
        try Task.checkCancellation()
        guard loginGeneration == attempt.generation else { throw CancellationError() }
        let client: String
        if let expected = attempt.clientID {
            guard result.clientID == nil || result.clientID == expected else { throw Failure.invalidIdentity }
            client = expected
        } else {
            guard let issued = result.clientID, issued.hasPrefix("oaiapp_"), issued != "dynamic_agent_client" else {
                throw Failure.invalidIdentity
            }
            client = issued
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": client, "code": result.code,
            "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI, "resource": Self.resource,
        ])
        let credentials = try await credentials(tokens, client: client, nonce: attempt.nonce, previous: previous.credentials)
        if let expected = attempt.expectedSubject, expected != credentials.subject { throw Failure.invalidIdentity }
        try Task.checkCancellation()
        guard loginGeneration == attempt.generation else { throw CancellationError() }
        var saved = previous
        saved.credentials = credentials
        try save(saved)
        record = saved
        loginStatus = credentials.scopes.contains("chatgpt.tokens.use.direct")
            ? "ChatGPT 订阅已登录" : "ChatGPT 已登录，但尚未授权计划使用权限"
    }

    private func accessToken() async throws -> String {
        guard var current = try loadRecord().credentials else { throw Failure.loginRequired }
        guard current.scopes.contains("chatgpt.tokens.use.direct") else { throw Failure.permission }
        if current.expiresAt.timeIntervalSinceNow <= 60 {
            if let refreshTask { current = try await refreshTask.value }
            else {
                guard current.refreshToken != nil else { throw Failure.expired }
                let original = current
                let task = Task {
                    try await self.refresh(original)
                }
                refreshTask = task
                defer { refreshTask = nil }
                current = try await task.value
            }
        }
        guard current.scopes.contains("chatgpt.tokens.use.direct") else { throw Failure.permission }
        return current.accessToken
    }

    private func refresh(_ original: Credentials) async throws -> Credentials {
        let lock = try await lockRefresh()
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        // The settings app may already have refreshed while the voice service waited.
        guard let before = try loadRecord().credentials,
              before.subject == original.subject, before.clientID == original.clientID else { throw Failure.expired }
        if before.expiresAt.timeIntervalSinceNow > 60 { return before }
        guard let rotatingToken = before.refreshToken else { throw Failure.expired }
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token", "client_id": before.clientID,
            "refresh_token": rotatingToken, "resource": Self.resource,
        ])
        let updated = try await credentials(tokens, client: before.clientID, nonce: nil, previous: before)
        var saved = try loadRecord()
        // Settings and the voice service are different processes. A successful new
        // login must not be overwritten by an older in-flight refresh in either one.
        guard let latest = saved.credentials, latest.subject == original.subject,
              latest.clientID == original.clientID else { throw Failure.expired }
        if latest.accessToken != before.accessToken { return latest }
        saved.credentials = updated
        try save(saved)
        record = saved
        return updated
    }

    private func lockRefresh() async throws -> Int32 {
        let path = Self.credentialURL.deletingLastPathComponent().appendingPathComponent("chatgpt-oauth-refresh.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.storage }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & 0o077 == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            _ = close(descriptor); throw Failure.storage
        }
        let deadline = Date().addingTimeInterval(30)
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { throw Failure.storage }
                try await Task.sleep(for: .milliseconds(100))
            }
            return descriptor
        } catch { _ = close(descriptor); throw error }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)
        return try await json(request)
    }

    private func credentials(_ tokens: [String: Any], client: String, nonce: String?, previous: Credentials?) async throws -> Credentials {
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
              let kind = tokens["token_type"] as? String, kind.lowercased() == "bearer",
              let seconds = tokens["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw Failure.invalidResponse }
        let idToken: String
        let subject: String
        if let fresh = tokens["id_token"] as? String {
            idToken = fresh
            subject = try await verifiedSubject(fresh, audience: client, nonce: nonce)
            if let previous, subject != previous.subject { throw Failure.invalidIdentity }
        } else if nonce == nil, let previous {
            idToken = previous.idToken
            subject = previous.subject
        } else { throw Failure.invalidIdentity }
        let scopes: [String]
        if let granted = tokens["scope"] as? String { scopes = granted.split(separator: " ").map(String.init) }
        else if nonce == nil, let previous { scopes = previous.scopes }
        else { throw Failure.permission }
        return Credentials(clientID: client, subject: subject, idToken: idToken,
                           accessToken: access, refreshToken: tokens["refresh_token"] as? String ?? previous?.refreshToken,
                           scopes: scopes, expiresAt: Date().addingTimeInterval(seconds))
    }

    func json(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        if request.timeoutInterval == 60 { request.timeoutInterval = 25 }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            // Do not surface OAuth response bodies; they may contain credentials or PII.
            if response.statusCode == 401 { throw Failure.expired }
            throw Self.inferenceFailure(status: response.statusCode, data: Data())
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        return object
    }

    private func loadRecord() throws -> Record {
        let url = Self.credentialURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Record() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { throw Failure.storage }
        let saved = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        record = saved
        return saved
    }

    private func save(_ value: Record) throws {
        let url = Self.credentialURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { throw Failure.storage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".chatgpt-oauth-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(value))
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw Failure.storage }
    }

    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.loginFailed }
        return Self.base64URL(Data(bytes))
    }
}

private final class CodexOAuthHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Authorization headers and token bodies must never follow a server redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
