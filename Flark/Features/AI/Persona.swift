import Foundation

/// One AI persona the user can summon into a topic. The persona's reply is
/// posted under the *current user's* identity (Flark events are signed by the
/// device key), with the persona's name baked into the message body as a label
/// — so no synthetic author identities or core signing changes are involved.
/// The avatar is derived from the name's first character (see `AvatarView`),
/// matching how human authors render in the topic list.
struct Persona: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    /// The system instruction handed to the model — defines the persona's voice.
    var systemPrompt: String
    /// Legacy free-text model override (pre model-registry). Kept only so older
    /// stored personas still decode; superseded by `modelOptionID`.
    var model: String = ""
    /// Selected model from the registry (see `ModelOption`). nil/empty ⇒ use the
    /// global default model. Optional so personas saved before the registry
    /// existed still decode (a missing key decodes to nil rather than throwing).
    var modelOptionID: String? = nil
}

/// A configured model the user can assign to a persona. `kind` selects the
/// provider. Under the hood there are three transports: Gemini uses the
/// built-in `GeminiClient`, Anthropic uses the native Messages API, and every
/// other provider is reached through an OpenAI-compatible endpoint pointed at
/// that provider's base URL (`Kind.presetBaseURL`, overridable via `baseURL`).
struct ModelOption: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case gemini
        case openAI
        case anthropic
        case xAI
        case openRouter
        case groq
        case deepSeek
        case mistral
        case together
        case perplexity
        case fireworks
        case ollama
        case custom = "openAICompatible"   // keeps registries saved by the old two-kind schema decoding

        var id: String { rawValue }

        /// Lenient: unknown / legacy raw values fall back to `.custom` instead of
        /// throwing, so older saved registries keep decoding.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .custom
        }

        var label: String {
            switch self {
            case .gemini:     return String(localized: "Gemini（Google）")
            case .openAI:     return "OpenAI"
            case .anthropic:  return String(localized: "Anthropic（Claude）")
            case .xAI:        return String(localized: "xAI（Grok）")
            case .openRouter: return "OpenRouter"
            case .groq:       return "Groq"
            case .deepSeek:   return "DeepSeek"
            case .mistral:    return "Mistral"
            case .together:   return "Together AI"
            case .perplexity: return "Perplexity"
            case .fireworks:  return "Fireworks AI"
            case .ollama:     return String(localized: "本地（Ollama / LM Studio）")
            case .custom:     return String(localized: "自定义（OpenAI 兼容）")
            }
        }

        /// Gemini and Anthropic use native transports; every other provider is
        /// reached through the OpenAI-compatible path.
        var isGemini: Bool { self == .gemini }
        var isAnthropic: Bool { self == .anthropic }

        /// Default provider endpoint root. For Anthropic this is the `/v1`
        /// API root; for OpenAI-compatible providers it is the root before
        /// `/chat/completions`. nil ⇒ OpenAI's own host, or user-supplied.
        var presetBaseURL: String? {
            switch self {
            case .gemini, .openAI, .ollama, .custom: return nil
            case .anthropic:  return "https://api.anthropic.com/v1"
            case .xAI:        return "https://api.x.ai/v1"
            case .openRouter: return "https://openrouter.ai/api/v1"
            case .groq:       return "https://api.groq.com/openai/v1"
            case .deepSeek:   return "https://api.deepseek.com"
            case .mistral:    return "https://api.mistral.ai/v1"
            case .together:   return "https://api.together.xyz/v1"
            case .perplexity: return "https://api.perplexity.ai"
            case .fireworks:  return "https://api.fireworks.ai/inference/v1"
            }
        }

        /// True when the user is expected to supply the base URL themselves.
        var usesCustomBaseURL: Bool { self == .ollama || self == .custom }

        /// Placeholder example for the model-id field.
        var modelIDHint: String {
            switch self {
            case .gemini:     return "gemini-2.0-flash"
            case .openAI:     return "gpt-4o"
            case .anthropic:  return "claude-3-5-sonnet-20241022"
            case .xAI:        return "grok-latest"
            case .openRouter: return "anthropic/claude-3.5-sonnet"
            case .groq:       return "llama-3.3-70b-versatile"
            case .deepSeek:   return "deepseek-chat"
            case .mistral:    return "mistral-large-latest"
            case .together:   return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
            case .perplexity: return "sonar"
            case .fireworks:  return "accounts/fireworks/models/llama-v3p1-70b-instruct"
            case .ollama:     return "llama3.2"
            case .custom:     return "your-model-id"
            }
        }
    }

    var id: String = UUID().uuidString
    var name: String
    var kind: Kind = .gemini
    /// Model id sent to the provider (see `Kind.modelIDHint` for examples).
    var modelID: String = ""
    /// Endpoint root override. Blank ⇒ `kind.presetBaseURL` (or OpenAI's own
    /// host for `.openAI`). Used for `.ollama` / `.custom`, and to correct a
    /// preset if a provider moves its URL.
    var baseURL: String = ""
    /// Provider API key. Secret — the whole registry lives in the Keychain.
    var apiKey: String = ""

    /// Effective endpoint root for the selected transport: an explicit
    /// `baseURL` wins, else the provider preset (nil ⇒ OpenAI's default host).
    var effectiveBaseURL: String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        if !normalized.isEmpty { return normalized }
        return kind.presetBaseURL
    }

    /// Label shown in lists / pickers. The display name is optional: fall back
    /// to the model id, then the provider label.
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return modelID }
        return kind.label
    }

    /// Does the configured model produce images? Inferred from the model id
    /// (see `ModelCapability`). Drives the image-output route in `LLMRunner`;
    /// everything else stays on the text/vision path (which still accepts images
    /// as input).
    var generatesImages: Bool { ModelCapability.generatesImages(id: modelID) }

    /// Best-effort guess that the model can read images (vision input). Used to
    /// tag rows in the model picker; the summon path attaches images regardless.
    var recognizesImages: Bool { ModelCapability.recognizesImages(id: modelID) }
}

