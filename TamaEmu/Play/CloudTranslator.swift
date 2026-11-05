import CoreGraphics
import Foundation
import UIKit

/// Bring-your-own-key cloud translation. Detects which provider a pasted
/// key belongs to from its own prefix — Gemini keys start "AIza",
/// Anthropic keys "sk-ant-", OpenAI keys "sk-" — so Settings can offer one
/// plain "paste your AI API key" field instead of a provider picker. The
/// key is only ever sent to that one provider's own API, straight from
/// this device.
enum CloudProvider {
    case gemini, openAI, anthropic

    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// Anthropic ("sk-ant-...") and OpenAI ("sk-...", checked after the
    /// more specific Anthropic prefix) have had stable key formats for
    /// years, so those two are matched positively. Google's hasn't been
    /// stable — their own docs describe an API key format change as
    /// recent as May 2026 — so rather than guess at (and risk rejecting)
    /// whatever the current one looks like, anything that isn't
    /// recognizably OpenAI or Anthropic defaults to Gemini.
    static func detect(fromKey key: String) -> CloudProvider? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sk-ant-") { return .anthropic }
        if trimmed.hasPrefix("sk-") { return .openAI }
        return .gemini
    }
}

enum CloudTranslator {
    static func translate(_ cgImage: CGImage, apiKey: String) async -> String? {
        guard let provider = CloudProvider.detect(fromKey: apiKey) else { return nil }
        guard let upscaled = ScreenImagePrep.textAreaUpscaled(cgImage) else { return nil }
        switch provider {
        case .gemini: return await translateWithGemini(upscaled, apiKey: apiKey)
        case .openAI: return await translateWithOpenAI(upscaled, apiKey: apiKey)
        case .anthropic: return await translateWithAnthropic(upscaled, apiKey: apiKey)
        }
    }

    private static let promptText = """
    This is a cropped close-up of the text display area, in the middle of \
    a Tamagotchi virtual pet toy's tiny LCD screen — the decorative \
    stat-icon strips above and below it have already been cropped out. It \
    shows short Japanese UI text — a stat readout, a menu, a room name, a \
    dialog prompt, or similar. Reply with ONLY the English translation of \
    exactly what's visible, as a single line — no transcription, no \
    labels, no explanation, and no extra items that aren't actually shown. \
    If several separate pieces of text are shown (a label and a value, \
    several menu items), join them with ", ". A character or pet name \
    should be transliterated to its standard spelling, not translated \
    word-for-word. If nothing is legible, reply with an empty string.
    """

    // MARK: Gemini

    private static func translateWithGemini(_ cgImage: CGImage, apiKey: String) async -> String? {
        guard let base64 = pngBase64(cgImage) else { return nil }
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": promptText],
                    ["inlineData": ["mimeType": "image/png", "data": base64]],
                ],
            ]],
            // Temperature 0, same reasoning as the on-device model: this
            // is a read-the-screen task with one right answer, not
            // creative writing.
            "generationConfig": ["temperature": 0],
        ]
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let result = await post(request, body: body) else { return nil }
        guard
            let candidates = result["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { return nil }
        return cleaned(text)
    }

    // MARK: OpenAI

    private static func translateWithOpenAI(_ cgImage: CGImage, apiKey: String) async -> String? {
        guard let base64 = pngBase64(cgImage) else { return nil }
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": promptText],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)", "detail": "high"]],
                ],
            ]],
        ]
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let result = await post(request, body: body) else { return nil }
        guard
            let choices = result["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { return nil }
        return cleaned(text)
    }

    // MARK: Anthropic

    private static func translateWithAnthropic(_ cgImage: CGImage, apiKey: String) async -> String? {
        guard let base64 = pngBase64(cgImage) else { return nil }
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 200,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": promptText],
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                ],
            ]],
        ]
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let result = await post(request, body: body) else { return nil }
        guard
            let content = result["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else { return nil }
        return cleaned(text)
    }

    // MARK: Shared

    private static func post(_ request: URLRequest, body: [String: Any]) async -> [String: Any]? {
        var request = request
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func pngBase64(_ cgImage: CGImage) -> String? {
        UIImage(cgImage: cgImage).pngData()?.base64EncodedString()
    }
}
