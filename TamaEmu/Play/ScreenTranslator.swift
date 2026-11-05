import CoreGraphics
import FoundationModels

/// Reads the LCD's Japanese UI text directly from a screenshot and
/// translates it in a single on-device model call — no separate OCR step.
/// (The removed Vision-OCR overlay hit a real ceiling: its OCR model was
/// never trained on ~1990s–2000s bitmap pixel fonts. A vision-capable LLM
/// reasons over the image instead of character-matching against a font it
/// doesn't know, which is the whole bet this makes.)
@available(iOS 27.0, *)
enum ScreenTranslator {
    @Generable
    struct Result {
        // Asked for first and kept as its own field on purpose — writing
        // out what it actually sees gives the model a scratchpad to ground
        // the translation in, the same way "transcribe, then translate"
        // worked in the free-form-text version. An earlier version of this
        // prompt skipped straight to `translation` and that visibly hurt
        // accuracy, so this stays even though only `translation` reaches
        // the UI. (A separate earlier version also spelled out example
        // Japanese→English pairs in the instructions — that backfired
        // worse: on a real device the model echoed those examples back as
        // if they were on screen, e.g. translating a 2-character "ガム"
        // screen as "Meal, Snack, Lottery Draw, Renovate, ..., Gum". The
        // prompt below deliberately gives no concrete example answers for
        // it to crib from.)
        @Guide(description: "Exactly what text is visible on screen, transcribed character for character. Empty string if nothing is legible.")
        var transcription: String
        @Guide(description: "A natural English translation of the transcription, as a single line, and ONLY of the transcription — never add words, items, or examples that aren't part of it. If the screen shows several separate pieces of text (a label and a value, several menu items, etc.), join them with \", \" (comma, space) rather than running them together. A character or pet name should be transliterated to its standard romanized spelling, not translated word-for-word. Empty string if the transcription is empty.")
        var translation: String
    }

    /// `nil` covers both "nothing legible" and "the call failed" — both
    /// render the same way to the caller (no bubble), so there's no need
    /// to tell them apart here.
    static func translate(_ cgImage: CGImage) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        guard let upscaled = ScreenImagePrep.textAreaUpscaled(cgImage) else { return nil }
        do {
            let session = LanguageModelSession(model: model)
            let prompt = Prompt {
                """
                This is a cropped close-up of the text display area, in the \
                middle of a Tamagotchi virtual pet toy's tiny LCD screen — \
                the decorative stat-icon strips above and below it have \
                already been cropped out, so ignore anything that looks like \
                a stray icon fragment at the very top or bottom edge. It \
                shows short Japanese UI text — a stat readout, a menu, a \
                room name, a dialog prompt, or similar. First transcribe \
                exactly, and only, what's actually visible right now, then \
                translate just that. Do not mention or list any other menu \
                items, words, or examples that aren't actually shown — only \
                describe this one screen. The font is tiny — if a word isn't \
                clearly legible, leave it out rather than guessing; a \
                shorter, correct answer is much better than a complete but \
                invented one.
                """
                Attachment(upscaled).label("Tamagotchi LCD screen")
            }
            // Greedy, not the default sampling — this is a read-the-screen
            // task with one right answer, not creative writing, and the
            // default was visibly unstable: the same unchanged stat screen
            // read back differently call to call (e.g. "hunger" vs "body"
            // vs "stomach"). Greedy always picks the model's single most
            // likely token, which is deterministic and should also reduce
            // confident-sounding hallucinated words.
            let options = GenerationOptions(samplingMode: .greedy)
            let response = try await session.respond(to: prompt, generating: Result.self, options: options)
            let text = response.content.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