/// Best-effort capability inference from a model id. Providers don't expose a
/// clean per-model capability flag through their list endpoints, so the model
/// picker (and the image-output router) read intent from the id alone. These
/// are hints, not guarantees — a mis-tag at worst means a request the provider
/// rejects, surfaced as an error.
enum ModelCapability {
    /// Dedicated image-generation models: Gemini's (`gemini-2.5-flash-image`,
    /// `*-image-generation`, `imagen-*`), OpenAI's (`gpt-image-1`, `dall-e-3`),
    /// and the common gateway aliases.
    static func generatesImages(id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("image")
            || s.contains("imagen")
            || s.contains("dall-e") || s.contains("dall·e")
            || s.contains("nano-banana")
    }

    /// Vision-capable (image input) families. Image-generation models are
    /// included since they also accept an input image (for editing).
    static func recognizesImages(id: String) -> Bool {
        let s = id.lowercased()
        if generatesImages(id: s) { return true }
        let markers = [
            "gemini", "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-4-vision", "chatgpt-4o",
            "o1", "o3", "o4-",
            "claude-3", "claude-4", "claude-opus", "claude-sonnet", "claude-haiku",
            "vision", "-vl", "vl-", "llava", "pixtral",
            "llama-3.2", "llama3.2", "llama-4", "llama4",
            "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl",
            "grok-2-vision", "grok-vision", "grok-4",
            "internvl", "minicpm-v", "phi-3.5-vision", "phi-4",
        ]
        return markers.contains { s.contains($0) }
    }
}

enum AISettingsKeys {
    static let personas = "flark.ai.personas.v1"
    /// Keychain account holding the JSON model registry (carries provider keys).
    static let models = "flark.ai.models.v1"
    /// UserDefaults key for the default model option's id.
    static let defaultModelOptionID = "flark.ai.defaultModelOptionID"
}

/// Config for the AI feature. Personas + the default-model pointer live in
/// `UserDefaults` (non-secret config); the model registry — which carries the
/// provider API keys — lives in the Keychain so the secrets never land on disk
/// in the clear and ride iCloud Keychain to the user's other devices.
enum AIConfig {
    // MARK: - Personas (UserDefaults JSON)

