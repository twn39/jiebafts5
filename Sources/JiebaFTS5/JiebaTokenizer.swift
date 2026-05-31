// JiebaTokenizer.swift
// JiebaFTS5
//
// FTS5 custom tokenizer backed by cppjieba, fully optimized for zero-heap-allocation.

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
    
    // Skip tokens consisting entirely of non-alphanumeric ASCII characters.
    var isTokenAscii = true
    var hasAlphanumeric = false
    for i in 0..<wordLen {
        let b = UInt8(bitPattern: tokenPtr[i])
        if b >= 0x80 {
            isTokenAscii = false
            break
        }
        let isAlphanum = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        if isAlphanum {
            hasAlphanumeric = true
        }
    }
    if isTokenAscii && !hasAlphanumeric {
        return SQLITE_OK
    }
    
    // Detect if the token consists entirely of CJK Unified Ideographs (U+4E00 to U+9FFF).
    // In UTF-8, each CJK Unified Ideograph is represented as 3 bytes:
    // Byte 1: 0xE4 - 0xE9
    // Byte 2: 0x80 - 0xBF
    // Byte 3: 0x80 - 0xBF
    var isPureCJK = true
    var idx = 0
    while idx < wordLen {
        if idx + 2 < wordLen {
            let b1 = UInt8(bitPattern: tokenPtr[idx])
            let b2 = UInt8(bitPattern: tokenPtr[idx+1])
            let b3 = UInt8(bitPattern: tokenPtr[idx+2])
            
            let isCJKChar = (b1 >= 0xE4 && b1 <= 0xE9) && (b2 >= 0x80 && b2 <= 0xBF) && (b3 >= 0x80 && b3 <= 0xBF)
            if isCJKChar {
                idx += 3
                continue
            }
        }
        isPureCJK = false
        break
    }
    
    if isPureCJK {
        if let stopwordSet, stopwordSet.contains(tokenPtr, count: wordLen) {
            return SQLITE_OK
        }
        let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
        if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
        return rc
    }
    
    // Path 1: Zero-copy fast exit (no folding or normalisation required)
    if !options.caseFolding && !options.widthFolding && !options.diacriticFolding {
        if let stopwordSet, stopwordSet.contains(tokenPtr, count: wordLen) {
            return SQLITE_OK
        }
        let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
        if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
        return rc
    }
    
    // Path 2: Inspect byte properties for ASCII lowercasing optimization
    var hasUpper = false
    var isAscii = true
    for i in 0..<wordLen {
        let b = UInt8(bitPattern: tokenPtr[i])
        if b >= 0x80 { isAscii = false; break }
        if b >= 0x41 && b <= 0x5A { hasUpper = true }
    }
    
    if isAscii && !options.caseFolding {
        // caseFolding disabled, other folding irrelevant for ASCII -> zero-copy
        if let stopwordSet, stopwordSet.contains(tokenPtr, count: wordLen) {
            return SQLITE_OK
        }
        let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
        if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
        return rc
    }
    
    if isAscii {
        // All-lowercase ASCII -> zero-copy
        if !hasUpper {
            if let stopwordSet, stopwordSet.contains(tokenPtr, count: wordLen) {
                return SQLITE_OK
            }
            let rc = callback(context, flags, tokenPtr, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }
        
        // Contains uppercase ASCII -> Stack allocation case folding (Zero Heap Allocation)
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: wordLen) { buf in
            for i in 0..<wordLen {
                let b = UInt8(bitPattern: tokenPtr[i])
                buf[i] = CChar(bitPattern: (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b)
            }
            if let stopwordSet, stopwordSet.contains(buf.baseAddress!, count: wordLen) {
                return SQLITE_OK
            }
            let rc = callback(context, flags, buf.baseAddress, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }
    }
    
    // Path 3: Non-ASCII (full-width alphanumeric, diacritics, CJK, etc.)
    // String decoding and normalisation folding (Requires 1 heap allocation)
    let byteSlice = UnsafeRawBufferPointer(start: tokenPtr, count: wordLen)
    guard let raw = String(bytes: byteSlice, encoding: .utf8) else {
        return SQLITE_OK // Skip malformed tokens
    }
    
    // Skip tokens consisting entirely of non-alphanumeric CJK/Unicode characters (punctuation, symbols, spaces).
    let isIgnored = raw.allSatisfy { char in
        !char.isLetter && !char.isNumber
    }
    if isIgnored {
        return SQLITE_OK
    }
    
    var tokenStr = raw
    if options.widthFolding {
        tokenStr = tokenStr.precomposedStringWithCompatibilityMapping
    }
    
    var compareOptions: String.CompareOptions = []
    if options.diacriticFolding { compareOptions.insert(.diacriticInsensitive) }
    if options.caseFolding      { compareOptions.insert(.caseInsensitive) }
    
    if !compareOptions.isEmpty {
        tokenStr = tokenStr.folding(options: compareOptions, locale: nil)
    }
    
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

// MARK: - JiebaTokenizer

/// GRDB FTS5 custom tokenizer backed by cppjieba.
public final class JiebaTokenizer: FTS5CustomTokenizer {

    public static let name = "jieba"

    private let engine: JiebaEngine
    private let options: JiebaTokenizerOptions
    private let stopwordSet: StopwordSet?

    public required init(db: Database, arguments: [String]) throws {
        engine  = JiebaEngine.shared
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

        // Stack-allocated bridge
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
