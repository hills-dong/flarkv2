import Foundation
import FlarkKit

/// Result of one model generation. `text` is the model's prose (may be empty
/// for a pure image generation); `images` carries any pictures the model
/// produced, as the raw encoded bytes the provider returned (PNG/JPEG). The
/// caller uploads them to the blob store and embeds them in the reply.
struct LLMResult {
    var text: String
    var images: [Data]

    init(text: String, images: [Data] = []) {
        self.text = text
        self.images = images
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }
}

/// Minimal client for Google Gemini's `generateContent` REST endpoint. The app
/// is serverless / local-first, so the request goes straight from the device
/// with the user's own API key (kept in the Keychain — see `AIConfig`).
///
/// Multimodal: `inputImages` ride along as `inline_data` parts so the model can
/// *see* pictures already in the thread, and `wantsImageOutput` flips an
/// image-capable model (`gemini-2.5-flash-image`, `*-image-generation`) into
/// text+image mode via `responseModalities`, returning inline image bytes.
struct GeminiClient {
    let apiKey: String

    enum GeminiError: LocalizedError {
        case missingKey
        case http(status: Int, message: String)
        case blocked(String)
        case empty
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "尚未配置 Gemini API Key。")
            case .http(let status, let message):
                return message.isEmpty
                    ? String(localized: "Gemini 请求失败（\(status)）")
                    : String(localized: "Gemini 请求失败（\(status)）：\(message)")
            case .blocked(let reason):
                return String(localized: "内容被安全策略拦截（\(reason)）。")
            case .empty:
                return String(localized: "Gemini 没有返回任何内容。")
            case .transport(let detail):
                return String(localized: "网络错误：\(detail)")
            }
        }
    }

    /// One-shot generation: `systemPrompt` is the persona's voice, `userPrompt`
    /// is the flattened conversation context, `inputImages` are JPEG bytes the
    /// model should look at. With `wantsImageOutput` the model is asked for
    /// pictures too. Returns the model's text plus any images it produced.
    func generate(model: String,
                  systemPrompt: String,
                  userPrompt: String,
                  inputImages: [Data] = [],
                  wantsImageOutput: Bool = false) async throws -> LLMResult {
        guard !apiKey.isEmpty else { throw GeminiError.missingKey }

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else {
            throw GeminiError.transport(String(localized: "无效的请求地址"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than `?key=` so the secret doesn't ride in URLs / logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = wantsImageOutput ? 120 : 60

        // Image-generation models reject a separate `system_instruction`, so
        // fold the persona voice into the user turn there; for text the system
        // block keeps the instruction out of the conversation context.
        let leadingText = (wantsImageOutput && !systemPrompt.isEmpty)
            ? systemPrompt + "\n\n" + userPrompt
            : userPrompt
        var parts: [Part] = [.text(leadingText)]
        for image in inputImages {
            parts.append(.inlineData(mimeType: "image/jpeg", data: image.base64EncodedString()))
        }

        let payload = RequestBody(
            systemInstruction: wantsImageOutput ? nil : .init(parts: [.text(systemPrompt)]),
            contents: [.init(role: "user", parts: parts)],
            generationConfig: wantsImageOutput
                ? .init(responseModalities: ["TEXT", "IMAGE"])
                : .init(temperature: 0.9, maxOutputTokens: 800))
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response, _) = try await AITransport.perform(request, action: "gemini.generate", model: model)
        } catch {
            throw GeminiError.transport(error.localizedDescription)
        }

        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw GeminiError.http(status: status, message: AITransport.errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let block = decoded.promptFeedback?.blockReason {
            throw GeminiError.blocked(block)
        }

        var text = ""
        var images: [Data] = []
        for part in decoded.candidates?.first?.content?.parts ?? [] {
            if let t = part.text { text += t }
            if let inline = part.inlineData?.data, let bytes = Data(base64Encoded: inline) {
                images.append(bytes)
            }
        }
        let result = LLMResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               images: images)
        guard !result.isEmpty else { throw GeminiError.empty }
        return result
    }

    // MARK: - Wire format

    private struct RequestBody: Encodable {
        var systemInstruction: Content?
        var contents: [Content]
        var generationConfig: GenerationConfig

        enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents
            case generationConfig
        }
    }

    private struct Content: Encodable {
        var role: String? = nil   // omitted for system_instruction
        var parts: [Part]
    }

    /// A content part is either text or inline (base64) image bytes.
    private enum Part: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
        enum InlineKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let t):
                try c.encode(t, forKey: .text)
            case .inlineData(let mime, let data):
                var nested = c.nestedContainer(keyedBy: InlineKeys.self, forKey: .inlineData)
                try nested.encode(mime, forKey: .mimeType)
                try nested.encode(data, forKey: .data)
            }
        }
    }

    private struct GenerationConfig: Encodable {
        var temperature: Double? = nil
        var maxOutputTokens: Int? = nil
        var responseModalities: [String]? = nil
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            struct ContentBlock: Decodable {
                struct PartBlock: Decodable {
                    struct Inline: Decodable {
                        var mimeType: String?
                        var data: String?
                    }
                    var text: String?
                    var inlineData: Inline?
                }
                var parts: [PartBlock]?
            }
            var content: ContentBlock?
        }
        struct PromptFeedback: Decodable { var blockReason: String? }
        var candidates: [Candidate]?
        var promptFeedback: PromptFeedback?
    }
}

