// JiebaIntegration.swift
// JiebaFTS5

import GRDB

// MARK: - FTS5TokenizerDescriptor factory

extension FTS5TokenizerDescriptor {

    /// Jieba segmentation tokenizer descriptor.
    ///
    /// Matches the calling style of GRDB's built-in `.unicode61()` and
    /// `.porter()` descriptors:
    ///
    /// ```swift
    /// try db.create(virtualTable: "docs", using: FTS5()) { t in
    ///     t.tokenizer = .jieba()
    ///     t.column("title")
    ///     t.column("body")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - caseFolding: When `true` (default), ASCII / Latin tokens are lowercased.
    ///   - widthFolding: When `true` (default), full-width digits/letters are mapped to half-width.
    ///   - diacriticFolding: When `true` (default), Latin diacritics are folded (café -> cafe).
    ///   - stopwords: Optional custom stopwords list.
    /// - Returns: A descriptor suitable for `FTS5TableDefinition.tokenizer`.
    public static func jieba(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil
    ) -> FTS5TokenizerDescriptor {
        jieba(
            options: JiebaTokenizerOptions(
                caseFolding: caseFolding,
                widthFolding: widthFolding,
                diacriticFolding: diacriticFolding,
                stopwords: stopwords
            )
        )
    }

    /// Jieba tokenizer from a full options value (profiles, presets, custom).
    ///
    /// ```swift
    /// t.tokenizer = .jieba(options: .recommended)
    /// t.tokenizer = .jieba(options: .strictMatch)
    /// ```
    public static func jieba(options: JiebaTokenizerOptions) -> FTS5TokenizerDescriptor {
        JiebaTokenizer.tokenizerDescriptor(options: options)
    }
}

// MARK: - Configuration convenience

extension Configuration {

    /// Registers `JiebaTokenizer` with every database connection opened by
    /// this configuration.
    public mutating func addJiebaTokenizer() {
        prepareDatabase { db in
            db.add(tokenizer: JiebaTokenizer.self)
        }
    }
}
