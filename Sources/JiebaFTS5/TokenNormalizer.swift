// TokenNormalizer.swift
// JiebaFTS5
//
// Shared normalization for token emission and stopword table build (single source of truth).

import Foundation

/// Folding / classification helpers used by `JiebaTokenizer` emit path and `StopwordSet`.
enum TokenNormalizer {

    // MARK: - Latin-1 base folding (UTF-8 C3 80–BF → ASCII base)

    /// Maps second byte of `C3 xx` (xx in 0x80...0xBF) to ASCII base, or 0 if unmapped.
    static let latin1BaseTable: [UInt8] = [
        // 0x80 to 0x8F (À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï)
        0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0, 0x43, 0x45, 0x45, 0x45, 0x45, 0x49, 0x49, 0x49, 0x49,
        // 0x90 to 0x9F (Ð Ñ Ò Ó Ô Õ Ö × Ø Ù Ú Û Ü Ý Þ ß)
        0x44, 0x4E, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0, 0x4F, 0x55, 0x55, 0x55, 0x55, 0x59, 0, 0,
        // 0xA0 to 0xAF (à á â ã ä å æ ç è é ê ë ì í î ï)
        0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0, 0x63, 0x65, 0x65, 0x65, 0x65, 0x69, 0x69, 0x69, 0x69,
        // 0xB0 to 0xBF (ð ñ ò ó ô õ ö ÷ ø ù ú û ü ý þ ÿ)
        0x64, 0x6E, 0x6F, 0x6F, 0x6F, 0x6F, 0x6F, 0, 0x6F, 0x75, 0x75, 0x75, 0x75, 0x79, 0, 0x79
    ]

    // MARK: - String-level normalize (stopwords + slow emit path)

    /// Normalize a full word string. Order matches emit slow path:
    /// 1. optional NFKC (width)
    /// 2. optional diacritic / case folding via `String.folding`
    @inline(__always)
    static func normalizeWord(_ word: String, options: JiebaTokenizerOptions) -> String {
        var token = word
        if options.widthFolding {
            token = token.precomposedStringWithCompatibilityMapping
        }

        var compareOptions: String.CompareOptions = []
        if options.diacriticFolding {
            compareOptions.insert(.diacriticInsensitive)
        }
        if options.caseFolding {
            compareOptions.insert(.caseInsensitive)
        }
        if !compareOptions.isEmpty {
            token = token.folding(options: compareOptions, locale: nil)
        }
        return token
    }

    // MARK: - Byte classification

    /// Entire token is ASCII and contains no letter/digit (punctuation-only → drop).
    @inline(__always)
    static func isASCIINonAlphanumeric(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var hasAlphanumeric = false
        for i in 0..<count {
            let b = bytes[i]
            if b >= 0x80 { return false }
            let isAlphanum = (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
            if isAlphanum { hasAlphanumeric = true }
        }
        return !hasAlphanumeric
    }

    /// All codepoints are CJK Unified Ideographs U+4E00...U+9FFF (3-byte UTF-8 E4–E9).
    @inline(__always)
    static func isPureCJKUnified(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var idx = 0
        while idx < count {
            if idx + 2 < count {
                let b1 = bytes[idx]
                let b2 = bytes[idx + 1]
                let b3 = bytes[idx + 2]
                let isCJK = (b1 >= 0xE4 && b1 <= 0xE9)
                    && (b2 >= 0x80 && b2 <= 0xBF)
                    && (b3 >= 0x80 && b3 <= 0xBF)
                if isCJK {
                    idx += 3
                    continue
                }
            }
            return false
        }
        return count > 0
    }

    /// Scans ASCII token: `(isAllASCII, hasUppercase)`.
    @inline(__always)
    static func asciiCaseInfo(_ bytes: UnsafePointer<UInt8>, count: Int) -> (isASCII: Bool, hasUpper: Bool) {
        var hasUpper = false
        for i in 0..<count {
            let b = bytes[i]
            if b >= 0x80 { return (false, false) }
            if b >= 0x41 && b <= 0x5A { hasUpper = true }
        }
        return (true, hasUpper)
    }

    @inline(__always)
    static func isASCIIAlphanumericByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
    }

    /// Fold A–Z to a–z in place into `dest` (same length).
    @inline(__always)
    static func foldASCIIUpper(
        _ src: UnsafePointer<UInt8>,
        count: Int,
        into dest: UnsafeMutablePointer<UInt8>
    ) {
        for i in 0..<count {
            let b = src[i]
            dest[i] = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
        }
    }

    // MARK: - Fast fold (Latin-1 + fullwidth → ASCII)

    /// Result of stack fast-path fold over mixed Latin-1 / fullwidth / ASCII.
    enum FastFoldOutcome {
        /// Could not represent with byte-local rules; caller must use String slow path.
        case needsSlowPath
        /// Folded into buffer; `length` is written byte count. May be punctuation-only.
        case folded(length: Int)
    }

    /// Attempts to fold `src[0..<count]` into `dest` (capacity >= count).
    /// Handles ASCII, Latin-1 (C3 xx), and fullwidth FF01–FF5E when options request folding.
    @inline(__always)
    static func tryFastFold(
        _ src: UnsafePointer<UInt8>,
        count: Int,
        options: JiebaTokenizerOptions,
        into dest: UnsafeMutablePointer<UInt8>
    ) -> FastFoldOutcome {
        var writeIdx = 0
        var readIdx = 0

        while readIdx < count {
            let b = src[readIdx]
            if b < 0x80 {
                let folded: UInt8
                if options.caseFolding && b >= 0x41 && b <= 0x5A {
                    folded = b | 0x20
                } else {
                    folded = b
                }
                dest[writeIdx] = folded
                writeIdx += 1
                readIdx += 1
            } else if b == 0xC3 && readIdx + 1 < count {
                let b2 = src[readIdx + 1]
                if b2 >= 0x80 && b2 <= 0xBF {
                    let baseChar = latin1BaseTable[Int(b2 - 0x80)]
                    if baseChar != 0 {
                        let folded: UInt8
                        if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                            folded = baseChar | 0x20
                        } else {
                            folded = baseChar
                        }
                        dest[writeIdx] = folded
                        writeIdx += 1
                        readIdx += 2
                        continue
                    }
                }
                return .needsSlowPath
            } else if b == 0xEF && readIdx + 2 < count {
                let b2 = src[readIdx + 1]
                let b3 = src[readIdx + 2]
                if b2 == 0xBC && b3 >= 0x81 && b3 <= 0xBF {
                    let baseChar = b3 - 0x60
                    let folded: UInt8
                    if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                        folded = baseChar | 0x20
                    } else {
                        folded = baseChar
                    }
                    dest[writeIdx] = folded
                    writeIdx += 1
                    readIdx += 3
                    continue
                } else if b2 == 0xBD && b3 >= 0x80 && b3 <= 0x9E {
                    let baseChar = b3 - 0x20
                    let folded: UInt8
                    if options.caseFolding && baseChar >= 0x41 && baseChar <= 0x5A {
                        folded = baseChar | 0x20
                    } else {
                        folded = baseChar
                    }
                    dest[writeIdx] = folded
                    writeIdx += 1
                    readIdx += 3
                    continue
                }
                return .needsSlowPath
            } else {
                return .needsSlowPath
            }
        }
        return .folded(length: writeIdx)
    }
}
