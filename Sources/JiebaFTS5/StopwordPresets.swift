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
///
/// Chinese lists are intentionally high-frequency function words for FTS noise reduction,
/// not a full NLP stopword corpus. Extend via custom `stopwords:` when needed.
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

    /// Default Chinese stopwords (common function words for FTS noise reduction).
    public static let chinese: Set<String> = [
        // Classic high-frequency particles / pronouns
        "的", "了", "和", "是", "在", "我", "有", "这", "个", "他", "们", "就", "人", "都", "一", "而",
        "及", "与", "也", "着", "它", "之", "为", "以", "所", "于", "上", "下", "那",
        // Demonstratives / quantifiers / copula-adjacent
        "你", "她", "我们", "你们", "他们", "她们", "它们", "自己", "什么", "怎么", "怎样", "为何",
        "这个", "那个", "这些", "那些", "这里", "那里", "这么", "那么", "这样", "那样",
        "一种", "一些", "有的", "每个", "任何", "其他", "其它", "某", "某个", "某些",
        // Auxiliaries / aspect / mood
        "会", "能", "可以", "可", "要", "应", "应该", "得", "到", "过", "来", "去", "出", "回",
        "被", "把", "让", "给", "对", "向", "从", "比", "跟", "同", "并", "且", "或", "或者",
        "而且", "但是", "但", "不过", "然而", "因此", "所以", "因为", "如果", "若", "虽", "虽然",
        "然后", "接着", "于是", "此外", "另外", "同时", "其中",
        // Structural / filler
        "吗", "呢", "吧", "啊", "呀", "嘛", "啦", "哇", "哦", "嗯",
        "很", "非常", "更", "最", "较", "挺", "太", "真", "已", "已经", "曾", "曾经", "正", "正在",
        "还", "又", "再", "也是", "就是", "只是", "只有", "只要", "不仅", "不但",
        "没有", "没", "无", "非", "不", "不是", "不会", "不能", "不要",
        "请", "看", "说", "做", "让我们",
        // Time / place light words often noisy in FTS
        "年", "月", "日", "时", "分", "秒", "今", "今天", "昨天", "明天", "现在", "目前", "以前", "以后",
        "中", "内", "外", "前", "后", "左", "右", "里", "间", "等", "等等",
        // Numbers often stripped as stop-noise in full-text (optional; keep short digits only)
        "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万",
        // Common English-adjacent loan fillers used in CN text
        "啊啊", "呵呵", "哈哈"
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
