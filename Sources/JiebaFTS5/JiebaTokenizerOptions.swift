// JiebaTokenizerOptions.swift
// JiebaFTS5

import Foundation

// MARK: - JiebaTokenizerOptions

/// Configuration for `JiebaTokenizer`.
///
/// Default `.jieba()` / `JiebaTokenizerOptions()` does **not** enable stopwords.
/// Use `.recommended` or pass `StopwordPresets` for out-of-the-box filtering.
///
/// Contract: `docs/TOKENIZATION_PROFILE.md`.
public struct JiebaTokenizerOptions: Sendable, Equatable {

    /// When `true` (default), ASCII / Latin tokens are lowercased.
    public var caseFolding: Bool

    /// When `true` (default), full-width digits/letters are mapped to half-width.
    public var widthFolding: Bool

    /// When `true` (default), Latin diacritics are removed (e.g. café -> cafe).
    public var diacriticFolding: Bool

    /// Optional custom stopwords. If empty or nil, no stopword filtering is performed.
    public var stopwords: Set<String>?

    /// Optional named engine registered via `JiebaEngine.register(name:engine:)`.
    /// `nil` / empty / `"shared"` / `"default"` → process ``JiebaEngine/shared``.
    public var engineName: String?

    public init(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil,
        engineName: String? = nil
    ) {
        self.caseFolding = caseFolding
        self.widthFolding = widthFolding
        self.diacriticFolding = diacriticFolding
        self.stopwords = stopwords
        self.engineName = engineName
    }

    // MARK: Named profiles

    /// All folding on + Chinese/English common stopwords.
    public static var recommended: JiebaTokenizerOptions {
        JiebaTokenizerOptions(stopwords: StopwordPresets.cjkCommon)
    }

    /// All folding off, no stopwords (strict byte forms).
    public static var strictMatch: JiebaTokenizerOptions {
        JiebaTokenizerOptions(
            caseFolding: false,
            widthFolding: false,
            diacriticFolding: false,
            stopwords: nil
        )
    }

    // MARK: Built-in stopword aliases

    /// Default English stopwords (alias of `StopwordPresets.english`).
    public static var englishStopwords: Set<String> { StopwordPresets.english }

    /// Default Chinese stopwords (alias of `StopwordPresets.chinese`).
    public static var chineseStopwords: Set<String> { StopwordPresets.chinese }

    // MARK: FTS5 Arguments Encoding/Decoding

    var arguments: [String] {
        var args: [String] = []
        if !caseFolding { args.append("no_case_fold") }
        if !widthFolding { args.append("no_width_fold") }
        if !diacriticFolding { args.append("no_diacritic_fold") }
        if let stopwords, !stopwords.isEmpty {
            if let preset = StopwordPresets.presetID(matching: stopwords) {
                args.append("stopwords_preset")
                args.append(preset)
            } else {
                args.append("stopwords")
                args.append(stopwords.sorted().joined(separator: ","))
            }
        }
        if let engineName {
            let key = engineName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, key != "shared", key != "default" {
                args.append("engine")
                args.append(key)
            }
        }
        return args
    }

    init(arguments: [String]) {
        caseFolding = !arguments.contains("no_case_fold")
        widthFolding = !arguments.contains("no_width_fold")
        diacriticFolding = !arguments.contains("no_diacritic_fold")

        if let idx = arguments.firstIndex(of: "stopwords_preset"), idx + 1 < arguments.count,
           let preset = StopwordPresets.resolve(preset: arguments[idx + 1]) {
            stopwords = preset
        } else if let idx = arguments.firstIndex(of: "stopwords"), idx + 1 < arguments.count {
            let listStr = arguments[idx + 1]
            let words = listStr.split(separator: ",").map(String.init)
            stopwords = Set(words)
        } else {
            stopwords = nil
        }

        if let idx = arguments.firstIndex(of: "engine"), idx + 1 < arguments.count {
            let key = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            engineName = key.isEmpty ? nil : key
        } else {
            engineName = nil
        }
    }
}