/// Native client for Anthropic's Messages API. Claude uses a top-level
/// `system` prompt plus a `messages` array; image inputs are attached as
/// base64 image blocks when present.
enum AnthropicClient {
    enum ClientError: LocalizedError {
        case missingKey
        case empty
        case http(status: Int, message: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "尚未配置 Anthropic API Key。")
            case .empty:
                return String(localized: "Anthropic 没有返回任何内容。")
            case .http(let status, let message):
                return message.isEmpty
                    ? String(localized: "Anthropic 请求失败（\(status)）")
                    : String(localized: "Anthropic 请求失败（\(status)）：\(message)")
            case .transport(let detail):
                return String(localized: "网络错误：\(detail)")
            }
        }
    }

    private static let defaultBaseURL = "https://api.anthropic.com/v1"
    private static let apiVersion = "2023-06-01"

    static func generate(option: ModelOption,
                         systemPrompt: String,
                         userPrompt: String,
                         inputImages: [Data] = []) async throws -> LLMResult {
        let key = option.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingKey }

        do {
            return try await request(option: option, key: key, systemPrompt: systemPrompt,
                                     userPrompt: userPrompt, inputImages: inputImages)
        } catch {
            // Claude vision is best-effort too; if the selected model rejects
            // image blocks, retry once with plain text rather than failing the
            // summon outright on an otherwise-valid thread.
            if !inputImages.isEmpty {
                return try await request(option: option, key: key, systemPrompt: systemPrompt,
                                         userPrompt: userPrompt, inputImages: [])
            }
            throw error
        }
    }

    private static func request(option: ModelOption,
                                key: String,
                                systemPrompt: String,
                                userPrompt: String,
                                inputImages: [Data]) async throws -> LLMResult {
        let root = AITransport.root(option.effectiveBaseURL, default: defaultBaseURL)
        guard let url = URL(string: root + "/messages") else {
            throw ClientError.transport(String(localized: "无效的请求地址"))
        }

        let content: MessageContent
        if inputImages.isEmpty {
            content = .text(userPrompt)
        } else {
            var blocks: [ContentBlock] = [.text(userPrompt)]
            for image in inputImages {
                blocks.append(.imageBase64(mimeType: "image/jpeg", data: image.base64EncodedString()))
            }
            content = .blocks(blocks)
        }

        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = RequestBody(model: option.modelID,
                               maxTokens: 800,
                               system: trimmedSystem.isEmpty ? nil : trimmedSystem,
                               messages: [.init(role: "user", content: content)],
                               temperature: 0.9)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response, _) = try await AITransport.perform(request, action: "anthropic.messages",
                                                                model: option.modelID)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: AITransport.errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = (decoded.content ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.empty }
        return LLMResult(text: text)
    }

    private struct RequestBody: Encodable {
        var model: String
        var maxTokens: Int
        var system: String?
        var messages: [Message]
        var temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case temperature
        }
    }

    private struct Message: Encodable {
        var role: String
        var content: MessageContent
    }

    private enum MessageContent: Encodable {
        case text(String)
        case blocks([ContentBlock])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .blocks(let blocks):
                try container.encode(blocks)
            }
        }
    }

    private enum ContentBlock: Encodable {
        case text(String)
        case imageBase64(mimeType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case source
        }
        enum SourceKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageBase64(let mimeType, let data):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mimeType, forKey: .mediaType)
                try source.encode(data, forKey: .data)
            }
        }
    }

    private struct ResponseBody: Decodable {
        var content: [Content]?

        struct Content: Decodable {
            var type: String
            var text: String?
        }
    }
}

