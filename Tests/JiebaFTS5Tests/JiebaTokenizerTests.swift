// JiebaTokenizerTests.swift
// JiebaFTS5Tests

import XCTest
import GRDB
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif
@testable import JiebaFTS5


final class JiebaTokenizerTests: XCTestCase {

    // MARK: - Test Helpers

    /// Opens an in-memory DatabaseQueue with JiebaTokenizer registered.
    private func makeDB(caseFolding: Bool = true) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = .jieba(caseFolding: caseFolding)
                t.column("content")
            }
        }
        return db
    }

    /// Returns a raw tokenizer instance (not backed by FTS5 index).
    private func makeTokenizer(caseFolding: Bool = true) throws -> any FTS5Tokenizer {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        return try db.read { db in
            try db.makeTokenizer(.jieba(caseFolding: caseFolding))
        }
    }

    private func insert(_ text: String, into db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)",
                           arguments: [text])
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

    // =========================================================================
    // MARK: - 1. Basic Chinese Segmentation
    // =========================================================================

    func testExactWordMatch() throws {
        let db = try makeDB()
        try insert("我来到北京清华大学", into: db)
        XCTAssertEqual(try count(query: "清华大学", in: db), 1)
    }

    func testSubWordMatch() throws {
        let db = try makeDB()
        try insert("我来到北京清华大学", into: db)
        // CutForSearch emits "清华", "华大", "大学" as COLOCATED synonyms.
        XCTAssertEqual(try count(query: "清华",   in: db), 1, "sub-word 清华 via COLOCATED")
        XCTAssertEqual(try count(query: "大学",   in: db), 1, "sub-word 大学")
        XCTAssertEqual(try count(query: "华大",   in: db), 1, "sub-word 华大")
    }

    func testSingleChineseCharacter() throws {
        // Single CJK characters that are valid words on their own.
        let db = try makeDB()
        try insert("爱中华", into: db)
        XCTAssertEqual(try count(query: "中", in: db), 0,
                       "单个汉字 '中' 不是独立词，jieba 不单独切出")
        XCTAssertEqual(try count(query: "中华", in: db), 1,
                       "'中华' 是词典词，应命中")
    }

    func testKnownCompoundWord() throws {
        let db = try makeDB()
        try insert("中国科学院计算所", into: db)
        XCTAssertGreaterThan(try count(query: "中国", in: db), 0)
        XCTAssertGreaterThan(try count(query: "科学院", in: db), 0)
    }

    // =========================================================================
    // MARK: - 2. Method 3 False-Positive Regression
    // =========================================================================

    func testQueryModeNoFalsePositive() throws {
        // Core regression: COLOCATED must never appear in query mode.
        // If it did, "北清" would OR-match any doc containing 北 and 清 separately.
        let db = try makeDB()
        try insert("北京清华大学", into: db)
        XCTAssertEqual(try count(query: "北清", in: db), 0,
                       "Method 3: 非词 '北清' 不应假阳性命中")
    }

    func testUnrelatedDocumentNotMatched() throws {
        let db = try makeDB()
        try insert("上海交通大学", into: db)
        XCTAssertEqual(try count(query: "清华大学", in: db), 0,
                       "'清华大学' 不应命中 '上海交通大学'")
    }

    // =========================================================================
    // MARK: - 3. Phrase Query (Position-Sensitive Matching)
    // =========================================================================

    func testPhraseQueryAdjacentWords() throws {
        let db = try makeDB()
        try insert("我来到北京清华大学", into: db)
        // jieba assigns "北京" and "清华大学" consecutive positions.
        XCTAssertEqual(try count(query: "北京清华大学", in: db), 1)
    }

    func testPhraseQueryRequiresProximity() throws {
        // "清华大学" and "北京" both exist but are NOT adjacent in this document.
        let db = try makeDB()
        try insert("北京是首都。清华大学是著名高校。", into: db)
        // Individual word matches still work.
        XCTAssertEqual(try count(query: "清华大学", in: db), 1, "词本身应命中")
        XCTAssertEqual(try count(query: "北京",     in: db), 1, "词本身应命中")
        // Phrase query of the two together should NOT match because
        // they are separated by punctuation and other tokens.
        XCTAssertEqual(try count(query: "北京清华大学", in: db), 0,
                       "非相邻的 phrase 不应命中")
    }

    // =========================================================================
    // MARK: - 4. Mixed CJK + ASCII
    // =========================================================================

    func testMixedCJKAndASCII() throws {
        let db = try makeDB()
        try insert("Swift 是 Apple 开发的编程语言", into: db)
        XCTAssertEqual(try count(query: "swift",  in: db), 1, "caseFold lowercase")
        XCTAssertEqual(try count(query: "Apple",  in: db), 1, "mixed case ASCII")
        XCTAssertEqual(try count(query: "编程",   in: db), 1, "CJK in mixed doc")
    }

    func testNumberTokens() throws {
        // Numbers embedded in Chinese text.
        let db = try makeDB()
        try insert("2024年诺贝尔奖", into: db)
        XCTAssertEqual(try count(query: "2024", in: db), 1, "数字应命中")
        XCTAssertEqual(try count(query: "诺贝尔", in: db), 1, "中文词应命中")
    }

    func testLatinWithDiacritics() throws {
        // Full-width letters and diacritics go through the Unicode lowercase path.
        let db = try makeDB(caseFolding: true)
        try insert("Ａｐｐｌｅ", into: db)     // full-width ASCII
        // caseFolding=true uses lowercased() for non-ASCII — verify no crash.
        XCTAssertNoThrow(try count(query: "ａｐｐｌｅ", in: db))
    }

    // =========================================================================
    // MARK: - 5. Case Folding
    // =========================================================================

    func testCaseFoldingEnabled_AsciiUpperToLower() throws {
        let db = try makeDB(caseFolding: true)
        try insert("Hello World", into: db)
        XCTAssertEqual(try count(query: "hello", in: db), 1)
        XCTAssertEqual(try count(query: "WORLD", in: db), 1)
        XCTAssertEqual(try count(query: "Hello", in: db), 1)
    }

    func testCaseFoldingEnabled_CJKUnaffected() throws {
        // CJK tokens are not ASCII, so folding path emits them via lowercased()
        // which is a no-op for ideographs.  Verify search still works.
        let db = try makeDB(caseFolding: true)
        try insert("北京大学", into: db)
        XCTAssertEqual(try count(query: "北京大学", in: db), 1,
                       "caseFolding 对中文无影响，查询应正常命中")
    }

    func testCaseFoldingDisabled_CaseSensitive() throws {
        let db = try makeDB(caseFolding: false)
        try insert("Hello World", into: db)
        XCTAssertEqual(try count(query: "hello", in: db), 0, "大小写不折叠时不应命中")
        // Cross-check: folding-enabled DB does hit.
        let dbFold = try makeDB(caseFolding: true)
        try insert("Hello World", into: dbFold)
        XCTAssertEqual(try count(query: "hello", in: dbFold), 1)
    }

    // =========================================================================
    // MARK: - 6. Token Emission Invariants (direct tokenizer inspection)
    // =========================================================================

    func testDocumentAndQueryTokensConsistent() throws {
        // caseFolding=false: whatever the document side emits, the query side
        // MUST emit the same bytes — otherwise FTS5 can never match.
        let tok = try makeTokenizer(caseFolding: false)
        let docTokens = try tok.tokenize(document: "Hello World").map { $0.token }
        let qryTokens = try tok.tokenize(query:    "Hello").map       { $0.token }
        XCTAssertTrue(docTokens.contains(qryTokens.first ?? ""),
                      "doc 和 query 的 token 字节必须一致")
    }

    func testCaseFoldingProducesLowercaseDocTokens() throws {
        let tok = try makeTokenizer(caseFolding: true)
        let tokens = try tok.tokenize(document: "GRDB Swift").map { $0.token }
        XCTAssertTrue(tokens.contains("grdb"),  "GRDB → grdb")
        XCTAssertTrue(tokens.contains("swift"), "Swift → swift")
    }

    func testCaseFoldingProducesLowercaseQueryTokens() throws {
        let tok = try makeTokenizer(caseFolding: true)
        let tokens = try tok.tokenize(query: "GRDB").map { $0.token }
        XCTAssertEqual(tokens.first, "grdb", "query token must be lowercased")
    }

    func testDocumentEmitsCOLOCATEDForSubWords() throws {
        // Verify that CutForSearch produces COLOCATED flags on the document side.
        let tok = try makeTokenizer(caseFolding: true)
        let pairs = try tok.tokenize(document: "清华大学")
        // Should have at least: "清华大学"(pos0,normal) + "清华"(pos0,COLOCATED) + ...
        let hasColocated = pairs.contains { $0.flags.contains(.colocated) }
        XCTAssertTrue(hasColocated, "文档模式应发射 COLOCATED 子词")
    }

    func testQueryEmitsNoCOLOCATED() throws {
        // Verify query mode never emits COLOCATED (Method 3 invariant).
        let tok = try makeTokenizer(caseFolding: true)
        let pairs = try tok.tokenize(query: "清华大学")
        let hasColocated = pairs.contains { $0.flags.contains(.colocated) }
        XCTAssertFalse(hasColocated, "查询模式禁止发射 COLOCATED")
    }

    func testAuxModeTokensMatchDocumentMode() throws {
        // AUX mode (used by snippet/highlight) must index the same positions as
        // DOCUMENT mode.  We verify this end-to-end: insert a document, then use
        // snippet() which internally triggers AUX tokenization, and confirm that
        // the highlighted token aligns with what we indexed.
        let db = try makeDB()
        try insert("清华大学是著名高校", into: db)

        let snippet = try db.read { db -> String? in
            let sql = "SELECT snippet(docs, 0, '<<', '>>', '...', 10) FROM docs WHERE docs MATCH ?"
            let pattern = FTS5Pattern(matchingPhrase: "清华大学")
            return try String.fetchOne(db, sql: sql, arguments: [pattern])
        }
        // If AUX tokenization is broken the snippet offsets misalign and either
        // return nil or garbled text.
        XCTAssertNotNil(snippet, "snippet() AUX 路径应返回结果")
        XCTAssertTrue(snippet?.contains("<<") ?? false,
                      "AUX 字节偏移正确时高亮标签应出现在结果中")
    }


    // =========================================================================
    // MARK: - 7. Edge Cases: Empty / Whitespace / Punctuation
    // =========================================================================

    func testEmptyString() throws {
        let db = try makeDB()
        try insert("", into: db)
        XCTAssertEqual(try count(query: "test", in: db), 0)
    }

    func testWhitespaceOnlyDocument() throws {
        // Pure whitespace: jieba emits whitespace tokens, no searchable content.
        let db = try makeDB()
        XCTAssertNoThrow(try insert("   \t\n", into: db))
        XCTAssertEqual(try count(query: "test", in: db), 0)
    }

    func testChinesePunctuation() throws {
        let db = try makeDB()
        XCTAssertNoThrow(try insert("你好，世界！", into: db))
        XCTAssertEqual(try count(query: "你好", in: db), 1, "中文与标点混合应能命中词")
    }

    func testASCIIPunctuation() throws {
        let db = try makeDB()
        XCTAssertNoThrow(try insert("hello, world!", into: db))
        XCTAssertEqual(try count(query: "hello", in: db), 1)
    }

    func testFullWidthPunctuation() throws {
        let db = try makeDB()
        XCTAssertNoThrow(try insert("。！？，、", into: db))
    }

    func testNewlineInDocument() throws {
        let db = try makeDB()
        try insert("北京大学\n清华大学", into: db)
        XCTAssertEqual(try count(query: "北京大学", in: db), 1, "换行前的词应命中")
        XCTAssertEqual(try count(query: "清华大学", in: db), 1, "换行后的词应命中")
    }

    // =========================================================================
    // MARK: - 8. Long / Large Input
    // =========================================================================

    func testLongDocument() throws {
        // Verify no buffer overflows or crashes on a long document.
        // Use a sentence that contains a definite jieba word as anchor.
        let sentence = "北京大学是中国著名高校。"
        let repeated = String(repeating: sentence, count: 200)  // ~2400 bytes
        let db = try makeDB()
        XCTAssertNoThrow(try insert(repeated, into: db))
        // "北京大学" appears many times — should match exactly 1 document row.
        XCTAssertEqual(try count(query: "北京大学", in: db), 1,
                       "长文档应正常分词并命中")
    }

    func testManyShortDocuments() throws {
        let db = try makeDB()
        let words = ["苹果", "香蕉", "橘子", "葡萄", "西瓜",
                     "草莓", "蓝莓", "芒果", "菠萝", "荔枝"]
        for w in words { try insert(w, into: db) }
        XCTAssertEqual(try count(query: "苹果", in: db), 1, "精确命中 1 条")
        XCTAssertEqual(
            try db.read { db in
                try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM docs", arguments: []) ?? 0
            }, words.count, "共 \(words.count) 条记录"
        )
    }

    // =========================================================================
    // MARK: - 9. Update & Delete (Index Maintenance)
    // =========================================================================

    func testDeleteRemovesFromIndex() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(rowid, content) VALUES (1, ?)",
                           arguments: ["清华大学是著名高校"])
        }
        XCTAssertEqual(try count(query: "清华大学", in: db), 1, "插入后应命中")

        try db.write { db in
            try db.execute(sql: "DELETE FROM docs WHERE rowid = 1")
        }
        XCTAssertEqual(try count(query: "清华大学", in: db), 0, "删除后不应命中")
    }

    func testUpdateChangesIndex() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(rowid, content) VALUES (1, ?)",
                           arguments: ["北京大学"])
        }
        XCTAssertEqual(try count(query: "北京大学", in: db), 1)
        XCTAssertEqual(try count(query: "清华大学", in: db), 0)

        // FTS5 UPDATE = DELETE old tokens + INSERT new tokens.
        try db.write { db in
            try db.execute(sql: "UPDATE docs SET content = ? WHERE rowid = 1",
                           arguments: ["清华大学"])
        }
        XCTAssertEqual(try count(query: "清华大学", in: db), 1, "更新后新词应命中")
        XCTAssertEqual(try count(query: "北京大学", in: db), 0, "更新后旧词不应命中")
    }

    // =========================================================================
    // MARK: - 10. Multiple Documents & Ranking
    // =========================================================================

    func testMultipleDocumentsSelectivity() throws {
        let db = try makeDB()
        try insert("北京清华大学",  into: db)
        try insert("上海交通大学",  into: db)
        try insert("浙江大学",      into: db)
        XCTAssertEqual(try count(query: "大学",    in: db), 3)
        XCTAssertEqual(try count(query: "清华大学", in: db), 1)
        XCTAssertEqual(try count(query: "北京",     in: db), 1)
    }

    // =========================================================================
    // MARK: - 11. Concurrency (Thread Safety)
    // =========================================================================

    func testConcurrentSearches() throws {
        let db = try makeDB()
        let docs = ["清华大学", "北京大学", "上海交通大学", "浙江大学", "复旦大学",
                    "南京大学", "武汉大学", "中山大学", "四川大学", "哈尔滨工业大学"]
        for doc in docs { try insert(doc, into: db) }

        let exp = expectation(description: "concurrent searches")
        exp.expectedFulfillmentCount = 20
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        for _ in 0..<20 {
            queue.async {
                do {
                    XCTAssertGreaterThan(try self.count(query: "大学", in: db), 0)
                } catch {
                    XCTFail("Concurrent search threw: \(error)")
                }
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: 10)
    }

    func testConcurrentMixedReadWrite() throws {
        // Simultaneous inserts and reads via the shared engine.
        let db = try makeDB()
        let exp = expectation(description: "mixed concurrent")
        exp.expectedFulfillmentCount = 10
        let queue = DispatchQueue(label: "test.rw", attributes: .concurrent)

        for i in 0..<10 {
            queue.async {
                do {
                    try self.insert("词汇\(i)中文测试", into: db)
                    _ = try self.count(query: "中文测试", in: db)
                } catch {
                    XCTFail("Concurrent rw threw: \(error)")
                }
                exp.fulfill()
            }
        }
        waitForExpectations(timeout: 10)
    }

    // =========================================================================
    // MARK: - 12. Singleton Sharing
    // =========================================================================

    func testEngineIsShared() throws {
        let db1 = try makeDB()
        let db2 = try makeDB()
        try insert("人工智能", into: db1)
        try insert("机器学习", into: db2)
        XCTAssertEqual(try count(query: "人工智能", in: db1), 1)
        XCTAssertEqual(try count(query: "机器学习", in: db2), 1)
        XCTAssertEqual(try count(query: "机器学习", in: db1), 0, "db1 不含 db2 的内容")
    }

    // =========================================================================
    // MARK: - 13. AUX Tokenization (snippet / highlight)
    // =========================================================================

    func testAUXTokenizationDoesNotCrash() throws {
        let db = try makeDB()
        try insert("清华大学是著名高校", into: db)
        let result = try db.read { db -> String? in
            let sql = "SELECT snippet(docs, 0, '<b>', '</b>', '...', 5) FROM docs WHERE docs MATCH ?"
            let pattern = FTS5Pattern(matchingPhrase: "清华大学")
            return try String.fetchOne(db, sql: sql, arguments: [pattern])
        }
        XCTAssertNotNil(result, "snippet() 应返回非 nil 结果")
        XCTAssertTrue(result?.contains("<b>") ?? false, "snippet 应包含高亮标签")
    }

    // =========================================================================
    // MARK: - 14. JiebaTokenizerOptions
    // =========================================================================

    func testOptionsEquatable() {
        XCTAssertEqual(JiebaTokenizerOptions(caseFolding: true),
                       JiebaTokenizerOptions(caseFolding: true))
        XCTAssertNotEqual(JiebaTokenizerOptions(caseFolding: true),
                          JiebaTokenizerOptions(caseFolding: false))
    }

    func testOptionsRoundTripCaseFoldingTrue() {
        let opts = JiebaTokenizerOptions(caseFolding: true)
        XCTAssertEqual(opts, JiebaTokenizerOptions(arguments: opts.arguments))
    }

    func testOptionsRoundTripCaseFoldingFalse() {
        let opts = JiebaTokenizerOptions(caseFolding: false)
        XCTAssertEqual(opts, JiebaTokenizerOptions(arguments: opts.arguments))
    }

    func testOptionsDefaultIsCaseFoldingTrue() {
        // Default options must fold case to ensure consistent behavior
        // when integrators call .jieba() without arguments.
        let defaultOpts = JiebaTokenizerOptions()
        XCTAssertTrue(defaultOpts.caseFolding,
                      "默认 caseFolding 应为 true（大小写不敏感搜索）")
    }

    func testOptionsArgumentsDoNotContainTokenizerName() {
        // options.arguments encodes ONLY the option flags (e.g. "no_case_fold").
        // The tokenizer name is prepended by tokenizerDescriptor(), not here.
        // This aligns with how GRDB's built-in tokenizers work.
        let optsDefault = JiebaTokenizerOptions(caseFolding: true)
        XCTAssertFalse(optsDefault.arguments.contains("jieba"),
                       "default options.arguments should be empty (no flags)")
        XCTAssertTrue(optsDefault.arguments.isEmpty,
                      "caseFolding=true produces no extra argument")

        let optsNoFold = JiebaTokenizerOptions(caseFolding: false)
        XCTAssertEqual(optsNoFold.arguments, ["no_case_fold"],
                       "caseFolding=false adds 'no_case_fold' flag")
    }
}
