// JiebaTokenGoldenTests.swift
// Golden token lists for document / query modes (behavioral lock-in).

import XCTest
@testable import JiebaFTS5

final class JiebaTokenGoldenTests: XCTestCase {

    func testQueryModeNoColocatedOnCompound() throws {
        let tok = try makeTokenizer()
        let pairs = try tok.tokenize(query: "清华大学")
        XCTAssertFalse(pairs.contains { $0.flags.contains(.colocated) })
        let tokens = pairs.map(\.token)
        XCTAssertTrue(tokens.contains("清华大学") || tokens.contains("清华"), "MixSeg should emit compound or parts")
    }

    func testDocumentModeHasColocatedSubwords() throws {
        let tok = try makeTokenizer()
        let pairs = try tok.tokenize(document: "清华大学")
        XCTAssertTrue(pairs.contains { $0.flags.contains(.colocated) }, "QuerySeg document path should emit COLOCATED")
    }

    func testCaseFoldGolden() throws {
        let tok = try makeTokenizer(caseFolding: true)
        let tokens = try tok.tokenize(document: "Hello GRDB").map(\.token)
        XCTAssertTrue(tokens.contains("hello"))
        XCTAssertTrue(tokens.contains("grdb"))
        XCTAssertFalse(tokens.contains("GRDB"))
    }

    func testRecommendedStopwordsDropThe() throws {
        let tok = try makeTokenizer(options: .recommended)
        let tokens = try tok.tokenize(document: "the quick 的 苹果").map(\.token)
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("的"))
        // "quick" / "苹果" should remain (segmentation-dependent for 苹果)
        XCTAssertTrue(tokens.contains("quick") || tokens.contains("苹果") || tokens.contains("苹"))
    }

    func testStrictMatchPreservesCase() throws {
        let tok = try makeTokenizer(options: .strictMatch)
        let tokens = try tok.tokenize(document: "Hello").map(\.token)
        // Under strict match, uppercase must not be forced to lower.
        XCTAssertTrue(tokens.contains("Hello"))
        XCTAssertFalse(tokens.contains("hello"))
    }
}
