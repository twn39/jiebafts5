// JiebaTokenizer.swift
// JiebaFTS5
//
// FTS5 custom tokenizer backed by cppjieba.
//
// ## Token emission strategy
//
// ### Document mode (FTS5_TOKENIZE_DOCUMENT)
//
// Uses CutForSearch which emits both MixSeg words and shorter sub-words
// (2- and 3-character compounds present in the dictionary).
//
// Tokens are sorted by byte offset; within the same start offset the longest
// token occupies a **new** FTS5 position while shorter tokens are COLOCATED:
//
//   "清华大学" → CutForSearch output (raw order):
//     ["清华"@0, "华大"@3, "大学"@6, "清华大学"@0]   ← long word emitted last
//
//   After index sort (offset ↑, length ↓ within group):
//     pos 0 → "清华大学"  (flags=0, new position)
//     pos 0 → "清华"      (flags=FTS5_TOKEN_COLOCATED)
//     pos 1 → "华大"      (flags=0)
//     pos 2 → "大学"      (flags=0)
//
//   Searching "清华大学" → ✅ pos 0 exact match
//   Searching "清华"     → ✅ pos 0 COLOCATED synonym
//   Searching "大学"     → ✅ pos 2 independent token
//
// ### Query mode (FTS5_TOKENIZE_QUERY / FTS5_TOKENIZE_PREFIX)
//
// Uses Cut (MixSeg only).  Emits **one token per position, no COLOCATED**.
// This follows SQLite FTS5 Method 3 (document-side synonyms only).  Emitting
// COLOCATED synonyms during query tokenization turns them into OR alternatives,
// producing false-positive matches.
//
//   "清华大学" → Cut: ["清华大学"]  → pos 0 (flags=0)
//
// ### FTS5_TOKENIZE_AUX
//
// Used by snippet() and highlight().  Treated identically to DOCUMENT mode
// so that snippet byte ranges correspond to indexed token positions.
//
// ## Zero-copy token emission
//
// SQLite passes its own text buffer (pText / nText) for the duration of the
// xTokenize call.  Since jieba's `token.offset` and `token.length` are exact
// byte positions within that buffer, we can pass `pText + offset` directly as
// `pToken` to the callback — skipping the strdup'd intermediate copy in the C
// layer entirely.
//
// Case folding requires a modified copy, so the zero-copy path is taken only
// when caseFolding is disabled **or** the token is already all-lowercase ASCII.
//
// ## Thread safety
//
// JiebaTokenizer is stateless after init (all fields are `let`).
// JiebaEngine.shared is read-only after its one-time static-let initialisation.
// SQLite calls xTokenize on whatever thread it chooses; no locking is needed.

import CJiebaWrapper
import GRDB
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif

// MARK: - JiebaTokenizer

/// GRDB FTS5 custom tokenizer backed by cppjieba.
///
/// **Quick start:**
/// ```swift
/// // 1. Register
/// var config = Configuration()
/// config.addJiebaTokenizer()
/// let dbPool = try DatabasePool(path: path, configuration: config)
///
/// // 2. Create FTS5 virtual table
/// try dbPool.write { db in
///     try db.create(virtualTable: "docs", using: FTS5()) { t in
///         t.tokenizer = .jieba()
///         t.column("title")
///         t.column("body")
///     }
/// }
///
/// // 3. Search
/// let pattern = FTS5Pattern(matchingPhrase: query)
/// let results = try Document.matching(pattern).fetchAll(db)
/// ```
public final class JiebaTokenizer: FTS5CustomTokenizer {

    // MARK: FTS5CustomTokenizer

    public static let name = "jieba"

    // MARK: State (all immutable after init)

    /// Shared engine — heavyweight, loaded once for the process lifetime.
    private let engine: JiebaEngine

    /// Per-instance configuration — lightweight, decoded from FTS5 arguments.
    private let options: JiebaTokenizerOptions

    // MARK: Init

    /// Called by GRDB once per database connection when the FTS5 virtual table
    /// is first opened.  `arguments` contains the tokenizer name at index 0
    /// followed by any custom option strings.
    public required init(db: Database, arguments: [String]) throws {
        engine  = JiebaEngine.shared   // triggers one-time lazy init if needed
        options = JiebaTokenizerOptions(arguments: arguments)
    }

