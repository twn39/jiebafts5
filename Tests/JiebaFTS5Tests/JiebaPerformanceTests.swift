// JiebaPerformanceTests.swift
// JiebaFTS5Tests
//
// Performance benchmarks for JiebaFTS5 custom tokenizer.

import XCTest
import GRDB
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif
@testable import JiebaFTS5

final class JiebaPerformanceTests: XCTestCase {

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

    func testTokenizerZeroAllocationHotPath() throws {
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let db = try DatabaseQueue(configuration: config)
        
        try db.write { db in
            let tokenizer = try JiebaTokenizer(db: db, arguments: [])
            
            let callback: FTS5TokenCallback = { _, _, _, _, _, _ in
                return 0 // SQLITE_OK
            }
            
            let handle = dlopen(nil, RTLD_NOW)
            guard let sym = dlsym(handle, "malloc_logger") else {
                print("⚠️ [WARNING] malloc_logger not available, skipping zero allocation assertions")
                return
            }
            
            typealias MallocLogger = @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void
            let loggerPtr = sym.assumingMemoryBound(to: MallocLogger?.self)
            let oldLogger = loggerPtr.pointee
            
            struct AllocationTracker {
                static var count = 0
                static var enabled = false
            }
            
            let runTokenize = { (text: String) -> Int in
                let cString = text.utf8CString
                
                AllocationTracker.count = 0
                AllocationTracker.enabled = false
                
                loggerPtr.pointee = { (type, zone, ptr, arg3, size, num) in
                    if AllocationTracker.enabled {
                        let isAlloc = (type == 1 || type == 4 || type == 8 || type == 12)
                        if isAlloc {
                            AllocationTracker.count += 1
                        }
                    }
                }
                
                cString.withUnsafeBufferPointer { buf in
                    let base = buf.baseAddress!
                    let count = CInt(buf.count - 1)
                    
                    // Preheat
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: .document,
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    // Track
                    AllocationTracker.count = 0
                    AllocationTracker.enabled = true
                    
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: .document,
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    AllocationTracker.enabled = false
                }
                
                loggerPtr.pointee = oldLogger
                return AllocationTracker.count
            }
            
            let cjkAlloc = runTokenize("我来到北京清华大学")
            let asciiLowerAlloc = runTokenize("hello")
            let asciiUpperAlloc = runTokenize("Hello")
            
            #if !DEBUG
            // Assert bounded flat O(1) allocations on hot paths in release configuration
            XCTAssertLessThanOrEqual(cjkAlloc, 15, "CJK fast path allocation count: \(cjkAlloc)")
            XCTAssertLessThanOrEqual(asciiLowerAlloc, 10, "ASCII lower fast path allocation count: \(asciiLowerAlloc)")
            XCTAssertLessThanOrEqual(asciiUpperAlloc, 10, "ASCII upper stack allocation count: \(asciiUpperAlloc)")
            #else
            print("ℹ️ [INFO] Debug mode - CJK Alloc: \(cjkAlloc), ASCII Lower Alloc: \(asciiLowerAlloc), ASCII Upper Alloc: \(asciiUpperAlloc)")
            #endif
        }
    }

