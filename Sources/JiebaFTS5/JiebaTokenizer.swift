// JiebaTokenizer.swift
// JiebaFTS5
//
// FTS5 custom tokenizer backed by cppjieba, optimized for zero-heap-allocation hot paths.

import CJiebaWrapper
import GRDB
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif

// MARK: - TokenizeBridge

private struct TokenizeBridge {
    let options: JiebaTokenizerOptions
    let stopwordSet: StopwordSet?
    let pTextBase: UnsafePointer<CChar>
    let callback: FTS5TokenCallback
    let context: UnsafeMutableRawPointer?
    var errorCode: CInt
}

// MARK: - Emit Pipeline (named stages; order is a correctness contract)

/// Stages of the FTS5 emit path. Order must stay aligned with
/// `docs/TOKENIZATION_PROFILE.md` (stopword after fold; CJK zero-copy first).
private enum TokenEmitPipeline {

    /// Record FTS5 callback failure on the bridge and return the code.
    @inline(__always)
    static func finish(
        _ rc: Int32,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
        return rc
    }

    /// Zero-copy emit of the original byte span (after optional stopword check).
    @inline(__always)
    static func emitRawBytes(
        tokenPtr: UnsafePointer<CChar>,
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        if let stopwordSet, stopwordSet.contains(u8Ptr, count: wordLen) {
            return SQLITE_OK
        }
        let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
        return finish(rc, bridgePtr: bridgePtr)
    }

    /// Pure CJK Unified Ideographs (U+4E00…U+9FFF): zero-copy, no Latin folding.
    @inline(__always)
    static func emitPureCJK(
        tokenPtr: UnsafePointer<CChar>,
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        emitRawBytes(
            tokenPtr: tokenPtr,
            u8Ptr: u8Ptr,
            wordLen: wordLen,
            byteStart: byteStart,
            byteEnd: byteEnd,
            flags: flags,
            stopwordSet: stopwordSet,
            callback: callback,
            context: context,
            bridgePtr: bridgePtr
        )
    }

    /// All folding disabled: stopword on raw bytes, then zero-copy emit.
    @inline(__always)
    static func emitNoFold(
        tokenPtr: UnsafePointer<CChar>,
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        emitRawBytes(
            tokenPtr: tokenPtr,
            u8Ptr: u8Ptr,
            wordLen: wordLen,
            byteStart: byteStart,
            byteEnd: byteEnd,
            flags: flags,
            stopwordSet: stopwordSet,
            callback: callback,
            context: context,
            bridgePtr: bridgePtr
        )
    }

    /// Pure ASCII: zero-copy when no uppercase (or caseFolding off); else stack fold A–Z.
    @inline(__always)
    static func emitASCII(
        tokenPtr: UnsafePointer<CChar>,
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        hasUpper: Bool,
        caseFolding: Bool,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        if !caseFolding || !hasUpper {
            return emitRawBytes(
                tokenPtr: tokenPtr,
                u8Ptr: u8Ptr,
                wordLen: wordLen,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: flags,
                stopwordSet: stopwordSet,
                callback: callback,
                context: context,
                bridgePtr: bridgePtr
            )
        }

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: wordLen) { buf in
            guard let base = buf.baseAddress else { return SQLITE_OK }
            TokenNormalizer.foldASCIIUpper(u8Ptr, count: wordLen, into: base)
            if let stopwordSet, stopwordSet.contains(base, count: wordLen) {
                return SQLITE_OK
            }
            return base.withMemoryRebound(to: CChar.self, capacity: wordLen) { cStr in
                let rc = callback(context, flags, cStr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
                return finish(rc, bridgePtr: bridgePtr)
            }
        }
    }