    // MARK: Convenience factory

    /// Returns an `FTS5TokenizerDescriptor` for use in `t.tokenizer = ...`.
    public static func tokenizerDescriptor(
        options: JiebaTokenizerOptions = JiebaTokenizerOptions()
    ) -> FTS5TokenizerDescriptor {
        tokenizerDescriptor(arguments: options.arguments)
    }

    // MARK: Core tokenization

    public func tokenize(
        context: UnsafeMutableRawPointer?,
        tokenization: FTS5Tokenization,
        pText: UnsafePointer<CChar>?,
        nText: CInt,
        tokenCallback: @escaping FTS5TokenCallback
    ) -> CInt {
        guard let pText, nText > 0 else { return SQLITE_OK }

        // Build a Swift String for cppjieba (std::string requires a copy).
        // We keep pText as the authoritative byte source for zero-copy emission.
        guard let text = String(
            bytes: UnsafeRawBufferPointer(start: pText, count: Int(nText)),
            encoding: .utf8
        ), !text.isEmpty else { return SQLITE_OK }

        // FTS5_TOKENIZE_QUERY | FTS5_TOKENIZE_PREFIX → query mode (no COLOCATED).
        // FTS5_TOKENIZE_DOCUMENT | FTS5_TOKENIZE_AUX  → document mode (COLOCATED).
        let isQuery = tokenization.contains(.query)

        return isQuery
            ? tokenizeQuery(text: text, pTextBase: pText,
                            callback: tokenCallback, context: context)
            : tokenizeDocument(text: text, pTextBase: pText,
                               callback: tokenCallback, context: context)
    }

    // MARK: Document tokenization

    /// Tokenizes with CutForSearch.
    ///
    /// Uses an index sort (sorts `Int` indices rather than `JiebaToken` structs)
    /// to group tokens by start offset and identify COLOCATED synonyms.
    /// cppjieba output is nearly sorted (sub-words precede their parent word),
    /// so the sort degrades to O(n) on the common case.
    private func tokenizeDocument(
        text: String,
        pTextBase: UnsafePointer<CChar>,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let list = engine.cutForSearch(text)
        defer { jieba_token_list_free(list) }
        guard list.count > 0, let tokens = list.tokens else { return SQLITE_OK }

        // Build and sort an index array.  Sorting Int (8 B) is cheaper than
        // sorting JiebaToken structs (~24 B).  ContiguousArray uses a single
        // heap allocation vs Array's (potentially) two.
        var indices = ContiguousArray<Int>(0..<list.count)
        indices.sort { l, r in
            let lhs = tokens[l], rhs = tokens[r]
            // Primary: ascending offset.  Secondary: descending length so the
            // longest (canonical) token comes first within the same offset group.
            return lhs.offset != rhs.offset
                ? lhs.offset  < rhs.offset
                : lhs.length  > rhs.length
        }

        var prevOffset: UInt32 = .max

        for idx in indices {
            let token    = tokens[idx]
            let byteStart = Int(token.offset)
            let byteEnd   = byteStart + Int(token.length)
            let isColocated = token.offset == prevOffset
            let flags: CInt = isColocated ? FTS5_TOKEN_COLOCATED : 0

            let emission = TokenEmissionContext(
                token: token,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: flags,
                pTextBase: pTextBase)
            let rc = emitToken(ctx: emission, callback: callback, context: context)
            guard rc == SQLITE_OK else { return rc }

            if !isColocated { prevOffset = token.offset }
        }
        return SQLITE_OK
    }

    // MARK: Query tokenization

    /// Tokenizes with Cut (MixSeg only).
    ///
    /// No COLOCATED tokens are emitted, following FTS5 Method 3.  Emitting
    /// COLOCATED synonyms in query mode turns them into OR alternatives,
    /// producing false-positive matches.
    private func tokenizeQuery(
        text: String,
        pTextBase: UnsafePointer<CChar>,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let list = engine.cut(text)
        defer { jieba_token_list_free(list) }
        guard list.count > 0, let tokens = list.tokens else { return SQLITE_OK }

        for i in 0..<list.count {
            let token     = tokens[i]
            let byteStart = Int(token.offset)
            let byteEnd   = byteStart + Int(token.length)

            let emission = TokenEmissionContext(
                token: token,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: 0,            // always a new position; no synonyms in query mode
                pTextBase: pTextBase)
            let rc = emitToken(ctx: emission, callback: callback, context: context)
            guard rc == SQLITE_OK else { return rc }
        }
        return SQLITE_OK
    }

