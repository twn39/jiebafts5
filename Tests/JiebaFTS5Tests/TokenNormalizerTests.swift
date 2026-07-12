// TokenNormalizerTests.swift
// Unit tests for TokenNormalizer (no SQLite required).

import XCTest
@testable import JiebaFTS5

final class TokenNormalizerTests: XCTestCase {

    func testNormalizeWordCaseFolding() {
        let opts = JiebaTokenizerOptions(caseFolding: true, widthFolding: false, diacriticFolding: false)
        XCTAssertEqual(TokenNormalizer.normalizeWord("GRDB", options: opts), "grdb")
    }

    func testNormalizeWordDiacritic() {
        let opts = JiebaTokenizerOptions(caseFolding: true, widthFolding: false, diacriticFolding: true)
        XCTAssertEqual(TokenNormalizer.normalizeWord("café", options: opts), "cafe")
    }

    func testNormalizeWordWidthFolding() {
        let opts = JiebaTokenizerOptions(caseFolding: true, widthFolding: true, diacriticFolding: false)
        // Fullwidth digits / letters via NFKC
        XCTAssertEqual(TokenNormalizer.normalizeWord("ＡＢＣ", options: opts), "abc")
        XCTAssertEqual(TokenNormalizer.normalizeWord("１２３", options: opts), "123")
    }

    func testNormalizeMatchesStopwordSet() {
        let opts = JiebaTokenizerOptions.recommended
        let folded = TokenNormalizer.normalizeWord("The", options: opts)
        let set = StopwordSet(stopwords: StopwordPresets.english, options: opts)
        let bytes = Array(folded.utf8)
        bytes.withUnsafeBufferPointer { buf in
            XCTAssertTrue(set.contains(buf))
        }
    }

    func testIsPureCJK() {
        let s = "清华大学"
        Array(s.utf8).withUnsafeBufferPointer { buf in
            XCTAssertTrue(TokenNormalizer.isPureCJKUnified(buf.baseAddress!, count: buf.count))
        }
        let mixed = "清华A"
        Array(mixed.utf8).withUnsafeBufferPointer { buf in
            XCTAssertFalse(TokenNormalizer.isPureCJKUnified(buf.baseAddress!, count: buf.count))
        }
    }

    func testIsASCIINonAlphanumeric() {
        let punct = "..."
        Array(punct.utf8).withUnsafeBufferPointer { buf in
            XCTAssertTrue(TokenNormalizer.isASCIINonAlphanumeric(buf.baseAddress!, count: buf.count))
        }
        let word = "ok"
        Array(word.utf8).withUnsafeBufferPointer { buf in
            XCTAssertFalse(TokenNormalizer.isASCIINonAlphanumeric(buf.baseAddress!, count: buf.count))
        }
    }

    func testAsciiCaseInfo() {
        let upper = "Hello"
        Array(upper.utf8).withUnsafeBufferPointer { buf in
            let info = TokenNormalizer.asciiCaseInfo(buf.baseAddress!, count: buf.count)
            XCTAssertTrue(info.isASCII)
            XCTAssertTrue(info.hasUpper)
        }
        let lower = "hello"
        Array(lower.utf8).withUnsafeBufferPointer { buf in
            let info = TokenNormalizer.asciiCaseInfo(buf.baseAddress!, count: buf.count)
            XCTAssertTrue(info.isASCII)
            XCTAssertFalse(info.hasUpper)
        }
    }

    func testFastFoldASCIIUpper() {
        let src = Array("AbC".utf8)
        var dest = [UInt8](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { sbuf in
            dest.withUnsafeMutableBufferPointer { dbuf in
                TokenNormalizer.foldASCIIUpper(sbuf.baseAddress!, count: src.count, into: dbuf.baseAddress!)
            }
        }
        XCTAssertEqual(String(bytes: dest, encoding: .utf8), "abc")
    }

    func testFastFoldLatin1() {
        let cafe = Array("café".utf8) // c a f C3 A9
        var dest = [UInt8](repeating: 0, count: cafe.count)
        let opts = JiebaTokenizerOptions(caseFolding: true, widthFolding: true, diacriticFolding: true)
        let outcome = cafe.withUnsafeBufferPointer { sbuf in
            dest.withUnsafeMutableBufferPointer { dbuf in
                TokenNormalizer.tryFastFold(
                    sbuf.baseAddress!,
                    count: cafe.count,
                    options: opts,
                    into: dbuf.baseAddress!
                )
            }
        }
        if case .folded(let len) = outcome {
            XCTAssertEqual(String(bytes: dest.prefix(len), encoding: .utf8), "cafe")
        } else {
            XCTFail("expected fast fold for café")
        }
    }

    func testProfiles() {
        XCTAssertEqual(JiebaTokenizerOptions.recommended.stopwords, StopwordPresets.cjkCommon)
        XCTAssertFalse(JiebaTokenizerOptions.strictMatch.caseFolding)
        XCTAssertNil(JiebaTokenizerOptions.strictMatch.stopwords)
    }

    func testStopwordsPresetRoundTrip() {
        let opts = JiebaTokenizerOptions(stopwords: StopwordPresets.english)
        let args = opts.arguments
        XCTAssertTrue(args.contains("stopwords_preset"))
        XCTAssertTrue(args.contains("en"))
        let decoded = JiebaTokenizerOptions(arguments: args)
        XCTAssertEqual(decoded.stopwords, StopwordPresets.english)
    }

    func testConfigureReturnsBool() {
        // If already warm from other tests, configure should return false without crashing.
        _ = JiebaEngine.shared
        let ok = JiebaEngine.configure(
            dictPath: "/tmp/nope.dict",
            hmmPath: "/tmp/nope.hmm",
            userDictPath: "/tmp/nope.user"
        )
        XCTAssertFalse(ok)
        XCTAssertTrue(JiebaEngine.isInitialized)
    }
}