/// Dispatches a generation request to the right backend for a `ModelOption`:
/// Gemini and Anthropic through their native REST APIs, OpenAI-compatible image
/// models through the images endpoint (`OpenAIImageClient`), and every other
/// OpenAI-compatible chat model through a direct `chat/completions` call.
/// Vision input (`inputImages`) flows on every path that supports it; image
/// output is selected automatically from the model id (`generatesImages`).
enum LLMRunner {
    static func generate(option: ModelOption,
                         systemPrompt: String,
                         userPrompt: String,
                         inputImages: [Data] = []) async throws -> LLMResult {
        let wantsImageOutput = option.generatesImages

        if option.kind.isGemini {
            return try await GeminiClient(apiKey: option.apiKey)
                .generate(model: option.modelID, systemPrompt: systemPrompt, userPrompt: userPrompt,
                          inputImages: inputImages, wantsImageOutput: wantsImageOutput)
        }

        if option.kind.isAnthropic {
            return try await AnthropicClient
                .generate(option: option, systemPrompt: systemPrompt, userPrompt: userPrompt,
                          inputImages: inputImages)
        }

        if wantsImageOutput {
            // OpenAI-compatible image models live behind a dedicated endpoint
            // (`images/generations`) that takes a single prompt, so fold the
            // persona voice in rather than passing a system message.
            let prompt = systemPrompt.isEmpty ? userPrompt : systemPrompt + "\n\n" + userPrompt
            return try await OpenAIImageClient.generate(option: option, prompt: prompt)
        }

        return try await OpenAICompatibleClient
            .generate(option: option, systemPrompt: systemPrompt, userPrompt: userPrompt,
                      inputImages: inputImages)
    }
}

