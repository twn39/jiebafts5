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

// MARK: - Latin-1 base folding lookup table
private let latin1BaseTable: [UInt8] = [
    // 0x80 to 0x8F (À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï)
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0, 0x43, 0x45, 0x45, 0x45, 0x45, 0x49, 0x49, 0x49, 0x49,
    // 0x90 to 0x9F (Ð Ñ Ò Ó Ô Õ Ö × Ø Ù Ú Û Ü Ý Þ ß)
    0x44, 0x4E, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0, 0x4F, 0x55, 0x55, 0x55, 0x55, 0x59, 0, 0,
    // 0xA0 to 0xAF (à á â ã ä å æ ç è é ê ë ì í î ï)
    0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0, 0x63, 0x65, 0x65, 0x65, 0x65, 0x69, 0x69, 0x69, 0x69,
    // 0xB0 to 0xBF (ð ñ ò ó ô õ ö ÷ ø ù ú û ü ý þ ÿ)
    0x64, 0x6E, 0x6F, 0x6F, 0x6F, 0x6F, 0x6F, 0, 0x6F, 0x75, 0x75, 0x75, 0x75, 0x79, 0, 0x79
]

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
            if let baseAddress = buf.baseAddress {
                if let stopwordSet, stopwordSet.contains(baseAddress, count: wordLen) {
                    return SQLITE_OK
                }
                let rc = callback(context, flags, baseAddress, CInt(wordLen), CInt(byteStart), CInt(byteEnd))
                if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
                return rc
            }
            return SQLITE_OK
        }
    }

    // Path 3: Non-ASCII (full-width alphanumeric, diacritics, CJK, etc.)
    // Attempt stack-allocated fast path for full-width letters/digits and Latin-1 accented characters.
    let fastPathResult: Int32? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: wordLen) { buf in
        var writeIdx = 0
        var readIdx = 0
        var requiresSlowPath = false

        while readIdx < wordLen {
            let b = UInt8(bitPattern: tokenPtr[readIdx])
            if b < 0x80 {
                // Standard ASCII
                let foldedByte: UInt8
                if options.caseFolding && b >= 0x41 && b <= 0x5A {
                    foldedByte = b | 0x20 // lowercase
                } else {
                    foldedByte = b
                }
                buf[writeIdx] = foldedByte
                writeIdx += 1
                readIdx += 1
            } else if b == 0xC3 && readIdx + 1 < wordLen {
                // Latin-1 prefix
                let b2 = UInt8(bitPattern: tokenPtr[readIdx + 1])
                if b2 >= 0x80 && b2 <= 0xBF {
                    let baseChar = latin1BaseTable[Int(b2 - 0x80)]
                    if baseChar != 0 {
                        let foldedByte: UInt8
                        if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                            foldedByte = baseChar | 0x20 // lowercase
                        } else {
                            foldedByte = baseChar
                        }
                        buf[writeIdx] = foldedByte
                        writeIdx += 1
                        readIdx += 2
                        continue
                    }
                }
                requiresSlowPath = true
                break
            } else if b == 0xEF && readIdx + 2 < wordLen {
                // Potential Full-width prefix
                let b2 = UInt8(bitPattern: tokenPtr[readIdx + 1])
                let b3 = UInt8(bitPattern: tokenPtr[readIdx + 2])
                if b2 == 0xBC && b3 >= 0x81 && b3 <= 0xBF {
                    // Fullwidth U+FF01 to U+FF3F -> ASCII U+0021 to U+005F
                    let baseChar = b3 - 0x60
                    let foldedByte: UInt8
                    if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                        foldedByte = baseChar | 0x20
                    } else {
                        foldedByte = baseChar
                    }
                    buf[writeIdx] = foldedByte
                    writeIdx += 1
                    readIdx += 3
                    continue
                } else if b2 == 0xBD && b3 >= 0x80 && b3 <= 0x9E {
                    // Fullwidth U+FF40 to U+FF5E -> ASCII U+0060 to U+007E
                    let baseChar = b3 - 0x20
                    let foldedByte: UInt8
                    if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                        foldedByte = baseChar | 0x20
                    } else {
                        foldedByte = baseChar
                    }
                    buf[writeIdx] = foldedByte
                    writeIdx += 1
                    readIdx += 3
                    continue
                }
                requiresSlowPath = true
                break
            } else {
                // Other non-ASCII UTF-8 sequences (e.g., CJK characters, emojis, Cyrillic, Greek)
                requiresSlowPath = true
                break
            }
        }

        if requiresSlowPath {
            return nil
        }

        // Fast path succeeded!
        let finalLen = writeIdx

        // Skip tokens consisting entirely of non-alphanumeric ASCII (punctuation/symbols).
        var hasAlphanumeric = false
        for i in 0..<finalLen {
            let b = buf[i]
            let isAlphanum = (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
            if isAlphanum {
                hasAlphanumeric = true
                break
            }
        }
        if !hasAlphanumeric {
            return SQLITE_OK
        }

        if let baseAddress = buf.baseAddress {
            if let stopwordSet, stopwordSet.contains(baseAddress, count: finalLen) {
                return SQLITE_OK
            }

            // Emit token directly.
            let rc = baseAddress.withMemoryRebound(to: CChar.self, capacity: finalLen) { cStr in
                callback(context, flags, cStr, CInt(finalLen), CInt(byteStart), CInt(byteEnd))
            }
            if rc != SQLITE_OK { bridgePtr.pointee.errorCode = rc }
            return rc
        }
        return SQLITE_OK
    }

    if let result = fastPathResult {
        return result
    }

    // Path 3 Slow Fallback: String decoding and normalisation folding (Requires heap allocations)
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
    if options.caseFolding { compareOptions.insert(.caseInsensitive) }

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
