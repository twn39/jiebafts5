// JiebaTokenizerOptions.swift
// JiebaFTS5

import Foundation

// MARK: - JiebaTokenizerOptions

/// Configuration for JiebaTokenizer.
///
/// Options are encoded as string arguments that FTS5 passes to the tokenizer
/// during virtual-table creation, and decoded again in `init(db:arguments:)`.
///
/// **Encoding contract** (mirrors cjkfts5's style for consistency):
/// ```
/// tokenizerDescriptor(arguments: ["jieba", "no_case_fold"])
/// ```
/// The first element is always the tokenizer name; options follow.
public struct JiebaTokenizerOptions: Sendable, Equatable {

    /// When `true` (default), non-CJK tokens (ASCII / Latin) are lowercased
    /// before being emitted as FTS5 tokens, enabling case-insensitive search.
    ///
    /// Set to `false` for case-sensitive behaviour on Latin text.
    public var caseFolding: Bool

    public init(caseFolding: Bool = true) {
        self.caseFolding = caseFolding
    }

    // MARK: FTS5 argument encoding

    /// Encodes options as FTS5 tokenizer arguments (excluding the name).
    var arguments: [String] {
        var args: [String] = []
        if !caseFolding { args.append("no_case_fold") }
        return args
    }

    /// Decodes options from the FTS5 argument array.
    ///
    /// GRDB passes the full `azArg[]` array — including `azArg[0]` which is
    /// the tokenizer name — so `arguments.contains(...)` is safe regardless
    /// of position.
    init(arguments: [String]) {
        caseFolding = !arguments.contains("no_case_fold")
    }
}