/// Calls any OpenAI-compatible chat-completions endpoint directly with the
/// user's own key. `option.baseURL` blank ⇒ OpenAI itself; otherwise the given
/// gateway (OpenRouter, Groq, DeepSeek, Together, local Ollama/LM Studio, …).
/// `inputImages` are attached as base64 `image_url` content parts so
/// vision-capable models can read them.
enum OpenAICompatibleClient {
    enum ClientError: LocalizedError {
        case missingKey
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return String(localized: "该模型尚未配置 API Key。")
            case .empty: return String(localized: "模型没有返回任何内容。")
            case .failed(let detail): return String(localized: "请求失败：\(detail)")
            }
        }
    }

    private static let defaultBaseURL = "https://api.openai.com/v1"

    static func generate(option: ModelOption,
                         systemPrompt: String,
                         userPrompt: String,
                         inputImages: [Data] = []) async throws -> LLMResult {
        let key = option.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingKey }

        do {
            return try await request(option: option, key: key, systemPrompt: systemPrompt,
                                     userPrompt: userPrompt, inputImages: inputImages)
        } catch {
            // Text-only models reject a request that carries images. Vision is
            // best-effort, so fall back to a text-only attempt rather than
            // failing the summon outright on a thread that happens to have
            // pictures.
            if !inputImages.isEmpty {
                return try await request(option: option, key: key, systemPrompt: systemPrompt,
                                         userPrompt: userPrompt, inputImages: [])
            }
            throw error
        }
    }

    private static func request(option: ModelOption,
                                key: String,
                                systemPrompt: String,
                                userPrompt: String,
                                inputImages: [Data]) async throws -> LLMResult {
        let root = AITransport.root(option.effectiveBaseURL, default: defaultBaseURL)
        guard let url = URL(string: root + "/chat/completions") else {
            throw ClientError.failed(String(localized: "无效的请求地址"))
        }

        let userContent: OpenAIChatRequestBody.MessageContent
        if inputImages.isEmpty {
            userContent = .text(userPrompt)
        } else {
            var contentParts: [OpenAIChatRequestBody.ContentPart] = [.text(userPrompt)]
            for image in inputImages {
                contentParts.append(.imageURL("data:image/jpeg;base64,\(image.base64EncodedString())",
                                              detail: "auto"))
            }
            userContent = .parts(contentParts)
        }

        let body = OpenAIChatRequestBody(
            model: option.modelID,
            messages: [
                .init(role: "system", content: .text(systemPrompt)),
                .init(role: "user", content: userContent),
            ],
            temperature: 0.9)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response, _) = try await AITransport.perform(
                request, action: "\(option.kind.rawValue).chat", model: option.modelID)
            guard (200..<300).contains(response.statusCode) else {
                throw ClientError.failed(AITransport.errorMessage(from: data))
            }

            let decoded = try JSONDecoder().decode(OpenAIChatResponseBody.self, from: data)
            let text = (decoded.choices.first?.message.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ClientError.empty }
            return LLMResult(text: text)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.failed(error.localizedDescription)
        }
    }
}

/// Hand-rolled client for the OpenAI-compatible *image generation* endpoint
/// (`{baseURL}/images/generations`). It accepts any model id (gpt-image-1,
/// dall-e-3) and any base URL, so OpenAI-compatible gateways work too.
/// `response_format` is deliberately omitted: gpt-image-1 rejects it and
/// always returns base64, while dall-e-3 defaults to a CDN URL — both are
/// handled by reading `b64_json` first and falling back to fetching `url`.
enum OpenAIImageClient {
    enum ClientError: LocalizedError {
        case missingKey
        case empty
        case http(status: Int, message: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "该模型尚未配置 API Key。")
            case .empty:
                return String(localized: "模型没有返回图片。")
            case .http(let status, let message):
                return message.isEmpty
                    ? String(localized: "生成图片失败（\(status)）")
                    : String(localized: "生成图片失败（\(status)）：\(message)")
            case .transport(let detail):
                return String(localized: "网络错误：\(detail)")
            }
        }
    }

    private static let defaultBaseURL = "https://api.openai.com/v1"

    static func generate(option: ModelOption, prompt: String) async throws -> LLMResult {
        let key = option.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingKey }

        let root = AITransport.root(option.effectiveBaseURL, default: defaultBaseURL)
        guard let url = URL(string: root + "/images/generations") else {
            throw ClientError.transport(String(localized: "无效的请求地址"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            ImageRequest(model: option.modelID, prompt: prompt, n: 1))

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response, _) = try await AITransport.perform(
                request, action: "\(option.kind.rawValue).image", model: option.modelID)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: AITransport.errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
        var images: [Data] = []
        for item in decoded.data ?? [] {
            if let b64 = item.b64JSON, let bytes = Data(base64Encoded: b64) {
                images.append(bytes)
            } else if let urlString = item.url,
                      let imageURL = URL(string: urlString),
                      let bytes = try? await URLSession.shared.data(from: imageURL).0 {
                images.append(bytes)
            }
        }
        guard !images.isEmpty else { throw ClientError.empty }
        return LLMResult(text: "", images: images)
    }

    private struct ImageRequest: Encodable {
        var model: String
        var prompt: String
        var n: Int
    }

    private struct ImageResponse: Decodable {
        struct Item: Decodable {
            var b64JSON: String?
            var url: String?

            enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case url
            }
        }
        var data: [Item]?
    }
}