    static func loadPersonas() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: AISettingsKeys.personas),
              let list = try? JSONDecoder().decode([Persona].self, from: data) else {
            return defaultPersonas
        }
        return list
    }

    static func savePersonas(_ personas: [Persona]) {
        guard let data = try? JSONEncoder().encode(personas) else { return }
        UserDefaults.standard.set(data, forKey: AISettingsKeys.personas)
    }

    // MARK: - Model registry (Keychain JSON — carries provider secrets)

    static func loadModels() -> [ModelOption] {
        // Respect an explicitly-saved registry (even an empty one); only seed
        // when nothing has ever been written.
        if let data = Keychain.get(AISettingsKeys.models),
           let list = try? JSONDecoder().decode([ModelOption].self, from: data) {
            return list
        }
        return seededModels()
    }

    static func saveModels(_ models: [ModelOption]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        Keychain.set(data, account: AISettingsKeys.models, sync: true)
    }

    /// First-run seed so the registry isn't empty: a bare Gemini entry the user
    /// fills in with their own key. Fixed id keeps it stable across reads.
    private static func seededModels() -> [ModelOption] {
        [ModelOption(id: "default-gemini", name: "Gemini", kind: .gemini,
                     modelID: "gemini-2.0-flash")]
    }

    static var defaultModelOptionID: String? {
        get { UserDefaults.standard.string(forKey: AISettingsKeys.defaultModelOptionID) }
        set { UserDefaults.standard.set(newValue, forKey: AISettingsKeys.defaultModelOptionID) }
    }

    /// The model used when a persona doesn't pick one. Falls back to the first
    /// configured model.
    static func defaultModelOption() -> ModelOption? {
        let models = loadModels()
        if let id = defaultModelOptionID, let hit = models.first(where: { $0.id == id }) {
            return hit
        }
        return models.first
    }

    /// Resolve which model a persona should use: its explicit pick, else the
    /// global default.
    static func modelOption(for persona: Persona) -> ModelOption? {
        let models = loadModels()
        if let id = persona.modelOptionID, !id.isEmpty,
           let hit = models.first(where: { $0.id == id }) {
            return hit
        }
        return defaultModelOption()
    }

    /// True if at least one configured model has a usable API key — gates the
    /// summon picker.
    static var hasUsableModel: Bool {
        loadModels().contains {
            !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// True when the device language is Chinese — selects the seed language for
    /// personas / templates (display copy goes through the string catalog, but
    /// persona *data* is persisted, so it's branched at creation time instead).
    static var prefersChinese: Bool {
        (Locale.current.language.languageCode?.identifier ?? "").hasPrefix("zh")
    }

    /// Seed personas shown on first run; fully editable afterwards. Localized so
    /// an English-locale device starts with English names + prompts rather than
    /// Chinese ones.
    static var defaultPersonas: [Persona] {
        prefersChinese ? defaultPersonasZh : defaultPersonasEn
    }

    private static let defaultPersonasZh: [Persona] = [
        Persona(name: "苏格拉底",
                systemPrompt: "你是哲学家苏格拉底。用温和而犀利的反问，引导对话者自己思考，而不是直接给出结论。语气平和、简洁，多用提问。"),
        Persona(name: "程序员老王",
                systemPrompt: "你是一位资深软件工程师，务实、直接。简洁作答，必要时给出可操作的建议或权衡，不啰嗦。"),
        Persona(name: "段子手",
                systemPrompt: "你是个幽默风趣的段子手。用轻松俏皮、带点自嘲的语气回应话题，适度玩梗，但不要冒犯他人。"),
        Persona(name: "知心姐姐",
                systemPrompt: "你是温柔体贴的倾听者。先共情对方的感受，再给出温暖、具体而真诚的建议。语气柔和、有耐心。"),
    ]

    private static let defaultPersonasEn: [Persona] = [
        Persona(name: "Socrates",
                systemPrompt: "You are the philosopher Socrates. Guide the other person to think for themselves through gentle but incisive questions rather than handing over conclusions. Stay calm and concise, and ask often."),
        Persona(name: "The Engineer",
                systemPrompt: "You are a seasoned software engineer — pragmatic and direct. Answer concisely; when useful, offer actionable advice or trade-offs. No fluff."),
        Persona(name: "Jokester",
                systemPrompt: "You are a witty comedian. Respond with a light, playful, slightly self-deprecating tone and the occasional joke — but never at anyone's expense."),
        Persona(name: "The Confidante",
                systemPrompt: "You are a warm, attentive listener. First empathize with how the other person feels, then offer warm, concrete, sincere advice. Gentle and patient."),
    ]
}

/// Persona replies are posted under the user's own identity (Flark events are
/// signed by the device key). To still show the persona's *name* in the reply
/// header — instead of the posting user's — the body is prefixed with a hidden,
/// strippable marker carrying the persona name. Every member runs the same app
/// and strips it when rendering, while the real author stays recoverable from
/// the event's `authorID`.
enum PersonaTag {
    /// SOH control character — invisible and effectively never present in user
    /// text, so it can't collide with real content.
    private static let open = "\u{0001}persona:"
    private static let close = "\u{0001}"

    /// Wrap `content` (already a serialized markdown body) with the persona
    /// name marker.
    static func wrap(name: String, content: String) -> String {
        let safeName = name.replacingOccurrences(of: close, with: " ")
        return open + safeName + close + content
    }

    /// Returns the persona name + the remaining body content, or nil when the
    /// body carries no persona marker (i.e. a normal human reply).
    static func unwrap(_ body: String) -> (name: String, content: String)? {
        guard body.hasPrefix(open) else { return nil }
        let afterOpen = body.dropFirst(open.count)
        guard let closeRange = afterOpen.range(of: close) else { return nil }
        let name = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
        let content = String(afterOpen[closeRange.upperBound...])
        return (name, content)
    }
}