    /// Latin-1 / fullwidth stack fold. Returns `nil` when caller must use String slow path.
    @inline(__always)
    static func emitFastFold(
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        options: JiebaTokenizerOptions,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: wordLen) { buf in
            guard let base = buf.baseAddress else { return SQLITE_OK as Int32? }
            switch TokenNormalizer.tryFastFold(u8Ptr, count: wordLen, options: options, into: base) {
            case .needsSlowPath:
                return nil
            case .folded(let finalLen):
                var hasAlphanumeric = false
                for i in 0..<finalLen {
                    if TokenNormalizer.isASCIIAlphanumericByte(base[i]) {
                        hasAlphanumeric = true
                        break
                    }
                }
                if !hasAlphanumeric {
                    return SQLITE_OK
                }
                if let stopwordSet, stopwordSet.contains(base, count: finalLen) {
                    return SQLITE_OK
                }
                let rc = base.withMemoryRebound(to: CChar.self, capacity: finalLen) { cStr in
                    callback(context, flags, cStr, CInt(finalLen), CInt(byteStart), CInt(byteEnd))
                }
                return finish(rc, bridgePtr: bridgePtr)
            }
        }
    }

    /// Foundation folding (heap). Used when fast fold cannot represent the token.
    @inline(__always)
    static func emitSlowString(
        u8Ptr: UnsafePointer<UInt8>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        options: JiebaTokenizerOptions,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        let byteSlice = UnsafeRawBufferPointer(start: u8Ptr, count: wordLen)
        guard let raw = String(bytes: byteSlice, encoding: .utf8) else {
            return SQLITE_OK
        }

        if raw.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
            return SQLITE_OK
        }

        let tokenStr = TokenNormalizer.normalizeWord(raw, options: options)

        if let stopwordSet {
            let isStop = tokenStr.utf8.withContiguousStorageIfAvailable { buf in
                stopwordSet.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
            } ?? false
            if isStop {
                return SQLITE_OK
            }
        }

        return tokenStr.withCString { cStr in
            let rc = callback(context, flags, cStr, CInt(tokenStr.utf8.count), CInt(byteStart), CInt(byteEnd))
            return finish(rc, bridgePtr: bridgePtr)
        }
    }

    /// Full emit for one jieba span. Preserves historical stage order.
    @inline(__always)
    static func emitToken(
        tokenPtr: UnsafePointer<CChar>,
        wordLen: Int,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        options: JiebaTokenizerOptions,
        stopwordSet: StopwordSet?,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?,
        bridgePtr: UnsafeMutablePointer<TokenizeBridge>
    ) -> Int32 {
        tokenPtr.withMemoryRebound(to: UInt8.self, capacity: wordLen) { u8Ptr -> Int32 in
            // Stage 0: skip pure ASCII punctuation.
            if TokenNormalizer.isASCIINonAlphanumeric(u8Ptr, count: wordLen) {
                return SQLITE_OK
            }

            // Stage 1: pure CJK Unified Ideographs — zero-copy.
            if TokenNormalizer.isPureCJKUnified(u8Ptr, count: wordLen) {
                return emitPureCJK(
                    tokenPtr: tokenPtr,
                    u8Ptr: u8Ptr,
                    wordLen: wordLen,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: flags,
                    stopwordSet: stopwordSet,
                    callback: callback,
                    context: context,
                    bridgePtr: bridgePtr
                )
            }

            // Stage 2: no folding requested — zero-copy after stopword on raw bytes.
            if !options.caseFolding && !options.widthFolding && !options.diacriticFolding {
                return emitNoFold(
                    tokenPtr: tokenPtr,
                    u8Ptr: u8Ptr,
                    wordLen: wordLen,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: flags,
                    stopwordSet: stopwordSet,
                    callback: callback,
                    context: context,
                    bridgePtr: bridgePtr
                )
            }

            let asciiInfo = TokenNormalizer.asciiCaseInfo(u8Ptr, count: wordLen)

            // Stage 3: pure ASCII (optional case fold on stack).
            if asciiInfo.isASCII {
                return emitASCII(
                    tokenPtr: tokenPtr,
                    u8Ptr: u8Ptr,
                    wordLen: wordLen,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: flags,
                    hasUpper: asciiInfo.hasUpper,
                    caseFolding: options.caseFolding,
                    stopwordSet: stopwordSet,
                    callback: callback,
                    context: context,
                    bridgePtr: bridgePtr
                )
            }

            // Stage 4: Latin-1 / fullwidth stack fast path.
            if let fast = emitFastFold(
                u8Ptr: u8Ptr,
                wordLen: wordLen,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: flags,
                options: options,
                stopwordSet: stopwordSet,
                callback: callback,
                context: context,
                bridgePtr: bridgePtr
            ) {
                return fast
            }

            // Stage 5: Foundation slow path (heap).
            return emitSlowString(
                u8Ptr: u8Ptr,
                wordLen: wordLen,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: flags,
                options: options,
                stopwordSet: stopwordSet,
                callback: callback,
                context: context,
                bridgePtr: bridgePtr
            )
        }
    }
}