/// One model returned by a provider's list endpoint, tagged with best-effort
/// capability hints (see `ModelCapability`) so the picker can flag which models
/// can read / make images.
struct RemoteModel: Identifiable, Hashable {
    var id: String
    var displayName: String?
    var recognizesImages: Bool
    var generatesImages: Bool
}

/// Fetches a provider's available model list so the user can pick rather than
/// type an id. Gemini and Anthropic use their native list endpoints; every
/// other provider uses the OpenAI-compatible `GET {base}/models`. Needs the key
/// (and base URL) already entered — hence the picker sits below those fields in
/// the editor.
enum ModelCatalogFetcher {
    enum FetchError: LocalizedError {
        case missingKey
        case http(status: Int, message: String)
        case transport(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "请先填写 API Key，再获取模型列表。")
            case .http(let status, let message):
                return message.isEmpty
                    ? String(localized: "获取模型列表失败（\(status)）")
                    : String(localized: "获取模型列表失败（\(status)）：\(message)")
            case .transport(let detail):
                return String(localized: "网络错误：\(detail)")
            case .empty:
                return String(localized: "没有获取到可用的模型。")
            }
        }
    }

    private static let anthropicDefaultBaseURL = "https://api.anthropic.com/v1"
    private static let anthropicVersion = "2023-06-01"
    private static let openAIDefaultBaseURL = "https://api.openai.com/v1"

    static func fetch(option: ModelOption) async throws -> [RemoteModel] {
        let key = option.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FetchError.missingKey }
        if option.kind.isGemini {
            return try await fetchGemini(key: key)
        }
        if option.kind.isAnthropic {
            return try await fetchAnthropic(key: key, baseURL: option.effectiveBaseURL)
        }
        return try await fetchOpenAI(kind: option.kind, key: key, baseURL: option.effectiveBaseURL)
    }

    private static func fetchGemini(key: String) async throws -> [RemoteModel] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000") else {
            throw FetchError.transport(String(localized: "无效的请求地址"))
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        let (data, response) = try await send(request, action: "gemini.models")
        try checkStatus(response, data)

        let decoded = try JSONDecoder().decode(GeminiList.self, from: data)
        let models: [RemoteModel] = (decoded.models ?? []).compactMap { m in
            // Only models we can actually drive through generateContent —
            // skips embeddings / aqa / predict-only Imagen.
            guard (m.supportedGenerationMethods ?? []).contains("generateContent") else { return nil }
            let id = m.name.hasPrefix("models/") ? String(m.name.dropFirst("models/".count)) : m.name
            return RemoteModel(id: id, displayName: m.displayName,
                               recognizesImages: ModelCapability.recognizesImages(id: id),
                               generatesImages: ModelCapability.generatesImages(id: id))
        }
        guard !models.isEmpty else { throw FetchError.empty }
        return dedupSorted(models)
    }

    private static func fetchAnthropic(key: String, baseURL: String?) async throws -> [RemoteModel] {
        let root = AITransport.root(baseURL, default: anthropicDefaultBaseURL)
        guard let url = URL(string: root + "/models?limit=1000") else {
            throw FetchError.transport(String(localized: "无效的请求地址"))
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        let (data, response) = try await send(request, action: "anthropic.models")
        try checkStatus(response, data)

        let decoded = try JSONDecoder().decode(AnthropicList.self, from: data)
        let models: [RemoteModel] = (decoded.data ?? []).map { m in
            RemoteModel(id: m.id, displayName: m.displayName,
                        recognizesImages: ModelCapability.recognizesImages(id: m.id),
                        generatesImages: ModelCapability.generatesImages(id: m.id))
        }
        guard !models.isEmpty else { throw FetchError.empty }
        return dedupSorted(models)
    }

    private static func fetchOpenAI(kind: ModelOption.Kind,
                                    key: String,
                                    baseURL: String?) async throws -> [RemoteModel] {
        let root = AITransport.root(baseURL, default: openAIDefaultBaseURL)
        guard let url = URL(string: root + "/models") else {
            throw FetchError.transport(String(localized: "无效的请求地址"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await send(request, action: "\(kind.rawValue).models")
        try checkStatus(response, data)

        let decoded = try JSONDecoder().decode(OpenAIList.self, from: data)
        let models: [RemoteModel] = (decoded.data ?? []).map { m in
            RemoteModel(id: m.id, displayName: nil,
                        recognizesImages: ModelCapability.recognizesImages(id: m.id),
                        generatesImages: ModelCapability.generatesImages(id: m.id))
        }
        guard !models.isEmpty else { throw FetchError.empty }
        return dedupSorted(models)
    }

    private static func send(_ request: URLRequest, action: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response, _) = try await AITransport.perform(request, action: action)
            return (data, response)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
    }

    private static func checkStatus(_ response: HTTPURLResponse, _ data: Data) throws {
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw FetchError.http(status: status, message: AITransport.errorMessage(from: data))
        }
    }

    private static func dedupSorted(_ models: [RemoteModel]) -> [RemoteModel] {
        var seen = Set<String>()
        let unique = models.filter { seen.insert($0.id).inserted }
        return unique.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private struct GeminiList: Decodable {
        struct Item: Decodable {
            var name: String
            var displayName: String?
            var supportedGenerationMethods: [String]?
        }
        var models: [Item]?
    }

    private struct AnthropicList: Decodable {
        struct Item: Decodable {
            var id: String
            var displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
        var data: [Item]?
    }

    private struct OpenAIList: Decodable {
        struct Item: Decodable { var id: String }
        var data: [Item]?
    }
}

private struct OpenAIChatRequestBody: Encodable {
    var model: String
    var messages: [Message]
    var temperature: Double?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
    }

    struct Message: Encodable {
        var role: String
        var content: MessageContent
    }

    enum MessageContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    struct ContentPart: Encodable {
        var type: String
        var text: String?
        var imageURL: ImageURLPayload?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ text: String) -> ContentPart {
            ContentPart(type: "text", text: text, imageURL: nil)
        }

        static func imageURL(_ url: String, detail: String? = nil) -> ContentPart {
            ContentPart(type: "image_url", text: nil,
                        imageURL: ImageURLPayload(url: url, detail: detail))
        }
    }

    struct ImageURLPayload: Encodable {
        var url: String
        var detail: String?
    }
}

private struct OpenAIChatResponseBody: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var role: String?
        var content: String?

        enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decode(String.self, forKey: .role)

            if let text = try? container.decode(String.self, forKey: .content) {
                content = text
                return
            }
            if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                content = parts.compactMap(\.text).joined()
                return
            }
            content = nil
        }
    }

    struct ContentPart: Decodable {
        var type: String?
        var text: String?
    }
}

