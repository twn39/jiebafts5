// JiebaEngine.swift
// JiebaFTS5
//
// Global shared engine managing the cppjieba lifecycle.
// Supports dynamic configuration, explicit shutdown, and thread-safe dynamic inserts.

import CJiebaWrapper
import Foundation

// MARK: - JiebaEngine

/// Wraps the cppjieba segmentation engine as a process-lifetime global singleton
/// with configurable lifecycle and runtime dictionary mutation.
public final class JiebaEngine: @unchecked Sendable {

    // MARK: Config State

    private static var customConfig: (dictPath: String, hmmPath: String, userDictPath: String)?
    private static let lock = NSLock()
    private static var _shared: JiebaEngine?

    // MARK: Singleton Access

    /// The shared engine instance.
    /// Accessing this triggers initialization with either custom paths (if configured)
    /// or fallback bundle paths.
    public static var shared: JiebaEngine {
        lock.lock()
        defer { lock.unlock() }

        if let instance = _shared {
            return instance
        }

        let paths: (dictPath: String, hmmPath: String, userDictPath: String)
        if let custom = customConfig {
            paths = custom
        } else {
            // Default to Bundle resources
            guard
                let dict = Bundle.module.path(forResource: "jieba.dict", ofType: "utf8"),
                let hmm  = Bundle.module.path(forResource: "hmm_model", ofType: "utf8"),
                let user = Bundle.module.path(forResource: "user.dict", ofType: "utf8")
            else {
                fatalError(
                    "[JiebaFTS5] Default dictionary files not found in Bundle.module.\n" +
                    "If you are running in a custom environment, call JiebaEngine.configure(...) " +
                    "before accessing the database."
                )
            }
            paths = (dict, hmm, user)
        }

        let instance = JiebaEngine(dictPath: paths.dictPath, hmmPath: paths.hmmPath, userDictPath: paths.userDictPath)
        _shared = instance
        return instance
    }

    // MARK: Config / Lifecycle APIs

    /// Configures the engine paths. Must be called BEFORE the database is initialized
    /// or the shared engine is accessed.
    ///
    /// - Parameters:
    ///   - dictPath: Absolute path to the main dict.
    ///   - hmmPath: Absolute path to the HMM model.
    ///   - userDictPath: Absolute path to the user dictionary.
    public static func configure(dictPath: String, hmmPath: String, userDictPath: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard _shared == nil else {
            NSLog("[JiebaFTS5] Warning: JiebaEngine has already been initialized. Configuration ignored.")
            return
        }
        customConfig = (dictPath, hmmPath, userDictPath)
    }

    /// Shuts down the current engine and releases its ~25 MB memory.
    /// Useful for iOS memory warnings, background suspension, or clean test teardown.
    /// Subsequent calls to `JiebaEngine.shared` will automatically reinitialize the engine.
    public static func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil // Triggers deinit & C free
    }

    // MARK: Instance State

    /// Opaque C handle to the underlying segmenter.
    private let handle: JiebaHandle

    // MARK: Init / Deinit

    private init(dictPath: String, hmmPath: String, userDictPath: String) {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: dictPath) { missing.append("  • dict: \(dictPath)") }
        if !fm.fileExists(atPath: hmmPath) { missing.append("  • hmm:  \(hmmPath)") }
        if !fm.fileExists(atPath: userDictPath) { missing.append("  • user: \(userDictPath)") }

        if !missing.isEmpty {
            fatalError(
                "[JiebaFTS5] Dictionary file(s) not readable at specified paths:\n" +
                missing.joined(separator: "\n")
            )
        }

        guard let h = jieba_create(dictPath, hmmPath, userDictPath) else {
            fatalError(
                "[JiebaFTS5] jieba_create() returned NULL. Verify file format:\n" +
                "  dict: \(dictPath)\n" +
                "  hmm:  \(hmmPath)\n" +
                "  user: \(userDictPath)"
            )
        }
        handle = h
    }

    deinit {
        jieba_free(handle)
    }

    // MARK: - Segmentation Wrappers

    /// Precise segmentation (MixSeg: MP + HMM) with zero-allocation callback pass-through.
    func cut(_ pText: UnsafePointer<CChar>, count: Int, context: UnsafeMutableRawPointer, callback: JiebaTokenEmitCallback) -> Int32 {
        return jieba_cut(handle, pText, count, context, callback)
    }

    /// Search-engine segmentation (QuerySeg) with zero-allocation callback pass-through.
    func cutForSearch(_ pText: UnsafePointer<CChar>, count: Int, context: UnsafeMutableRawPointer, callback: JiebaTokenEmitCallback) -> Int32 {
        return jieba_cut_for_search(handle, pText, count, context, callback)
    }

    // MARK: Dynamic Dictionary

    /// Dynamically inserts a word into the dictionary at runtime.
    /// Thread-safe via internal C++ read-write locks.
    public func insertUserWord(_ word: String) {
        word.withCString { ptr in
            jieba_insert_user_word(handle, ptr)
        }
    }

    // MARK: Preheat

    /// Pre-warms the shared engine on a background thread.
    public static func preheat() {
        Task.detached(priority: .utility) {
            _ = JiebaEngine.shared
        }
    }
}
