// JiebaFTS5TestSupport.swift
// Shared fixtures for JiebaFTS5Tests.

import GRDB
import XCTest
@testable import JiebaFTS5

enum JiebaFTS5TestSupport {

    /// In-memory DatabaseQueue with `JiebaTokenizer` registered and a single `docs` FTS5 table.
    static func makeDB(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil,
        options: JiebaTokenizerOptions? = nil
    ) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                if let options {
                    t.tokenizer = .jieba(options: options)
                } else {
                    t.tokenizer = .jieba(
                        caseFolding: caseFolding,
                        widthFolding: widthFolding,
                        diacriticFolding: diacriticFolding,
                        stopwords: stopwords
                    )
                }
                t.column("content")
            }
        }
        return db
    }

    /// Raw tokenizer instance (not backed by an FTS5 index table).
    static func makeTokenizer(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil,
        options: JiebaTokenizerOptions? = nil
    ) throws -> any FTS5Tokenizer {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        let descriptor: FTS5TokenizerDescriptor
        if let options {
            descriptor = .jieba(options: options)
        } else {
            descriptor = .jieba(
                caseFolding: caseFolding,
                widthFolding: widthFolding,
                diacriticFolding: diacriticFolding,
                stopwords: stopwords
            )
        }
        return try db.read { db in
            try db.makeTokenizer(descriptor)
        }
    }

    static func insert(_ text: String, into db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: [text])
        }
    }

    static func count(query: String, in db: DatabaseQueue) throws -> Int {
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
}

// Convenience for XCTestCase subclasses.
extension XCTestCase {
    func makeDB(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil,
        options: JiebaTokenizerOptions? = nil
    ) throws -> DatabaseQueue {
        try JiebaFTS5TestSupport.makeDB(
            caseFolding: caseFolding,
            widthFolding: widthFolding,
            diacriticFolding: diacriticFolding,
            stopwords: stopwords,
            options: options
        )
    }

    func makeTokenizer(
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil,
        options: JiebaTokenizerOptions? = nil
    ) throws -> any FTS5Tokenizer {
        try JiebaFTS5TestSupport.makeTokenizer(
            caseFolding: caseFolding,
            widthFolding: widthFolding,
            diacriticFolding: diacriticFolding,
            stopwords: stopwords,
            options: options
        )
    }

    func insert(_ text: String, into db: DatabaseQueue) throws {
        try JiebaFTS5TestSupport.insert(text, into: db)
    }

    func count(query: String, in db: DatabaseQueue) throws -> Int {
        try JiebaFTS5TestSupport.count(query: query, in: db)
    }
}
