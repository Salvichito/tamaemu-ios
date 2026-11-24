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

/// Why a cloud translation didn't produce text, worded for the player —
/// shown in the same bubble a translation would be, so a failed tap never
/// just looks like nothing happened.
enum CloudTranslationError: Error {
    case timedOut, offline, rateLimited, busy, badKey, nothingLegible, unexpectedReply

    func message(for provider: CloudProvider) -> String {
        let name = provider.displayName
        switch self {
        case .timedOut: return "\(name) took too long. Try again."
        case .offline: return "No internet connection."
        case .rateLimited: return "Too many requests to \(name). Wait a moment and try again."
        case .busy: return "\(name) is busy right now. Try again."
        case .badKey: return "\(name) didn't accept your API key. Check it in Settings."
        case .nothingLegible: return "No text found on screen."
        case .unexpectedReply: return "Couldn't get a translation from \(name). Try again."
        }
    }
}

enum CloudTranslator {
    /// Text on success; on failure, a short player-facing reason.
    static func translate(_ cgImage: CGImage, apiKey: String) async -> Result<String, CloudTranslationError> {
        guard let provider = CloudProvider.detect(fromKey: apiKey) else { return .failure(.badKey) }
        guard let upscaled = ScreenImagePrep.textAreaUpscaled(cgImage),
              let base64 = pngBase64(upscaled)
        else { return .failure(.unexpectedReply) }
        let request: URLRequest
        let body: [String: Any]
        switch provider {
        case .gemini: (request, body) = geminiRequest(base64, apiKey: apiKey)
        case .openAI: (request, body) = openAIRequest(base64, apiKey: apiKey)
        case .anthropic: (request, body) = anthropicRequest(base64, apiKey: apiKey)
        }
        let json: [String: Any]
        switch await post(request, body: body) {
        case .success(let reply): json = reply
        case .failure(let error): return .failure(error)
        }
        let text: String?
        switch provider {
        case .gemini: text = geminiText(json)
        case .openAI: text = openAIText(json)
        case .anthropic: text = anthropicText(json)
        }
        guard let text else { return .failure(.unexpectedReply) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return trimmed.isEmpty ? .failure(.nothingLegible) : .success(trimmed)
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

    private static func geminiRequest(_ base64: String, apiKey: String) -> (URLRequest, [String: Any]) {
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": promptText],
                    ["inlineData": ["mimeType": "image/png", "data": base64]],
                ],
            ]],
            // Temperature 0, same reasoning as the on-device model: this
            // is a read-the-screen task with one right answer, not
            // creative writing. The output cap just stops a runaway reply
            // from holding the spinner — a real answer is a few words.
            // (Thinking is left at Flash-Lite's own default, which Google
            // documents as minimal.)
            "generationConfig": ["temperature": 0, "maxOutputTokens": 512],
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return (request, body)
    }

    private static func geminiText(_ json: [String: Any]) -> String? {
        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        // Skip any thought-summary parts; the answer is the plain text part.
        let texts = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }

    // MARK: OpenAI

    private static func openAIRequest(_ base64: String, apiKey: String) -> (URLRequest, [String: Any]) {
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
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return (request, body)
    }

    private static func openAIText(_ json: [String: Any]) -> String? {
        guard
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { return nil }
        return message["content"] as? String
    }

    // MARK: Anthropic

    private static func anthropicRequest(_ base64: String, apiKey: String) -> (URLRequest, [String: Any]) {
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
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return (request, body)
    }

    private static func anthropicText(_ json: [String: Any]) -> String? {
        guard let content = json["content"] as? [[String: Any]] else { return nil }
        return content.first?["text"] as? String
    }

    // MARK: Shared

    /// Hard ceiling for one attempt. The image is only tens of KB, so a
    /// healthy request finishes in a few seconds; anything still going
    /// at this point is stalled, not slow. Before this existed the app
    /// used iOS's default 60 s idle timeout with no overall limit, which
    /// is what made a stalled request look stuck forever.
    private static let attemptTimeout: TimeInterval = 15

    /// Own session rather than URLSession.shared: the per-request and
    /// whole-transfer limits both get capped, and an ephemeral config
    /// keeps the API key and replies out of any on-disk cache. It still
    /// reuses its connection between taps.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = attemptTimeout
        config.timeoutIntervalForResource = attemptTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// One automatic retry, only for "busy" / "rate-limited" replies —
    /// those come back fast and often clear within a second. A timeout
    /// isn't retried, so the worst case stays around one attempt's limit
    /// plus a quick failed one, not two full stalls back to back.
    private static func post(
        _ request: URLRequest, body: [String: Any]
    ) async -> Result<[String: Any], CloudTranslationError> {
        var request = request
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return .failure(.unexpectedReply) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = attemptTimeout

        var result = await attempt(request)
        if case .failure(let error) = result, error == .busy || error == .rateLimited {
            try? await Task.sleep(for: .seconds(1.5))
            result = await attempt(request)
        }
        return result
    }

    private static func attempt(_ request: URLRequest) async -> Result<[String: Any], CloudTranslationError> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .failure(.timedOut)
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failure(.offline)
            default: return .failure(.unexpectedReply)
            }
        } catch {
            return .failure(.unexpectedReply)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200..<300:
            return json.map { .success($0) } ?? .failure(.unexpectedReply)
        case 401, 403:
            return .failure(.badKey)
        case 400:
            // Gemini reports a bad key as a 400, not a 401.
            let body = String(data: data, encoding: .utf8) ?? ""
            return body.contains("API_KEY_INVALID") || body.contains("API key not valid")
                ? .failure(.badKey) : .failure(.unexpectedReply)
        case 429:
            return .failure(.rateLimited)
        case 500...599:
            // Includes Anthropic's 529 "overloaded".
            return .failure(.busy)
        default:
            return .failure(.unexpectedReply)
        }
    }

    private static func pngBase64(_ cgImage: CGImage) -> String? {
        UIImage(cgImage: cgImage).pngData()?.base64EncodedString()
    }
}
