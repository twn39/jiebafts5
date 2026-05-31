// JiebaTokenizerOptions.swift
// JiebaFTS5

import Foundation

// MARK: - JiebaTokenizerOptions

/// Configuration for JiebaTokenizer.
public struct JiebaTokenizerOptions: Sendable, Equatable {

    /// When `true` (default), ASCII / Latin tokens are lowercased.
    public var caseFolding: Bool

    /// When `true` (default), full-width digits/letters are mapped to half-width.
    public var widthFolding: Bool

    /// When `true` (default), Latin diacritics are removed (e.g. café -> cafe).
    public var diacriticFolding: Bool

    /// Optional custom stopwords. If empty or nil, no stopword filtering is performed.
    public var stopwords: Set<String>?

    public init(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil
    ) {
        self.caseFolding = caseFolding
        self.widthFolding = widthFolding
        self.diacriticFolding = diacriticFolding
        self.stopwords = stopwords
    }

    // MARK: Default Stopword Lists

    /// Default English stopwords.
    public static let englishStopwords: Set<String> = [
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
    public static let chineseStopwords: Set<String> = [
        "的", "了", "和", "是", "在", "我", "有", "这", "个", "他", "们", "就", "人", "都", "一", "而",
        "及", "与", "也", "着", "它", "之", "为", "以", "所", "于", "上", "下", "那"
    ]

    // MARK: FTS5 Arguments Encoding/Decoding

    var arguments: [String] {
        var args: [String] = []
        if !caseFolding      { args.append("no_case_fold") }
        if !widthFolding     { args.append("no_width_fold") }
        if !diacriticFolding { args.append("no_diacritic_fold") }
        if let stopwords, !stopwords.isEmpty {
            args.append("stopwords")
            args.append(stopwords.sorted().joined(separator: ","))
        }
        return args
    }

    init(arguments: [String]) {
        caseFolding      = !arguments.contains("no_case_fold")
        widthFolding     = !arguments.contains("no_width_fold")
        diacriticFolding = !arguments.contains("no_diacritic_fold")
        
        if let idx = arguments.firstIndex(of: "stopwords"), idx + 1 < arguments.count {
            let listStr = arguments[idx + 1]
            let words = listStr.split(separator: ",").map(String.init)
            stopwords = Set(words)
        } else {
            stopwords = nil
        }
    }
}
