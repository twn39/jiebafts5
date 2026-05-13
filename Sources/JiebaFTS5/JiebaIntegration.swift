// JiebaIntegration.swift
// JiebaFTS5
//
// Convenience GRDB integration APIs, mirroring the style of cjkfts5's
// CJKIntegration.swift so adopters can migrate between the two tokenizers
// with minimal code changes.

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
    /// - Parameter caseFolding: When `true` (default), ASCII / Latin tokens are
    ///   lowercased before indexing, enabling case-insensitive search.
    ///   Set to `false` for case-sensitive behaviour.
    /// - Returns: A descriptor suitable for `FTS5TableDefinition.tokenizer`.
    public static func jieba(
        caseFolding: Bool = true
    ) -> FTS5TokenizerDescriptor {
        JiebaTokenizer.tokenizerDescriptor(
            options: JiebaTokenizerOptions(caseFolding: caseFolding)
        )
    }
}

// MARK: - Configuration convenience

extension Configuration {

    /// Registers `JiebaTokenizer` with every database connection opened by
    /// this configuration.
    ///
    /// **Typical usage:**
    /// ```swift
    /// var config = Configuration()
    /// config.addJiebaTokenizer()
    /// let dbPool = try DatabasePool(path: path, configuration: config)
    /// ```
    ///
    /// Internally appends a `prepareDatabase` closure; calling this method
    /// multiple times is safe but unnecessary.
    ///
    /// - Note: Works identically for both `DatabaseQueue` and `DatabasePool`.
    ///   For a pool, GRDB executes `prepareDatabase` on every reader and writer
    ///   connection, ensuring all connections recognise the tokenizer.
    public mutating func addJiebaTokenizer() {
        prepareDatabase { db in
            db.add(tokenizer: JiebaTokenizer.self)
        }
    }
}
