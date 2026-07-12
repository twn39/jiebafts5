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
        _ = try? JiebaEngine.bootstrap()
        let ok = JiebaEngine.configure(
            dictPath: "/tmp/nope.dict",
            hmmPath: "/tmp/nope.hmm",
            userDictPath: "/tmp/nope.user"
        )
        XCTAssertFalse(ok)
        XCTAssertTrue(JiebaEngine.isInitialized)
    }

    func testBootstrapSucceedsWithBundleDefaults() throws {
        // May already be warm; bootstrap is idempotent once shared exists.
        let engine = try JiebaEngine.bootstrap()
        XCTAssertTrue(JiebaEngine.isInitialized)
        _ = engine
    }

    func testMakeThrowsOnMissingPaths() {
        XCTAssertThrowsError(
            try JiebaEngine.make(
                dictPath: "/tmp/jiebafts5-missing-dict-\(UUID().uuidString)",
                hmmPath: "/tmp/jiebafts5-missing-hmm-\(UUID().uuidString)",
                userDictPath: "/tmp/jiebafts5-missing-user-\(UUID().uuidString)"
            )
        ) { error in
            guard case JiebaEngineError.missingDictionaryFiles = error else {
                XCTFail("expected missingDictionaryFiles, got \(error)")
                return
            }
        }
    }

    func testSuggestTokensDocumentHasColocatedForCompound() {
        let tokens = JiebaTokenizer.suggestTokens(for: "清华大学", options: .init(), asQuery: false)
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.contains(where: { $0.text == "清华大学" && !$0.isColocated }))
        // QuerySeg typically emits colocated subwords for compounds.
        XCTAssertTrue(
            tokens.contains(where: { $0.isColocated }),
            "document mode should emit colocated sub-tokens for 清华大学; got \(tokens)"
        )
    }

    func testSuggestTokensRespectsRecommendedStopwords() {
        let tokens = JiebaTokenizer.suggestTokens(
            for: "the 的 苹果",
            options: .recommended,
            asQuery: false
        )
        let texts = Set(tokens.map(\.text))
        XCTAssertFalse(texts.contains("the"))
        XCTAssertFalse(texts.contains("的"))
        XCTAssertTrue(texts.contains("苹果") || texts.contains(where: { $0.contains("苹") }))
    }

    func testChineseStopwordPresetExpanded() {
        XCTAssertGreaterThan(StopwordPresets.chinese.count, 80)
        XCTAssertTrue(StopwordPresets.chinese.contains("因为"))
        XCTAssertTrue(StopwordPresets.chinese.contains("可以"))
        XCTAssertEqual(StopwordPresets.presetID(matching: StopwordPresets.chinese), "zh")
    }

    func testInsertUserWordsBatch() {
        let engine = JiebaEngine.shared
        let n = engine.insertUserWords(["批测词甲\(UUID().uuidString.prefix(6))", ""])
        // Empty string should fail; at least one unique word should succeed.
        XCTAssertGreaterThanOrEqual(n, 1)
    }

    func testNamedEngineRegistryAndOptionsRoundTrip() throws {
        guard let paths = JiebaEngine.bundledDictionaryPaths else {
            XCTFail("bundled dictionaries missing")
            return
        }
        let name = "test_engine_\(UUID().uuidString.prefix(8))"
        let eng = try JiebaEngine.make(
            dictPath: paths.dictPath,
            hmmPath: paths.hmmPath,
            userDictPath: paths.userDictPath
        )
        XCTAssertTrue(JiebaEngine.register(name: name, engine: eng))
        defer { JiebaEngine.unregister(name: name) }

        var opts = JiebaTokenizerOptions()
        opts.engineName = name
        let args = opts.arguments
        XCTAssertTrue(args.contains("engine"))
        XCTAssertTrue(args.contains(name))
        let decoded = JiebaTokenizerOptions(arguments: args)
        XCTAssertEqual(decoded.engineName, name)

        let resolved = try JiebaEngine.resolve(name: name)
        XCTAssertTrue(resolved === eng)

        let tok = JiebaTokenizer(engine: eng, options: .init())
        let tokens = tok.suggestTokens(for: "北京", asQuery: true)
        XCTAssertFalse(tokens.isEmpty)
    }

    func testResolveUnknownEngineNameThrows() {
        XCTAssertThrowsError(try JiebaEngine.resolve(name: "no_such_engine_zzz")) { error in
            guard case JiebaEngineError.unknownEngineName = error else {
                XCTFail("expected unknownEngineName, got \(error)")
                return
            }
        }
    }

    func testReservedEngineNameRegistrationFails() throws {
        guard let paths = JiebaEngine.bundledDictionaryPaths else {
            XCTFail("bundled dictionaries missing")
            return
        }
        let eng = try JiebaEngine.make(
            dictPath: paths.dictPath,
            hmmPath: paths.hmmPath,
            userDictPath: paths.userDictPath
        )
        XCTAssertFalse(JiebaEngine.register(name: "shared", engine: eng))
        XCTAssertFalse(JiebaEngine.register(name: "default", engine: eng))
        XCTAssertFalse(JiebaEngine.register(name: "", engine: eng))
    }
}
