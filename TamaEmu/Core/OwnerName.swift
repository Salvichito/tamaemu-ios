import Foundation

/// Settings → "Your Name": writes the owner's name straight into a Tama's
/// memory, so it can be changed without the toy's letter-by-letter entry.
///
/// Found headless 2026-11-26 (same tools as the points hack): fresh setups
/// with names differing by one letter, compared byte by byte; each spot
/// confirmed by writing a name and seeing the toy use it (the color Tamas
/// greet their owner by name in a speech bubble; 4U/4U+ show it on
/// PROFILE; Tama-Go on Info → USER NAME), still there a minute later.
/// Letter tables were read off the toy's own screen, one code at a time.
///
/// Not supported: first-gen models (no owner name), Tamagotchi Friends
/// (its name never shows anywhere the app can reach; it's only sent in a
/// bump, which isn't emulated), Tomomix (has its own name fields).
enum OwnerName {
    enum Format {
        /// iD family, P's, Plus Color, Hexagontchi: 5 bytes, hiragana
        /// table, unused letters filled with 108 (blank).
        case kana5(offset: Int)
        /// 4U and 4U+: up to 8 letters, each stored as the pair (4, code),
        /// then (0, 0). Hiragana, katakana, A–Z, 0–9.
        case pairs8(offset: Int)
        /// Tama-Go: up to 8 bytes in work RAM, A–Z, 0–9, . ! ?, then 0.
        case tamaGo
    }

    static func format(for deviceID: String) -> Format? {
        switch deviceID {
        case "plus-color": .kana5(offset: 45841)
        case "plus-color-hexa": .kana5(offset: 45845)
        case "id", "id-melody": .kana5(offset: 45986)
        case "idl": .kana5(offset: 46085)  // also Princess Spacey
        case "ps": .kana5(offset: 5297)
        case "4u": .pairs8(offset: 5044)   // 4U+ (Japanese and English patch)
        case "4u-plain": .pairs8(offset: 5308)
        case "tamago": .tamaGo
        default: nil
        }
    }

    static func supports(_ deviceID: String) -> Bool { format(for: deviceID) != nil }

    static func maxLength(for deviceID: String) -> Int {
        if case .kana5 = format(for: deviceID) { 5 } else { 8 }
    }

    /// What the user can type, for the prompt.
    static func hint(for deviceID: String) -> String {
        switch format(for: deviceID) {
        case .kana5:
            "Up to 5 letters. This Tama only has hiragana: type in Japanese, or in English letters (\"sarubi\" becomes さるび)."
        case .pairs8:
            "Up to 8 letters: A–Z, numbers, hiragana or katakana."
        case .tamaGo:
            "Up to 8 letters: A–Z, numbers, and . ! ?"
        case nil:
            ""
        }
    }

    enum EncodeError: Error {
        case empty
        case tooLong(max: Int)
        case unsupported(String)

        var message: String {
            switch self {
            case .empty: "Type a name first."
            case .tooLong(let max): "That's too long: this Tama allows \(max) letters."
            case .unsupported(let chars):
                "This Tama can't show: " + chars.map { $0 == " " ? "spaces" : String($0) }.joined(separator: " ")
            }
        }
    }

    /// The bytes to write at the model's spot (the whole field, padding
    /// included).
    static func encode(_ text: String, deviceID: String) -> Result<[UInt8], EncodeError> {
        guard let format = format(for: deviceID) else { return .failure(.unsupported(text)) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        switch format {
        case .kana5:
            // Romaji and katakana both become hiragana (the only kana here).
            // No ヴ here: "v" is read as "b" (Salvi → さるび), and the old
            // kana ゐ/ゑ the transform can produce become い/え.
            let romaji = trimmed.lowercased().replacingOccurrences(of: "v", with: "b")
            var kana = romaji.applyingTransform(.latinToHiragana, reverse: false) ?? romaji
            kana = kana.replacingOccurrences(of: "ゐ", with: "い").replacingOccurrences(of: "ゑ", with: "え")
            kana = kana.applyingTransform(.hiraganaToKatakana, reverse: true) ?? kana
            return codes(for: kana, table: kanaTable, max: 5).map { codes in
                codes.map(UInt8.init) + Array(repeating: 108, count: 5 - codes.count)
            }
        case .pairs8:
            return codes(for: trimmed.uppercased(), table: fourUTable, max: 8).map { codes in
                var bytes: [UInt8] = []
                for code in codes { bytes += [4, UInt8(code)] }
                bytes += Array(repeating: 0, count: 18 - bytes.count)
                return bytes
            }
        case .tamaGo:
            return codes(for: trimmed.uppercased(), table: tamaGoTable, max: 8).map { codes in
                codes.map(UInt8.init) + Array(repeating: 0, count: 8 - codes.count)
            }
        }
    }

    private static func codes(for text: String, table: [Character: Int], max: Int) -> Result<[Int], EncodeError> {
        var result: [Int] = []
        var missing: [Character] = []
        for ch in text {
            if let code = table[ch] { result.append(code) } else if !missing.contains(ch) { missing.append(ch) }
        }
        if !missing.isEmpty { return .failure(.unsupported(String(missing))) }
        if result.count > max { return .failure(.tooLong(max: max)) }
        return .success(result)
    }

    // MARK: - Letter tables

    private static func table(_ runs: [(start: Int, chars: String)]) -> [Character: Int] {
        var t: [Character: Int] = [:]
        for run in runs {
            for (i, ch) in run.chars.enumerated() where t[ch] == nil { t[ch] = run.start + i }
        }
        return t
    }

    /// Shared by every color model, codes 1–107 (also the 4U's first 107).
    private static let kanaRuns: [(start: Int, chars: String)] = [
        (1, "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"),
        (47, "ぁぃぅぇぉっゃゅょ"),
        (56, "がぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽ"),
        (81, "ー〜…、。()「」.・!?&○×♥"),
        (99, "★"),
        (101, "♪"),
        // Common look-alikes typed on iPhone keyboards.
        (81, "-"), (82, "~"), (86, "（）"), (90, "．"), (92, "！？"), (94, "＆"), (97, "❤"),
    ]

    private static let kanaTable: [Character: Int] = table(kanaRuns + [(108, " 　")])

    private static let fourUTable: [Character: Int] = table(kanaRuns + [
        (108, " 　"),
        (109, "0123456789"),
        (119, "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"),
        (165, "ァィゥェォッャュョ"),
        (174, "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポヴ"),
        (224, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        (250, "%"), (252, "+"),
    ])

    private static let tamaGoTable: [Character: Int] = table([
        (1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        (27, "0123456789"),
        (37, ".!?"),
    ])
}