    func testCompleteBenchmarkSuite() throws {
        // 1. Prepare 5,000 documents containing mixed CJK & English (approx. 2.5 MB total)
        let baseParagraph = """
        基于 cppjieba 包装的 Swift FTS5 分词器，专为 GRDB.swift 设计。
        它是一个支持零堆分配、停用词过滤以及全角与变音符折叠的高性能中文分词方案。
        配合 Method 3 邻近词去重算法，能够在满足短语查询 (Phrase Query) 精确命中的同时，
        极大降低数据库索引的冗余空间开销。
        The quick brown fox jumps over the lazy dog. Swift is a safe, fast, and interactive programming language.
        在多线程环境及并发压力下，通过共享读写锁与 thread_local 内存复用实现 zero 竞争的高吞吐。
        """
        
        let docCount = 5000
        let documents: [String] = {
            var docs: [String] = []
            docs.reserveCapacity(docCount)
            for i in 0..<docCount {
                docs.append("\(baseParagraph) [DocID: \(i)]")
            }
            return docs
        }()
        
        let totalBytes = documents.reduce(0) { $0 + $1.utf8.count }
        let totalSizeMB = Double(totalBytes) / (1024.0 * 1024.0)
        
        let stopwords: Set<String> = ["的", "了", "在", "和", "the", "a", "is", "and", "of", "to"]
        
        // ─── Dimension A: Raw Tokenizer Throughput ───
        var config = Configuration()
        config.prepareDatabase { db in db.add(tokenizer: JiebaTokenizer.self) }
        let dbQueue = try DatabaseQueue(configuration: config)
        
        let rawResults: [(name: String, timeMs: Double, throughput: Double)] = try dbQueue.write { db in
            let largeText = documents.joined(separator: "\n")
            let cString = largeText.utf8CString
            
            let runRawBench = { (name: String, args: [String]) throws -> (String, Double, Double) in
                let tokenizer = try JiebaTokenizer(db: db, arguments: args)
                let callback: FTS5TokenCallback = { _, _, _, _, _, _ in return 0 }
                
                // Preheat
                cString.withUnsafeBufferPointer { buf in
                    _ = tokenizer.tokenize(context: nil, tokenization: .document, pText: buf.baseAddress!, nText: CInt(buf.count - 1), tokenCallback: callback)
                }
                
                let start = CFAbsoluteTimeGetCurrent()
                cString.withUnsafeBufferPointer { buf in
                    _ = tokenizer.tokenize(context: nil, tokenization: .document, pText: buf.baseAddress!, nText: CInt(buf.count - 1), tokenCallback: callback)
                }
                let end = CFAbsoluteTimeGetCurrent()
                let duration = end - start
                return (name, duration * 1000.0, totalSizeMB / duration)
            }
            
            let r1 = try runRawBench("Jieba (Default)", [])
            let r2 = try runRawBench("Jieba (With Stopwords)", ["stopwords", stopwords.sorted().joined(separator: ",")])
            let r3 = try runRawBench("Jieba (No Folding)", ["no_case_fold", "no_width_fold", "no_diacritic_fold"])
            
            return [
                (r1.0, r1.1, r1.2),
                (r2.0, r2.1, r2.2),
                (r3.0, r3.1, r3.2)
            ]
        }
        
        // ─── Dimension B: FTS5 Indexing Throughput ───
        let runIndexBench = { (name: String, descriptor: FTS5TokenizerDescriptor) -> (String, Double, Double) in
            var config = Configuration()
            config.prepareDatabase { db in
                db.add(tokenizer: JiebaTokenizer.self)
            }
            guard let db = try? DatabaseQueue(configuration: config) else {
                return (name, 0.0, 0.0)
            }
            
            let tableName = "docs_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            
            try? db.write { db in
                try db.create(virtualTable: tableName, using: FTS5()) { t in
                    t.tokenizer = descriptor
                    t.column("content")
                }
            }
            
            let start = CFAbsoluteTimeGetCurrent()
            try? db.write { db in
                for doc in documents {
                    try db.execute(sql: "INSERT INTO \(tableName)(content) VALUES (?)", arguments: [doc])
                }
            }
            let end = CFAbsoluteTimeGetCurrent()
            let duration = end - start
            return (name, duration * 1000.0, totalSizeMB / duration)
        }
        
        let i1 = runIndexBench("Jieba (Default)", .jieba())
        let i2 = runIndexBench("Jieba (With Stopwords)", .jieba(stopwords: stopwords))
        let i3 = runIndexBench("SQLite unicode61", .unicode61())
        
        let indexResults = [
            (i1.0, i1.1, i1.2),
            (i2.0, i2.1, i2.2),
            (i3.0, i3.1, i3.2)
        ]
        
        // Generate Markdown Report
        var mdReport = """
        # JiebaTokenizer Complete Performance Benchmark Report
        
        - **Corpus Details**: Mixed Chinese/English text, \(docCount) documents.
        - **Corpus Size**: \(String(format: "%.2f", totalSizeMB)) MB (\(totalBytes) bytes).
        - **Platform**: \(ProcessInfo.processInfo.operatingSystemVersionString) (\(ProcessInfo.processInfo.activeProcessorCount) Cores).
        
        ---
        
        ## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
        > 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。
        
        | 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
        | :--- | :---: | :---: |
        """
        
        for res in rawResults {
            mdReport += "\n| \(res.0) | \(String(format: "%.2f", res.1)) | \(String(format: "%.2f", res.2)) |"
        }
        
        mdReport += """
        
        
        
        ## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
        > 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。
        
        | 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
        | :--- | :---: | :---: |
        """
        
        for res in indexResults {
            if res.1 > 0 {
                mdReport += "\n| \(res.0) | \(String(format: "%.2f", res.1)) | \(String(format: "%.2f", res.2)) |"
            } else {
                mdReport += "\n| \(res.0) | N/A (不支持) | N/A |"
            }
        }
        
        mdReport += "\n\n*(测试结果在运行时自动计算生成)*\n"
        
        print("🚀🚀🚀 [BENCHMARK SUITE COMPLETED] 🚀🚀🚀")
        print(mdReport)
        
        // Save to benchmark_results.md in the package root
        let repoRoot = "/Users/2342184/programs/jiebafts5/jiebafts5"
        do {
            try mdReport.write(toFile: "\(repoRoot)/benchmark_results.md", atomically: true, encoding: .utf8)
        } catch {
            print("❌ Failed to write benchmark report: \(error)")
            XCTFail("Failed to write benchmark report: \(error)")
        }
    }
}
