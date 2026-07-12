// JiebaEngine.swift
// JiebaFTS5
//
// Global shared engine managing the cppjieba lifecycle.
// Supports dynamic configuration, explicit shutdown, and thread-safe dynamic inserts.
//
// Contract: docs/ENGINE_LIFECYCLE.md

import CJiebaWrapper
import Foundation

// MARK: - JiebaEngine

/// Wraps the cppjieba segmentation engine as a process-lifetime global singleton
/// with configurable lifecycle and runtime dictionary mutation.
///
/// Thread-safety of segmentation / insert is provided by C++ `std::shared_mutex`
/// inside `CJiebaWrapper`; hence `@unchecked Sendable`.
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
            guard
                let dict = Bundle.module.path(forResource: "jieba.dict", ofType: "utf8"),
                let hmm = Bundle.module.path(forResource: "hmm_model", ofType: "utf8"),
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

        let instance = JiebaEngine(
            dictPath: paths.dictPath,
            hmmPath: paths.hmmPath,
            userDictPath: paths.userDictPath
        )
        _shared = instance
        return instance
    }

    // MARK: Config / Lifecycle APIs

    /// Configures dictionary paths. Must be called **before** the shared engine is first accessed.
    ///
    /// - Returns: `true` if paths were stored; `false` if the engine was already initialized
    ///   (configuration ignored; see `docs/ENGINE_LIFECYCLE.md`).
    @discardableResult
    public static func configure(dictPath: String, hmmPath: String, userDictPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard _shared == nil else {
            NSLog("[JiebaFTS5] Warning: JiebaEngine has already been initialized. Configuration ignored.")
            return false
        }
        customConfig = (dictPath, hmmPath, userDictPath)
        return true
    }

    /// Whether the shared engine has been created (not yet shut down).
    public static var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _shared != nil
    }

    /// Shuts down the current engine and releases its dictionary memory.
    /// Subsequent calls to `JiebaEngine.shared` reinitialize using the last `configure` paths
    /// (if any) or bundle defaults.
    public static func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil
    }

    // MARK: Instance State

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

    /// Precise segmentation (MixSeg) — used for FTS5 **query** mode.
    func cut(
        _ pText: UnsafePointer<CChar>,
        count: Int,
        context: UnsafeMutableRawPointer,
        callback: JiebaTokenEmitCallback
    ) -> Int32 {
        jieba_cut(handle, pText, count, context, callback)
    }

    /// Search-engine segmentation (QuerySeg) — used for FTS5 **document** mode.
    func cutForSearch(
        _ pText: UnsafePointer<CChar>,
        count: Int,
        context: UnsafeMutableRawPointer,
        callback: JiebaTokenEmitCallback
    ) -> Int32 {
        jieba_cut_for_search(handle, pText, count, context, callback)
    }

    // MARK: Dynamic Dictionary

    /// Dynamically inserts a word into the dictionary at runtime.
    /// Thread-safe via internal C++ read-write locks.
    /// - Returns: `true` on success, `false` on failure (null handle / empty / C++ error).
    @discardableResult
    public func insertUserWord(_ word: String) -> Bool {
        word.withCString { ptr in
            jieba_insert_user_word(handle, ptr) != 0
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