    // MARK: Token emission

    /// Bundles the per-token parameters that do not change between the
    /// zero-copy and case-folding emission paths.
    private struct TokenEmissionContext {
        let token: JiebaToken
        let byteStart: Int
        let byteEnd: Int
        let flags: CInt
        let pTextBase: UnsafePointer<CChar>
    }

    /// Emits a single token to the FTS5 callback.
    ///
    /// ## Zero-copy path
    ///
    /// When case folding is disabled **or** the token is already all-lowercase
    /// ASCII, `pTextBase + byteStart` is passed directly as `pToken` — no copy.
    /// SQLite guarantees the buffer remains valid for the duration of xTokenize.
    ///
    /// ## Case folding paths
    ///
    /// - All-lowercase ASCII → zero-copy direct pass.
    /// - Contains uppercase ASCII → fold into a temporary **stack** buffer
    ///   (`withUnsafeTemporaryAllocation`), no heap allocation.
    /// - Non-ASCII (full-width letters, etc.) → `lowercased()` + `withCString`,
    ///   one heap allocation per token (unavoidable for correct Unicode folding).
    @inline(__always)
    private func emitToken(
        ctx: TokenEmissionContext,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let token     = ctx.token
        let byteStart = ctx.byteStart
        let byteEnd   = ctx.byteEnd
        let flags     = ctx.flags
        let pTextBase = ctx.pTextBase
        let wordLen = Int(token.length)

        // Zero-copy fast-exit: caseFolding disabled → use pTextBase slice.
        // pTextBase + byteStart points into SQLite's own buffer, valid until
        // xTokenize returns.
        if !options.caseFolding {
            return callback(context, flags,
                            pTextBase.advanced(by: byteStart), CInt(wordLen),
                            CInt(byteStart), CInt(byteEnd))
        }

        // Case folding is enabled.  Inspect the token's bytes to choose a path.
        // We use the strdup'd C string from jieba (token.word) as the byte source
        // for inspection and (potentially) folding, since pTextBase may not be
        // NUL-terminated at the token boundary.
        guard let wordPtr = token.word else { return SQLITE_OK }

        var hasUpper = false
        var isAscii  = true
        for i in 0..<wordLen {
            let b = UInt8(bitPattern: wordPtr[i])
            if b >= 0x80 { isAscii = false; break }
            if b >= 0x41 && b <= 0x5A { hasUpper = true }
        }

        if isAscii && !hasUpper {
            // All-lowercase ASCII: use pTextBase slice (zero-copy).
            return callback(context, flags,
                            pTextBase.advanced(by: byteStart), CInt(wordLen),
                            CInt(byteStart), CInt(byteEnd))
        }

        if isAscii {
            // Contains uppercase ASCII: fold into a stack-allocated temporary buffer.
            // withUnsafeTemporaryAllocation does not heap-allocate for small sizes.
            return withUnsafeTemporaryAllocation(
                of: CChar.self, capacity: wordLen
            ) { buf in
                for i in 0..<wordLen {
                    let b = UInt8(bitPattern: wordPtr[i])
                    buf[i] = CChar(bitPattern: (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b)
                }
                return callback(context, flags,
                                buf.baseAddress, CInt(wordLen),
                                CInt(byteStart), CInt(byteEnd))
            }
        }

        // Non-ASCII (e.g., full-width letters Ａ-Ｚ): Unicode-aware lowercasing.
        // Requires one heap allocation per token — unavoidable for correct folding.
        let raw   = String(cString: wordPtr)
        let lower = raw.lowercased()
        return lower.withCString { lowerPtr in
            callback(context, flags,
                     lowerPtr, CInt(lower.utf8.count),
                     CInt(byteStart), CInt(byteEnd))
        }
    }
}