// MARK: - C Callback Bridge

/// Thin, context-free C function pointer. Swift stack-allocated struct is bridged via the ctx pointer.
private let jiebaEmitCallback: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Int32) -> Int32 = { ctx, offset, length, isColocated in
    guard let ctx else { return SQLITE_ERROR }
    let bridgePtr = ctx.assumingMemoryBound(to: TokenizeBridge.self)

    let byteStart = Int(offset)
    let wordLen = Int(length)
    let byteEnd = byteStart + wordLen

    let flags: CInt = (isColocated == 1) ? FTS5_TOKEN_COLOCATED : 0
    let tokenPtr = bridgePtr.pointee.pTextBase.advanced(by: byteStart)

    return TokenEmitPipeline.emitToken(
        tokenPtr: tokenPtr,
        wordLen: wordLen,
        byteStart: byteStart,
        byteEnd: byteEnd,
        flags: flags,
        options: bridgePtr.pointee.options,
        stopwordSet: bridgePtr.pointee.stopwordSet,
        callback: bridgePtr.pointee.callback,
        context: bridgePtr.pointee.context,
        bridgePtr: bridgePtr
    )
}

// MARK: - Debug token info

/// One token as emitted by the same pipeline used for FTS5 indexing/query.
public struct JiebaSuggestedToken: Sendable, Equatable {
    /// Normalized token text (UTF-8), matching what FTS5 would store/match.
    public let text: String
    /// Byte offset into the original UTF-8 input.
    public let byteStart: Int
    /// Byte length in the original input (pre-normalization span).
    public let byteLength: Int
    /// `true` when FTS5 colocated (same start offset as a longer sibling token).
    public let isColocated: Bool

    public var byteEnd: Int { byteStart + byteLength }
}

/// Heap box for C-callback collection (`FTS5TokenCallback` cannot capture context).
private final class SuggestedTokenBox: @unchecked Sendable {
    var items: [JiebaSuggestedToken] = []
}

/// Context-free collect callback; `context` is `Unmanaged<SuggestedTokenBox>`.
private let suggestTokensCollectCallback: FTS5TokenCallback = { ctx, flags, pToken, nToken, iStart, iEnd in
    guard let ctx else { return SQLITE_ERROR }
    let box = Unmanaged<SuggestedTokenBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let pToken, nToken > 0 else { return SQLITE_OK }
    let len = Int(nToken)
    let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(pToken), count: len)
    let tokenText = String(bytes: bytes, encoding: .utf8) ?? ""
    let colocated = (flags & FTS5_TOKEN_COLOCATED) != 0
    let start = Int(iStart)
    let end = Int(iEnd)
    box.items.append(
        JiebaSuggestedToken(
            text: tokenText,
            byteStart: start,
            byteLength: max(0, end - start),
            isColocated: colocated
        )
    )
    return SQLITE_OK
}

// MARK: - JiebaTokenizer

/// GRDB FTS5 custom tokenizer backed by cppjieba.
public final class JiebaTokenizer: FTS5CustomTokenizer {

    public static let name = "jieba"

    private let engine: JiebaEngine
    private let options: JiebaTokenizerOptions
    private let stopwordSet: StopwordSet?

    public required init(db: Database, arguments: [String]) throws {
        options = JiebaTokenizerOptions(arguments: arguments)
        engine = try JiebaEngine.resolve(name: options.engineName)
        if let stopwords = options.stopwords, !stopwords.isEmpty {
            stopwordSet = StopwordSet(stopwords: stopwords, options: options)
        } else {
            stopwordSet = nil
        }
    }

