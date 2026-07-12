// JiebaTokenizerIndexTests.swift
// JiebaFTS5Tests
//
// Sections 9-14: index maintenance, concurrency, singleton, AUX, options.

import GRDB
import XCTest
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif
@testable import JiebaFTS5

// MARK: - 9. Update & Delete (Index Maintenance)

final class JiebaTokenizerIndexTests: XCTestCase {

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
}

// MARK: - 10. Multiple Documents & Ranking

extension JiebaTokenizerIndexTests {

    func testMultipleDocumentsSelectivity() throws {
        let db = try makeDB()
        try insert("北京清华大学", into: db)
        try insert("上海交通大学", into: db)
        try insert("浙江大学", into: db)
        XCTAssertEqual(try count(query: "大学", in: db), 3)
        XCTAssertEqual(try count(query: "清华大学", in: db), 1)
        XCTAssertEqual(try count(query: "北京", in: db), 1)
    }
}

// MARK: - 11. Concurrency (Thread Safety)

extension JiebaTokenizerIndexTests {

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
}

// MARK: - 12. Singleton Sharing

extension JiebaTokenizerIndexTests {

    func testEngineIsShared() throws {
        let db1 = try makeDB()
        let db2 = try makeDB()
        try insert("人工智能", into: db1)
        try insert("机器学习", into: db2)
        XCTAssertEqual(try self.count(query: "人工智能", in: db1), 1)
        XCTAssertEqual(try self.count(query: "机器学习", in: db2), 1)
        XCTAssertEqual(try self.count(query: "机器学习", in: db1), 0, "db1 不含 db2 的内容")
    }
}

// MARK: - 13. AUX Tokenization (snippet / highlight)

extension JiebaTokenizerIndexTests {

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
}

// MARK: - 14. JiebaTokenizerOptions

extension JiebaTokenizerIndexTests {

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

// MARK: - 15. Lifecycle Management & Custom Configuration

extension JiebaTokenizerIndexTests {
    func testEngineConfigureAndShutdown() throws {
        JiebaEngine.shutdown()

        guard
            let dictPath = Bundle.module.path(forResource: "jieba.dict", ofType: "utf8"),
            let hmmPath  = Bundle.module.path(forResource: "hmm_model", ofType: "utf8"),
            let userPath = Bundle.module.path(forResource: "user.dict", ofType: "utf8")
        else {
            XCTFail("Default dictionary files not found")
            return
        }

        JiebaEngine.configure(dictPath: dictPath, hmmPath: hmmPath, userDictPath: userPath)

        let db = try makeDB()
        try insert("人工智能很强大", into: db)
        XCTAssertEqual(try self.count(query: "人工智能", in: db), 1)

        JiebaEngine.shutdown()
    }
}

// MARK: - 16. Dynamic User Dictionary

extension JiebaTokenizerIndexTests {
    func testDynamicUserWordInsertion() throws {
        let tok = try makeTokenizer(caseFolding: true)

        let rawTokensBefore = try tok.tokenize(query: "男默女泪")
        XCTAssertFalse(rawTokensBefore.map { $0.token }.contains("男默女泪"), "Before insert, '男默女泪' should not be a single word")

        JiebaEngine.shared.insertUserWord("男默女泪")

        let rawTokensAfter = try tok.tokenize(query: "男默女泪")
        XCTAssertTrue(rawTokensAfter.map { $0.token }.contains("男默女泪"), "After insert, '男默女泪' must be identified as a single word")

        JiebaEngine.shutdown()
    }
}

// MARK: - 17. Stopwords & Unicode Folding

extension JiebaTokenizerIndexTests {
    func testStopwordsFiltering() throws {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = .jieba(stopwords: ["的", "和"])
                t.column("content")
            }
        }

        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: ["苹果和香蕉的秘密"])
        }

        XCTAssertEqual(try self.count(query: "苹果", in: db), 1)
        XCTAssertEqual(try self.count(query: "和", in: db), 0, "Stopword '和' should be filtered out")
    }

    func testWidthAndDiacriticFolding() throws {
        let tok = try makeTokenizer(caseFolding: true)
        let tokens = try tok.tokenize(document: "Ａｐｐｌｅ café")
        print("DEBUG TOKENS: \(tokens.map { $0.token })")

        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = .jieba(caseFolding: true, widthFolding: true, diacriticFolding: true)
                t.column("content")
            }
        }

        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: ["Ａｐｐｌｅ café"])
        }

        XCTAssertEqual(try self.count(query: "a", in: db), 1, "Single full-width 'Ａ' folded to 'a' should match query 'a'")
        XCTAssertEqual(try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH '\"caf\" \"e\"'") ?? 0
        }, 1, "Diacritic 'café' split into 'caf' and 'e' should match phrase query")
    }
}
