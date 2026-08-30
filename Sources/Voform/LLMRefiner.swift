import Foundation

enum LLMRefinerError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The API Base URL is invalid."
        case .invalidResponse: return "The API returned an invalid response."
        case .server(let status, let message): return "API error \(status): \(message)"
        case .emptyResponse: return "The API returned no refined text."
        }
    }
}

final class LLMRefiner {
    static let systemPrompt = """
    You correct speech-recognition transcripts. Be extremely conservative. Only fix obvious recognition errors, including clear Chinese homophone mistakes and English technical terms that were mistakenly rendered as Chinese sounds (for example 配森→Python and 杰森→JSON). Never rewrite, polish, summarize, reorder, or remove content that appears correct. Preserve the speaker's wording, tone, punctuation, language mixing, and every correct detail. If the transcript looks correct, return it exactly as-is. Return only the corrected transcript with no explanation, quotation marks, or markdown.
    """

    private struct RequestBody: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    func refine(_ transcript: String, configuration: LLMConfiguration) async throws -> String {
        let endpoint = try endpointURL(from: configuration.baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: configuration.model,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: transcript)
            ],
            temperature: 0
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMRefinerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw LLMRefinerError.server(status: http.statusCode, message: String(message.prefix(500)))
        }
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = body.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMRefinerError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpointURL(from base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https" || components.scheme == "http",
              components.host != nil else { throw LLMRefinerError.invalidBaseURL }
        var path = components.path
        if !path.hasSuffix("/chat/completions") {
            if path.hasSuffix("/") { path.removeLast() }
            path += "/chat/completions"
        }
        components.path = path
        guard let url = components.url else { throw LLMRefinerError.invalidBaseURL }
        return url
    }
}
