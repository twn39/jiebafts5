// StopwordPresets.swift
// JiebaFTS5
//
// Built-in stopword presets (decoupled from folding switches).

import Foundation

/// Built-in stopword tables.
///
/// Default `.jieba()` does **not** enable any preset; pass explicitly, e.g.:
/// ```swift
/// t.tokenizer = .jieba(options: .recommended)
/// t.tokenizer = .jieba(stopwords: StopwordPresets.english)
/// ```
public enum StopwordPresets: Sendable {

    /// Default English stopwords.
    public static let english: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "aren't",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can't", "cannot", "could", "couldn't", "did", "didn't", "do", "does", "doesn't", "doing", "don't",
        "down", "during", "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't", "have",
        "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here", "here's", "hers", "herself",
        "him", "himself", "his", "how", "how's", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "into",
        "is", "isn't", "it", "it's", "its", "itself", "let's", "me", "more", "most", "mustn't", "my",
        "myself", "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "ought", "our",
        "ours", "ourselves", "out", "over", "own", "same", "shan't", "she", "she'd", "she'll", "she's",
        "should", "shouldn't", "so", "some", "such", "than", "that", "that's", "the", "their", "theirs",
        "them", "themselves", "then", "there", "there's", "these", "they", "they'd", "they'll", "they're",
        "they've", "this", "those", "through", "to", "too", "under", "until", "up", "very", "was", "wasn't",
        "we", "we'd", "we'll", "we're", "we've", "were", "weren't", "what", "what's", "when", "when's",
        "where", "where's", "which", "while", "who", "who's", "whom", "why", "why's", "with", "won't",
        "would", "wouldn't", "you", "you'd", "you'll", "you're", "you've", "your", "yours", "yourself",
        "yourselves"
    ]

    /// Default Chinese stopwords.
    public static let chinese: Set<String> = [
        "的", "了", "和", "是", "在", "我", "有", "这", "个", "他", "们", "就", "人", "都", "一", "而",
        "及", "与", "也", "着", "它", "之", "为", "以", "所", "于", "上", "下", "那"
    ]

    /// English ∪ Chinese common stopwords.
    public static var cjkCommon: Set<String> {
        english.union(chinese)
    }

    /// Resolve preset id to word set; unknown id → `nil`.
    ///
    /// Supported: `en`, `zh`, `en+zh` / `zh+en` / `cjk`.
    public static func resolve(preset id: String) -> Set<String>? {
        switch id.lowercased() {
        case "en", "english":
            return english
        case "zh", "chinese", "cn":
            return chinese
        case "en+zh", "zh+en", "cjk", "common":
            return cjkCommon
        default:
            return nil
        }
    }

    /// If `words` equals a built-in preset, return compact id for FTS5 args.
    public static func presetID(matching words: Set<String>) -> String? {
        if words == english { return "en" }
        if words == chinese { return "zh" }
        if words == cjkCommon { return "en+zh" }
        return nil
    }
}
