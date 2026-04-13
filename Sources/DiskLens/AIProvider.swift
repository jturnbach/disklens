import Foundation
import SwiftUI
import AppKit

// All four supported providers funnel through one Codable-friendly enum so
// the chat code never has to switch on provider.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openAI
    case anthropic
    case gemini
    case xAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Google Gemini"
        case .xAI:       return "xAI"
        }
    }

    var productName: String {
        switch self {
        case .openAI:    return "ChatGPT"
        case .anthropic: return "Claude"
        case .gemini:    return "Gemini"
        case .xAI:       return "Grok"
        }
    }

    // Name of the bundled PNG logo inside Resources/Logos.
    var logoResourceName: String {
        switch self {
        case .openAI:    return "openai"
        case .anthropic: return "claude"
        case .gemini:    return "gemini"
        case .xAI:       return "grok"
        }
    }

    // SF Symbol fallback if the logo image fails to load.
    var fallbackSymbol: String {
        switch self {
        case .openAI:    return "bubble.left.and.bubble.right.fill"
        case .anthropic: return "sparkle"
        case .gemini:    return "diamond.fill"
        case .xAI:       return "x.circle.fill"
        }
    }

    // Official-ish brand colors used for accent tinting of cards, buttons,
    // and the toolbar. Sourced from each provider's public brand materials.
    var accentColor: Color {
        switch self {
        case .openAI:    return Color(red: 0.063, green: 0.639, blue: 0.545)  // OpenAI teal
        case .anthropic: return Color(red: 0.851, green: 0.459, blue: 0.341)  // Claude coral
        case .gemini:    return Color(red: 0.259, green: 0.522, blue: 0.957)  // Google blue
        case .xAI:       return Color(red: 0.10,  green: 0.10,  blue: 0.10)   // Grok near-black
        }
    }

    // Background tint for the logo badge — brand color at low opacity, or
    // a light gray for providers with dark logos on dark backgrounds.
    var badgeBackground: Color {
        switch self {
        case .openAI:    return Color.white
        case .anthropic: return Color(red: 1.0, green: 0.95, blue: 0.92)
        case .gemini:    return Color.white
        case .xAI:       return Color.white
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .gemini:    return "gemini-2.0-flash"
        case .xAI:       return "grok-2-latest"
        }
    }

    var availableModels: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo", "o1-mini"]
        case .anthropic:
            return ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-6"]
        case .gemini:
            return ["gemini-2.0-flash", "gemini-1.5-flash", "gemini-1.5-pro"]
        case .xAI:
            return ["grok-2-latest", "grok-2", "grok-beta"]
        }
    }

    var apiKeyHelpURL: String {
        switch self {
        case .openAI:    return "https://platform.openai.com/api-keys"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .gemini:    return "https://aistudio.google.com/app/apikey"
        case .xAI:       return "https://console.x.ai"
        }
    }

    var keychainAccount: String { "key.\(rawValue)" }
}

// MARK: - Logo badge

// Loads the bundled PNG logo for a provider via Bundle.module. Kept in one
// place so every call site — setup picker, welcome footer, toolbar button,
// chat header — renders consistently.
enum ProviderLogo {
    static func image(for provider: AIProvider) -> NSImage? {
        // SwiftPM puts processed resources in the target's Bundle.module.
        if let url = Bundle.module.url(
            forResource: provider.logoResourceName,
            withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
}

struct ProviderLogoView: View {
    let provider: AIProvider
    var size: CGFloat = 28
    var padding: CGFloat = 6
    var background: Bool = true

    var body: some View {
        ZStack {
            if background {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(provider.badgeBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.22,
                                          style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08),
                                          lineWidth: 0.5)
                    )
            }
            if let img = ProviderLogo.image(for: provider) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(padding)
            } else {
                Image(systemName: provider.fallbackSymbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(provider.accentColor)
            }
        }
        .frame(width: size + padding * 2,
               height: size + padding * 2)
    }
}

// One conversational turn — provider-agnostic role enum.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    let role: Role
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
}

// MARK: - HTTP client

enum AIClientError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case missingKey
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decoding(let msg):       return "Failed to decode response: \(msg)"
        case .missingKey:              return "API key missing"
        case .empty:                   return "Empty response from provider"
        }
    }
}

struct AIClient {
    let provider: AIProvider
    let apiKey: String
    let model: String

    func send(system: String, history: [ChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw AIClientError.missingKey }
        switch provider {
        case .openAI, .xAI: return try await sendOpenAICompatible(system: system, history: history)
        case .anthropic:    return try await sendAnthropic(system: system, history: history)
        case .gemini:       return try await sendGemini(system: system, history: history)
        }
    }

    // MARK: OpenAI / xAI (xAI is OpenAI-compatible)

    private func sendOpenAICompatible(system: String, history: [ChatMessage]) async throws -> String {
        let url: URL = {
            switch provider {
            case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
            case .xAI:    return URL(string: "https://api.x.ai/v1/chat/completions")!
            default:      fatalError()
            }
        }()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: String]] = [["role": "system", "content": system]]
        for m in history {
            let role: String
            switch m.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            }
            messages.append(["role": role, "content": m.content])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.4
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response: response, data: data)

        struct Resp: Decodable {
            struct Choice: Decodable { let message: Msg }
            struct Msg: Decodable { let content: String? }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIClientError.empty
        }
        return text
    }

    // MARK: Anthropic

    private func sendAnthropic(system: String, history: [ChatMessage]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: Any]] = []
        for m in history {
            let role: String
            switch m.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            }
            messages.append(["role": role, "content": m.content])
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response: response, data: data)

        struct Resp: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIClientError.empty }
        return text
    }

    // MARK: Gemini

    private func sendGemini(system: String, history: [ChatMessage]) async throws -> String {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else { throw AIClientError.missingKey }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var contents: [[String: Any]] = []
        for m in history {
            let role: String
            switch m.role {
            case .user: role = "user"
            case .assistant: role = "model"
            case .system: continue
            }
            contents.append([
                "role": role,
                "parts": [["text": m.content]]
            ])
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.4,
                "maxOutputTokens": 4096
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response: response, data: data)

        struct Resp: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Content: Decodable { let parts: [Part]? }
            struct Part: Decodable { let text: String? }
            let candidates: [Candidate]?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .compactMap { $0.text }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIClientError.empty }
        return text
    }

    // MARK: Common

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw AIClientError.http(http.statusCode, body.prefix(500).description)
        }
    }
}
