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

// MARK: - C Callback Bridge

/// Thin, context-free C function pointer. Swift stack-allocated struct is bridged via the ctx pointer.
private let jiebaEmitCallback: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Int32) -> Int32 = { ctx, offset, length, isColocated in
    guard let ctx else { return SQLITE_ERROR }
    let bridgePtr = ctx.assumingMemoryBound(to: TokenizeBridge.self)

    let byteStart = Int(offset)
    let wordLen = Int(length)
    let byteEnd = byteStart + wordLen

    let options = bridgePtr.pointee.options
    let stopwordSet = bridgePtr.pointee.stopwordSet
    let pTextBase = bridgePtr.pointee.pTextBase
    let callback = bridgePtr.pointee.callback
    let context = bridgePtr.pointee.context

    let flags: CInt = (isColocated == 1) ? FTS5_TOKEN_COLOCATED : 0
    let tokenPtr = pTextBase.advanced(by: byteStart)

    return tokenPtr.withMemoryRebound(to: UInt8.self, capacity: wordLen) { u8Ptr -> Int32 in
        // Skip pure ASCII punctuation.
        if TokenNormalizer.isASCIINonAlphanumeric(u8Ptr, count: wordLen) {
            return SQLITE_OK
        }

        // Pure CJK Unified Ideographs: zero-copy.
        if TokenNormalizer.isPureCJKUnified(u8Ptr, count: wordLen) {
            if let stopwordSet, stopwordSet.contains(u8Ptr, count: wordLen) {
                return SQLITE_OK
            }
            let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }

        // No folding requested: zero-copy (after stopword check on raw bytes).
        if !options.caseFolding && !options.widthFolding && !options.diacriticFolding {
            if let stopwordSet, stopwordSet.contains(u8Ptr, count: wordLen) {
                return SQLITE_OK
            }
            let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }

        let asciiInfo = TokenNormalizer.asciiCaseInfo(u8Ptr, count: wordLen)

        if asciiInfo.isASCII && !options.caseFolding {
            if let stopwordSet, stopwordSet.contains(u8Ptr, count: wordLen) {
                return SQLITE_OK
            }
            let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }

        if asciiInfo.isASCII {
            if !asciiInfo.hasUpper {
                if let stopwordSet, stopwordSet.contains(u8Ptr, count: wordLen) {
                    return SQLITE_OK
                }
                let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
                if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
                return rc
            }

            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: wordLen) { buf in
                guard let base = buf.baseAddress else { return SQLITE_OK }
                TokenNormalizer.foldASCIIUpper(u8Ptr, count: wordLen, into: base)
                if let stopwordSet, stopwordSet.contains(base, count: wordLen) {
                    return SQLITE_OK
                }
                return base.withMemoryRebound(to: CChar.self, capacity: wordLen) { cStr in
                    let rc = callback(context, flags, cStr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
                    if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
                    return rc
                }
            }
        }

        // Non-ASCII: stack fast path (Latin-1 / fullwidth) then String slow path.
        let fastPathResult: Int32? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: wordLen) { buf in
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
                if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
                return rc
            }
        }

        if let result = fastPathResult {
            return result
        }

        // Slow path: Foundation folding (heap).
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
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }
    }
}

// MARK: - JiebaTokenizer

/// GRDB FTS5 custom tokenizer backed by cppjieba.
public final class JiebaTokenizer: FTS5CustomTokenizer {

    public static let name = "jieba"

    private let engine: JiebaEngine
    private let options: JiebaTokenizerOptions
    private let stopwordSet: StopwordSet?

    public required init(db: Database, arguments: [String]) throws {
        engine = JiebaEngine.shared
        options = JiebaTokenizerOptions(arguments: arguments)
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
}