    /// Advanced / tests: bind a specific engine instance (defaults to shared in FTS5 path).
    ///
    /// Production FTS5 registration always uses `JiebaEngine.shared`. Prefer this initializer
    /// when exercising a standalone `JiebaEngine.make(...)` instance without mutating process globals.
    public init(engine: JiebaEngine, options: JiebaTokenizerOptions = JiebaTokenizerOptions()) {
        self.engine = engine
        self.options = options
        if let stopwords = options.stopwords, !stopwords.isEmpty {
            stopwordSet = StopwordSet(stopwords: stopwords, options: options)
        } else {
            stopwordSet = nil
        }
    }

    public static func tokenizerDescriptor(
        options: JiebaTokenizerOptions = JiebaTokenizerOptions()
    ) -> FTS5TokenizerDescriptor {
        tokenizerDescriptor(arguments: options.arguments)
    }

    public func tokenize(
        context: UnsafeMutableRawPointer?,
        tokenization: FTS5Tokenization,
        pText: UnsafePointer<CChar>?,
        nText: CInt,
        tokenCallback: @escaping FTS5TokenCallback
    ) -> CInt {
        guard let pText, nText > 0 else { return SQLITE_OK }

        let isQuery = tokenization.contains(.query)

        var bridge = TokenizeBridge(
            options: options,
            stopwordSet: stopwordSet,
            pTextBase: pText,
            callback: tokenCallback,
            context: context,
            errorCode: SQLITE_OK
        )

        let rc: Int32
        if isQuery {
            rc = withUnsafeMutablePointer(to: &bridge) { bridgePtr in
                engine.cut(pText, count: Int(nText), context: bridgePtr, callback: jiebaEmitCallback)
            }
        } else {
            rc = withUnsafeMutablePointer(to: &bridge) { bridgePtr in
                engine.cutForSearch(pText, count: Int(nText), context: bridgePtr, callback: jiebaEmitCallback)
            }
        }

        if rc != SQLITE_OK {
            return bridge.errorCode != SQLITE_OK ? bridge.errorCode : rc
        }
        return SQLITE_OK
    }

    // MARK: Debug / tooling

    /// Segment `text` with the same emit pipeline as FTS5 (folding + stopwords).
    ///
    /// - Parameter asQuery: `true` uses MixSeg (query mode); `false` uses QuerySeg (document/index mode).
    /// - Returns: Tokens in emit order, including colocated sub-tokens when in document mode.
    public func suggestTokens(for text: String, asQuery: Bool = false) -> [JiebaSuggestedToken] {
        guard !text.isEmpty else { return [] }

        let box = SuggestedTokenBox()
        box.items.reserveCapacity(max(8, text.utf8.count / 3))
        let boxOpaque = Unmanaged.passUnretained(box).toOpaque()

        text.withCString { cStr in
            let nText = CInt(text.utf8.count)
            var bridge = TokenizeBridge(
                options: options,
                stopwordSet: stopwordSet,
                pTextBase: cStr,
                callback: suggestTokensCollectCallback,
                context: boxOpaque,
                errorCode: SQLITE_OK
            )
            withUnsafeMutablePointer(to: &bridge) { bridgePtr in
                if asQuery {
                    _ = engine.cut(cStr, count: Int(nText), context: bridgePtr, callback: jiebaEmitCallback)
                } else {
                    _ = engine.cutForSearch(cStr, count: Int(nText), context: bridgePtr, callback: jiebaEmitCallback)
                }
            }
        }
        return box.items
    }

    /// Convenience: suggest tokens using the process-shared engine and given options.
    public static func suggestTokens(
        for text: String,
        options: JiebaTokenizerOptions = JiebaTokenizerOptions(),
        asQuery: Bool = false,
        engine: JiebaEngine = .shared
    ) -> [JiebaSuggestedToken] {
        JiebaTokenizer(engine: engine, options: options).suggestTokens(for: text, asQuery: asQuery)
    }
}
