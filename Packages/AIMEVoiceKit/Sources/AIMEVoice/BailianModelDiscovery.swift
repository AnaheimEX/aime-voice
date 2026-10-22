import Foundation

/// Native catalog includes ASR models; no hardcoded model list or guessed model IDs.
enum BailianModelDiscovery {
    static func models(endpoint: VoiceEndpoint) async throws -> [String] {
        guard var components = URLComponents(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "wss", components.host != nil,
              components.path == "/api-ws/v1/inference", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !endpoint.apiKey.isEmpty, !endpoint.apiKey.contains("\r"), !endpoint.apiKey.contains("\n") else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        components.scheme = "https"
        components.path = "/api/v1/models"
        let session = URLSession(configuration: .ephemeral, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        struct Response: Decodable {
            struct Output: Decodable {
                struct Model: Decodable { let model: String }
                let total: Int
                let models: [Model]
            }
            let output: Output
        }
        var ids: [String] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            components.queryItems = [
                .init(name: "capabilities", value: "Realtime-ASR"),
                .init(name: "page_no", value: String(page)), .init(name: "page_size", value: "100")
            ]
            guard let url = components.url else { throw VoiceHTTP.Failure.endpoint }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw VoiceHTTP.Failure.response }
            guard (200..<300).contains(response.statusCode) else { throw VoiceHTTP.Failure.status(response.statusCode) }
            let output = try JSONDecoder().decode(Response.self, from: data).output
            ids.append(contentsOf: output.models.map(\.model))
            if ids.count >= output.total || output.models.isEmpty { break }
            page += 1
            guard page <= 100 else { throw VoiceHTTP.Failure.response }
        }
        // These provider families share run-task; the older qwen*-realtime family does not.
        return ids.filter {
            let model = $0.lowercased()
            return (model.hasPrefix("qwen-audio-") && model.hasSuffix("-streaming"))
                || model.hasPrefix("fun-asr") || model.hasPrefix("paraformer-realtime")
        }
    }
}
