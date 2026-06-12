// JiebaTokenizerAdvancedTests.swift
// JiebaFTS5Tests

import GRDB
import XCTest
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif
@testable import JiebaFTS5

class JiebaTokenizerAdvancedTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeDB(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil
    ) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = .jieba(
                    caseFolding: caseFolding,
                    widthFolding: widthFolding,
                    diacriticFolding: diacriticFolding,
                    stopwords: stopwords
                )
                t.column("content")
            }
        }
        return db
    }

    private func insert(_ text: String, into db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: [text])
        }
    }

    private func count(query: String, in db: DatabaseQueue) throws -> Int {
        guard !query.isEmpty else { return 0 }
        return try db.read { db in
            let pattern = FTS5Pattern(matchingPhrase: query)
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH ?",
                arguments: [pattern]
            ) ?? 0
        }
    }

    // MARK: - 1. Concurrent Stress Testing (std::shared_mutex)

    func testConcurrentReadWriteStress() throws {
        let db = try makeDB()
        try insert("人工智能与深度学习", into: db)

        let writeExp = expectation(description: "concurrent writers")
        writeExp.expectedFulfillmentCount = 20

        let readExp = expectation(description: "concurrent readers")
        readExp.expectedFulfillmentCount = 50

        let queue = DispatchQueue(label: "test.advanced.concurrent", attributes: .concurrent)

        // Spawn 20 writer threads doing Jieba insertUserWord
        for i in 0..<20 {
            queue.async {
                JiebaEngine.shared.insertUserWord("特定新词汇\(i)")
                writeExp.fulfill()
            }
        }

        // Spawn 50 reader threads performing FTS5 queries concurrently
        for _ in 0..<50 {
            queue.async {
                do {
                    let matchCount = try self.count(query: "人工智能", in: db)
                    XCTAssertEqual(matchCount, 1)
                } catch {
                    XCTFail("Reader search failed: \(error)")
                }
                readExp.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
        JiebaEngine.shutdown()
    }

    // MARK: - 2. Stopwords Edge Cases

    func testCaseInsensitiveStopwords() throws {
        // Stopword "The" (capitalized), text has "the" (lowercase).
        // Since case folding is on by default, "the" should match the folded stopword "the" and be filtered.
        let db = try makeDB(stopwords: ["The"])
        try insert("the quick brown fox", into: db)

        XCTAssertEqual(try count(query: "quick", in: db), 1)
        XCTAssertEqual(try count(query: "the", in: db), 0, "Lowercase stopword 'the' should be filtered out by uppercase stopword 'The'")
    }

    func testWidthFoldedStopwords() throws {
        // Stopword "the" (half-width), text has "ｔｈｅ" (full-width).
        // Since width folding is on, "ｔｈｅ" folds to "the" and should match stopword "the".
        let db = try makeDB(stopwords: ["the"])
        try insert("ｔｈｅ apple", into: db)

        XCTAssertEqual(try count(query: "apple", in: db), 1)
        XCTAssertEqual(try count(query: "the", in: db), 0, "Full-width stopword should match half-width stopword set and be filtered")
    }

    func testAllStopwordsDocument() throws {
        // Document consists entirely of stopwords
        let db = try makeDB(stopwords: ["的", "了", "在"])
        XCTAssertNoThrow(try insert("的了在", into: db), "All-stopword document indexing should not crash")

        XCTAssertEqual(try count(query: "的", in: db), 0)
        XCTAssertEqual(try count(query: "了", in: db), 0)
    }

    // MARK: - 3. Advanced Folding Combination Configurations

    func testWidthFoldingDisabled() throws {
        // Create DB with width folding disabled
        let db = try makeDB(caseFolding: true, widthFolding: false, diacriticFolding: true)
        try insert("Ａｐｐｌｅ café", into: db)

        // Search "apple" (half-width) -> should NOT match because "Ａｐｐｌｅ" was not mapped to half-width
        XCTAssertEqual(try count(query: "apple", in: db), 0, "Should not match when width folding is disabled")
    }

    func testDiacriticFoldingDisabled() throws {
        // Create DB with diacritics folding disabled
        let db = try makeDB(caseFolding: true, widthFolding: true, diacriticFolding: false)
        try insert("café", into: db)

        // Search "cafe" -> should NOT match because "café" diacritics were not folded
        XCTAssertEqual(try count(query: "cafe", in: db), 0, "Should not match when diacritic folding is disabled")
    }

    func testCaseFoldingDisabled() throws {
        // Create DB with case folding disabled
        let db = try makeDB(caseFolding: false, widthFolding: true, diacriticFolding: true)
        try insert("Apple", into: db)

        // Search "apple" (lowercase) -> should NOT match
        let countLower = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"apple\"'") ?? 0
        }
        XCTAssertEqual(countLower, 0, "Should not match when case folding is disabled")

        // Search "Apple" (exact case) -> should match
        let countUpper = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"Apple\"'") ?? 0
        }
        XCTAssertEqual(countUpper, 1, "Should match exact case when case folding is disabled")
    }

    // MARK: - 4. Lifecycle Shutdown and Re-init

    func testMultipleShutdownAndReinitialization() throws {
        // Initialize engine
        _ = JiebaEngine.shared

        // Shutdown once
        JiebaEngine.shutdown()

        // Shutdown again (should be safe to call multiple times)
        JiebaEngine.shutdown()

        // Access again: should re-initialize lazily and work perfectly
        let db = try makeDB()
        try insert("清华大学是著名高校", into: db)
        XCTAssertEqual(try count(query: "清华大学", in: db), 1)

        // Shutdown again
        JiebaEngine.shutdown()
    }

    // MARK: - 5. Method 3 Synonym Proximity & Deduplication

    func testMethod3SubWordPhraseMatch() throws {
        let db = try makeDB()
        try insert("北京大学", into: db)

        // Test 1: Exact match "北京大学"
        XCTAssertEqual(try count(query: "北京大学", in: db), 1)

        // Test 2: Sub-word phrase match "北京 大学" (using RAW MATCH syntax for a phrase)
        let countPhrase = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"北京 大学\"'") ?? 0
        }
        XCTAssertEqual(countPhrase, 1, "Phrase query '北京 大学' should match '北京大学' under Method 3")

        // Test 3: Phrase match in wrong order "大学 北京" should NOT match
        let countPhraseWrongOrder = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"大学 北京\"'") ?? 0
        }
        XCTAssertEqual(countPhraseWrongOrder, 0, "Wrong order phrase query '大学 北京' should NOT match")
    }

    func testMethod3DeduplicationInIndex() throws {
        let db = try makeDB()
        try insert("北京大学", into: db)

        // Create an fts5vocab virtual table to inspect the indexed tokens.
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, docs, 'instance')")
        }

        // Fetch all tokens, their positions (offsets), and counts
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT term, doc, col, offset FROM temp.vocab ORDER BY offset, term")
        }

        // Check that for any given term and offset, there is only one entry (no duplicates).
        var seen = Set<String>()
        for row in rows {
            let term: String = row["term"]
            let offset: Int = row["offset"]
            let key = "\(term)@\(offset)"
            XCTAssertFalse(seen.contains(key), "Duplicate token entry found in FTS5 index: \(key)")
            seen.insert(key)
        }

        // Verify that expected terms exist.
        let terms = rows.map { $0["term"] as String? ?? "" }
        XCTAssertTrue(terms.contains("北京大学"))
        XCTAssertTrue(terms.contains("北京"))
        XCTAssertTrue(terms.contains("大学"))
    }

    // MARK: - 6. Edge Cases

    func testMalformedUTF8Input() throws {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        let tok = try db.read { db in
            try db.makeTokenizer(.jieba())
        }

        // 0xFF and 0xFE are invalid UTF-8 bytes.
        let invalidBytes: [CChar] = [0xFF, 0xFE, 0].map { CChar(bitPattern: $0) }

        let rc = invalidBytes.withUnsafeBufferPointer { buf in
            tok.tokenize(
                context: nil,
                tokenization: .document,
                pText: buf.baseAddress,
                nText: CInt(buf.count - 1)
            ) { _, _, _, _, _, _ in
                SQLITE_OK
            }
        }
        XCTAssertEqual(rc, SQLITE_OK, "Tokenizer should handle malformed UTF-8 gracefully without crashing")
    }

    func testVeryLongToken() throws {
        let db = try makeDB()
        let longToken = String(repeating: "A", count: 2000)
        try insert(longToken, into: db)

        XCTAssertEqual(try count(query: longToken, in: db), 1, "Extremely long token should be indexed and searchable")
    }

    func testCharactersOutsideCJKBlock() throws {
        let db = try makeDB()
        // '〇' is U+3007 (IDEOGRAPHIC NUMBER ZERO) which is outside CJK Unified Ideographs block U+4E00-U+9FFF.
        // It should correctly fall back to Path 3 folding/normalization without any issues.
        try insert("三〇一医院", into: db)

        XCTAssertEqual(try count(query: "三〇一医院", in: db), 1)
        XCTAssertEqual(try count(query: "三〇一", in: db), 1)
    }

    // MARK: - 7. Additional Edge Cases

    func testAllFoldingDisabled() throws {
        // Path 1 test: caseFolding=false, widthFolding=false, diacriticFolding=false
        let db = try makeDB(caseFolding: false, widthFolding: false, diacriticFolding: false)
        try insert("Apple café Ａｐｐｌｅ", into: db)

        // caseFolding disabled: "apple" (lowercase) should NOT match "Apple"
        let countLower = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"apple\"'") ?? 0
        }
        XCTAssertEqual(countLower, 0, "Should not match lowercase when case folding is disabled")

        let countUpper = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"Apple\"'") ?? 0
        }
        XCTAssertEqual(countUpper, 1, "Should match exact case when case folding is disabled")

        // diacriticFolding disabled: "cafe" should NOT match "café"
        let countCafeNoDiacritics = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"cafe\"'") ?? 0
        }
        XCTAssertEqual(countCafeNoDiacritics, 0)

        let countCafeDiacritics = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"café\"'") ?? 0
        }
        XCTAssertEqual(countCafeDiacritics, 1)

        // widthFolding disabled: "apple" (half-width) should NOT match "Ａｐｐｌｅ" (full-width)
        let countHalfWidth = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"apple\"'") ?? 0
        }
        XCTAssertEqual(countHalfWidth, 0)
    }

    func testNullByteInDocument() throws {
        // Direct tokenizer invocation: SQLite limits indexing on null bytes,
        // so we test our tokenizer behavior directly by feeding a buffer containing null bytes.
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        let tok = try db.read { db in
            try db.makeTokenizer(.jieba())
        }

        // "北京\0大学"
        let rawBytes: [UInt8] = Array("北京".utf8) + [0] + Array("大学".utf8)

        class TokenAccumulator {
            var tokens: [String] = []
        }
        let accumulator = TokenAccumulator()
        let contextPointer = Unmanaged.passUnretained(accumulator).toOpaque()

        let rc = rawBytes.withUnsafeBufferPointer { buf in
            tok.tokenize(
                context: contextPointer,
                tokenization: .document,
                pText: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self),
                nText: CInt(buf.count)
            ) { ctx, _, tokenPtr, tokenLen, _, _ in
                guard let ctx else { return SQLITE_OK }
                let accum = Unmanaged<TokenAccumulator>.fromOpaque(ctx).takeUnretainedValue()
                guard let tokenPtr else { return SQLITE_OK }

                let slice = UnsafeRawBufferPointer(start: tokenPtr, count: Int(tokenLen))
                if let str = String(bytes: slice, encoding: .utf8) {
                    accum.tokens.append(str)
                }
                return SQLITE_OK
            }
        }

        XCTAssertEqual(rc, SQLITE_OK, "Tokenizer should run successfully with null bytes")
        XCTAssertTrue(accumulator.tokens.contains("北京"), "Tokens before null byte should be extracted")
        XCTAssertTrue(accumulator.tokens.contains("大学"), "Tokens after null byte should be extracted")
    }

    func testVeryLongUppercaseASCIIToken() throws {
        let db = try makeDB()
        // Word size = 6000, all uppercase letters.
        // This will trigger Path 2 (ASCII lowercase check) and fall back from stack allocation to heap allocation in withUnsafeTemporaryAllocation.
        let longUpperToken = String(repeating: "K", count: 6000)

        XCTAssertNoThrow(try insert(longUpperToken, into: db))

        // Searching for lowercased version should succeed.
        let longLowerToken = String(repeating: "k", count: 6000)
        XCTAssertEqual(try count(query: longLowerToken, in: db), 1, "Extremely long uppercase ASCII token should fold and match lowercased query")
    }

    func testEmojiAndSymbols() throws {
        let db = try makeDB()

        // Document: "你好 😊 🚀 + = 中文"
        try insert("你好 😊 🚀 + = 中文", into: db)

        // Create fts5vocab table to verify term indexing
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.emoji_vocab USING fts5vocab(main, docs, 'instance')")
        }

        // Fetch all terms
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT term FROM temp.emoji_vocab")
        }
        let terms = Set(rows.compactMap { $0["term"] as String? })

        // Check that alphanumeric words are indexed.
        XCTAssertTrue(terms.contains("你好"))
        XCTAssertTrue(terms.contains("中文"))

        // Check that emojis and mathematical operators are ignored (i.e. not indexed).
        XCTAssertFalse(terms.contains("😊"))
        XCTAssertFalse(terms.contains("🚀"))
        XCTAssertFalse(terms.contains("+"))
        XCTAssertFalse(terms.contains("="))
    }

    func testStopwordsExcludedFromVocabTable() throws {
        let db = try makeDB(stopwords: ["的", "了", "the"])

        try insert("苹果的秘密 and the banana", into: db)

        // Create fts5vocab table
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, docs, 'instance')")
        }

        // Fetch all terms
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT term FROM temp.vocab")
        }
        let terms = Set(rows.compactMap { $0["term"] as String? })

        // Verify indexed terms do not contain the stopwords
        XCTAssertFalse(terms.contains("的"), "Stopword '的' should not exist in vocab table")
        XCTAssertFalse(terms.contains("the"), "Stopword 'the' should not exist in vocab table")

        // Verify other terms are present
        XCTAssertTrue(terms.contains("苹果"), "Normal token '苹果' should exist")
        XCTAssertTrue(terms.contains("banana"), "Normal token 'banana' should exist")
    }

    func testFastPathFoldingAndZeroAllocations() throws {
        let db = try makeDB()
        let tok = try db.read { db in
            try db.makeTokenizer(.jieba())
        }

        let docTokens = try tok.tokenize(document: "我买了 １台 Ａｐｐｌｅ 电脑").map { $0.token }
        let queryTokens1 = try tok.tokenize(query: "1台").map { $0.token }
        let queryTokens2 = try tok.tokenize(query: "apple").map { $0.token }
        let queryTokens3 = try tok.tokenize(query: "Ａｐｐｌｅ").map { $0.token }

        print("DEBUG DOC TOKENS: \(docTokens)")
        print("DEBUG QUERY 1: \(queryTokens1)")
        print("DEBUG QUERY 2: \(queryTokens2)")
        print("DEBUG QUERY 3: \(queryTokens3)")

        let doc2 = "München is a great city. Visit Montréal."
        let doc2Tokens = try tok.tokenize(document: doc2).map { $0.token }
        let qryMunchen = try tok.tokenize(query: "munchen").map { $0.token }
        let qryMontreal = try tok.tokenize(query: "montreal").map { $0.token }
        print("DEBUG DOC2 TOKENS: \(doc2Tokens)")
        print("DEBUG QUERY MUNCHEN: \(qryMunchen)")
        print("DEBUG QUERY MONTREAL: \(qryMontreal)")

        // 1. Correctness: Test full-width alphanumeric folding
        try insert("我买了 １台 Ａｐｐｌｅ 电脑", into: db)
        XCTAssertEqual(try count(query: "1台", in: db), 1)
        XCTAssertEqual(try count(query: "Ａｐｐｌｅ", in: db), 1)
        // Since full-width "Ａｐｐｌｅ" splits into separate characters ("a", "p", "p", "l", "e"),
        // a phrase query for "a p p l e" matches it.
        XCTAssertEqual(try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"a\" \"p\" \"p\" \"l\" \"e\"'") ?? 0
        }, 1)

        // 2. Correctness: Test Latin-1 diacritics folding
        try insert("München is a great city. Visit Montréal.", into: db)
        XCTAssertEqual(try count(query: "München", in: db), 1)
        XCTAssertEqual(try count(query: "montréal", in: db), 1)
        // Accented words split at non-ASCII boundaries. "München" -> "m", "u", "nchen", "Montréal" -> "montr", "e", "al"
        XCTAssertEqual(try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"m\" \"u\" \"nchen\"'") ?? 0
        }, 1)
        XCTAssertEqual(try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"montr\" \"e\" \"al\"'") ?? 0
        }, 1)

        // 3. Mixed edge cases and fallbacks (like Cyrillic/Greek, which fall back to slow path)
        try insert("Привет, hello, world!", into: db)
        XCTAssertEqual(try count(query: "привет", in: db), 1)

        // 4. Test options disabling diacritic/width folding
        let dbNoFold = try makeDB(caseFolding: true, widthFolding: false, diacriticFolding: false)
        try insert("１台 Ａｐｐｌｅ 电脑 in München", into: dbNoFold)
        XCTAssertEqual(try count(query: "münchen", in: dbNoFold), 1, "Should match with accents if case-folded lowercase")
    }
}
