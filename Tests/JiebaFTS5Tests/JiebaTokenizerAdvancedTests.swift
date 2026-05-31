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
                return SQLITE_OK
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
}