private enum AITransport {
    static func perform(_ request: URLRequest,
                        action: String,
                        model: String? = nil) async throws -> (Data, HTTPURLResponse, Int) {
        let started = Date()
        AIActivityLog.recordRequest(action: action, url: request.url, model: model, body: request.httpBody)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let durationMs = elapsedMilliseconds(since: started)
            guard let http = response as? HTTPURLResponse else {
                AIActivityLog.recordTransportError(action: action, url: request.url,
                                                   detail: "Non-HTTP response", durationMs: durationMs)
                throw URLError(.badServerResponse)
            }
            AIActivityLog.recordResponse(action: action, url: request.url, status: http.statusCode,
                                         body: data, durationMs: durationMs)
            return (data, http, durationMs)
        } catch {
            let durationMs = elapsedMilliseconds(since: started)
            AIActivityLog.recordTransportError(action: action, url: request.url,
                                               detail: error.localizedDescription,
                                               durationMs: durationMs)
            throw error
        }
    }

    static func root(_ baseURL: String?, default defaultBaseURL: String) -> String {
        let base = (baseURL ?? defaultBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    static func errorMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
            ?? String(data: data, encoding: .utf8)?.prefix(200).description
            ?? ""
    }

    private static func elapsedMilliseconds(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private struct APIErrorEnvelope: Decodable {
        struct Detail: Decodable { var message: String? }
        var error: Detail
    }
}

private enum AIActivityLog {
    private static let maxLoggedCharacters = 16_000
    private static let maxInlineDataCharacters = 120

    static func recordRequest(action: String, url: URL?, model: String?, body: Data?) {
        FlarkLog.shared.record(.info, .ai, "REQ \(action)",
                               path: url?.absoluteString,
                               detail: requestDetail(model: model, body: body),
                               bytes: body?.count)
    }

    static func recordResponse(action: String, url: URL?, status: Int, body: Data, durationMs: Int) {
        let level: LogEvent.Level = (200..<300).contains(status) ? .info : .error
        let detail = """
        status: \(status)
        response:
        \(renderPayload(body))
        """
        FlarkLog.shared.record(level, .ai, "RES \(action)",
                               path: url?.absoluteString,
                               detail: detail,
                               bytes: body.count,
                               durationMs: durationMs)
    }

    static func recordTransportError(action: String, url: URL?, detail: String, durationMs: Int) {
        FlarkLog.shared.record(.error, .ai, "ERR \(action)",
                               path: url?.absoluteString,
                               detail: "error: \(detail)",
                               durationMs: durationMs)
    }

    private static func requestDetail(model: String?, body: Data?) -> String {
        var lines: [String] = []
        if let model, !model.isEmpty {
            lines.append("model: \(model)")
        }
        if let body {
            lines.append("request:")
            lines.append(renderPayload(body))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderPayload(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object) {
            let sanitized = sanitize(object, parentKey: nil)
            if let pretty = prettyPrintedJSONString(from: sanitized) {
                return truncate(pretty)
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return truncate(sanitizeString(text, key: nil))
        }
        return "<\(data.count) bytes>"
    }

    private static func prettyPrintedJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func sanitize(_ value: Any, parentKey: String?) -> Any {
        if let dict = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (key, val) in dict {
                sanitized[key] = sanitize(val, parentKey: key)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0, parentKey: parentKey) }
        }
        if let string = value as? String {
            return sanitizeString(string, key: parentKey)
        }
        return value
    }

    private static func sanitizeString(_ string: String, key: String?) -> String {
        let lowercasedKey = key?.lowercased()
        if lowercasedKey == "data" || lowercasedKey == "b64_json" {
            return "<base64 \(string.count) chars>"
        }

        if string.hasPrefix("data:image/"), let comma = string.firstIndex(of: ",") {
            let prefix = String(string[..<comma])
            let payload = string[string.index(after: comma)...]
            return "\(prefix),<base64 \(payload.count) chars>"
        }

        if string.count > maxInlineDataCharacters,
           let lowercasedKey,
           lowercasedKey.contains("data") || lowercasedKey.contains("image") {
            return "<\(string.count) chars>"
        }

        return string
    }

    private static func truncate(_ string: String) -> String {
        guard string.count > maxLoggedCharacters else { return string }
        let idx = string.index(string.startIndex, offsetBy: maxLoggedCharacters)
        return String(string[..<idx]) + "\n… <truncated>"
    }
}
