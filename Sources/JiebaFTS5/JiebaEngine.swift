// JiebaEngine.swift
// JiebaFTS5
//
// Global shared engine managing the cppjieba lifecycle.
// Supports named engine registry, explicit shutdown, and thread-safe dynamic inserts.
//
// Contract: docs/ENGINE_LIFECYCLE.md

import CJiebaWrapper
import Foundation

// MARK: - Errors

/// Recoverable engine creation / bootstrap failures.
public enum JiebaEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Bundle.module is missing one or more default dictionary resources.
    case missingBundleResources
    /// One or more dictionary paths do not exist on disk.
    case missingDictionaryFiles([String])
    /// `jieba_create` returned NULL (bad format / allocation failure).
    case createFailed(dictPath: String, hmmPath: String, userDictPath: String)
    /// FTS5 / tokenizer requested a name that is not in the registry.
    case unknownEngineName(String)

    public var description: String {
        switch self {
        case .missingBundleResources:
            return "[JiebaFTS5] Default dictionary files not found in Bundle.module. " +
                "Call JiebaEngine.configure(...) before accessing the database, or use JiebaEngine.make(...)."
        case .missingDictionaryFiles(let paths):
            return "[JiebaFTS5] Dictionary file(s) not readable:\n" + paths.joined(separator: "\n")
        case .createFailed(let dict, let hmm, let user):
            return "[JiebaFTS5] jieba_create() returned NULL. Verify file format:\n" +
                "  dict: \(dict)\n  hmm:  \(hmm)\n  user: \(user)"
        case .unknownEngineName(let name):
            return "[JiebaFTS5] Unknown engine name \"\(name)\". " +
                "Register with JiebaEngine.register(name:engine:) before opening the database."
        }
    }
}

// MARK: - JiebaEngine

/// Wraps the cppjieba segmentation engine with process-level lifecycle and optional named instances.
///
/// Thread-safety of segmentation / insert is provided by C++ `std::shared_mutex`
/// inside `CJiebaWrapper`; hence `@unchecked Sendable`.
///
/// Prefer `bootstrap()` when you need to handle load failures without aborting the process.
/// `shared` remains available and still `fatalError`s on unrecoverable setup for FTS5 convenience.
///
/// Multi-dictionary apps can `make` + `register(name:engine:)` and pass `engineName` in
/// ``JiebaTokenizerOptions`` so each FTS5 table binds a different engine.
public final class JiebaEngine: @unchecked Sendable {

    // MARK: Config State

    private static var customConfig: (dictPath: String, hmmPath: String, userDictPath: String)?
    private static let lock = NSLock()
    private static var _shared: JiebaEngine?
    private static var registry: [String: JiebaEngine] = [:]

    // MARK: Singleton Access

    /// The shared engine instance.
    /// Accessing this triggers initialization with either custom paths (if configured)
    /// or fallback bundle paths.
    ///
    /// On failure this still calls `fatalError` (stable FTS5 behavior). Use `bootstrap()` to handle errors.
    public static var shared: JiebaEngine {
        do {
            return try bootstrap()
        } catch {
            fatalError(String(describing: error))
        }
    }

    /// Lazily creates the shared engine, or returns the existing one.
    ///
    /// - Throws: ``JiebaEngineError`` when dictionaries are missing or `jieba_create` fails.
    @discardableResult
    public static func bootstrap() throws -> JiebaEngine {
        lock.lock()
        defer { lock.unlock() }

        if let instance = _shared {
            return instance
        }

        let paths = try resolvePathsLocked()
        let instance = try JiebaEngine(
            dictPath: paths.dictPath,
            hmmPath: paths.hmmPath,
            userDictPath: paths.userDictPath
        )
        _shared = instance
        return instance
    }

    /// Creates a **standalone** engine that is not installed as `shared`.
    ///
    /// Register it with ``register(name:engine:)`` to use from FTS5 via
    /// `JiebaTokenizerOptions.engineName`, or pass to `JiebaTokenizer(engine:options:)`.
    public static func make(
        dictPath: String,
        hmmPath: String,
        userDictPath: String
    ) throws -> JiebaEngine {
        try JiebaEngine(dictPath: dictPath, hmmPath: hmmPath, userDictPath: userDictPath)
    }

    /// Absolute paths to the dictionaries bundled in `Bundle.module`, if present.
    public static var bundledDictionaryPaths: (dictPath: String, hmmPath: String, userDictPath: String)? {
        guard
            let dict = Bundle.module.path(forResource: "jieba.dict", ofType: "utf8"),
            let hmm = Bundle.module.path(forResource: "hmm_model", ofType: "utf8"),
            let user = Bundle.module.path(forResource: "user.dict", ofType: "utf8")
        else {
            return nil
        }
        return (dict, hmm, user)
    }

    // MARK: Named engine registry

    /// Registers `engine` under `name` for FTS5 resolution (`options.engineName`).
    ///
    /// - Note: Names `"shared"` and `"default"` are reserved for the process singleton.
    /// - Returns: `false` if `name` is empty or reserved.
    @discardableResult
    public static func register(name: String, engine: JiebaEngine) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "shared", key != "default" else {
            NSLog("[JiebaFTS5] Warning: invalid engine name \"\(name)\"; registration ignored.")
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        registry[key] = engine
        return true
    }

    /// Removes a previously registered named engine (does not shut down `shared`).
    public static func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        registry.removeValue(forKey: name)
    }

    /// Resolves an engine by name. `"shared"` / `"default"` / empty → ``shared`` via bootstrap.
    public static func resolve(name: String?) throws -> JiebaEngine {
        let key = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty || key == "shared" || key == "default" {
            return try bootstrap()
        }
        lock.lock()
        let eng = registry[key]
        lock.unlock()
        guard let eng else {
            throw JiebaEngineError.unknownEngineName(key)
        }
        return eng
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

    /// Shuts down the current **shared** engine and releases its dictionary memory.
    /// Does **not** clear the named registry — call ``unregister(name:)`` as needed.
    /// Subsequent calls to `JiebaEngine.shared` / `bootstrap()` reinitialize using the last
    /// `configure` paths (if any) or bundle defaults.
    public static func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil
    }

    // MARK: Instance State

    private let handle: JiebaHandle

    // MARK: Init / Deinit

    private init(dictPath: String, hmmPath: String, userDictPath: String) throws {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: dictPath) { missing.append("  • dict: \(dictPath)") }
        if !fm.fileExists(atPath: hmmPath) { missing.append("  • hmm:  \(hmmPath)") }
        if !fm.fileExists(atPath: userDictPath) { missing.append("  • user: \(userDictPath)") }

        if !missing.isEmpty {
            throw JiebaEngineError.missingDictionaryFiles(missing)
        }

        guard let h = jieba_create(dictPath, hmmPath, userDictPath) else {
            throw JiebaEngineError.createFailed(
                dictPath: dictPath,
                hmmPath: hmmPath,
                userDictPath: userDictPath
            )
        }
        handle = h
    }

    deinit {
        jieba_free(handle)
    }

    // MARK: - Path resolution (caller must hold `lock`)

    private static func resolvePathsLocked() throws -> (dictPath: String, hmmPath: String, userDictPath: String) {
        if let custom = customConfig {
            return custom
        }
        guard let bundled = bundledDictionaryPaths else {
            throw JiebaEngineError.missingBundleResources
        }
        return bundled
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
    ///
    /// - Important: Does **not** rebuild existing FTS5 indexes. Only subsequent
    ///   document/query tokenization sees the new term. Re-index rows if needed.
    /// - Returns: `true` on success, `false` on failure (null handle / empty / C++ error).
    @discardableResult
    public func insertUserWord(_ word: String) -> Bool {
        word.withCString { ptr in
            jieba_insert_user_word(handle, ptr) != 0
        }
    }

    /// Inserts multiple user words under a **single** C++ write lock.
    ///
    /// Same re-index caveat as ``insertUserWord(_:)``.
    /// - Returns: Number of successful inserts.
    @discardableResult
    public func insertUserWords(_ words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }

        var storage: [UnsafeMutablePointer<CChar>] = []
        storage.reserveCapacity(words.count)
        defer {
            for p in storage {
                free(p)
            }
        }
        for w in words {
            guard let p = strdup(w) else { continue }
            storage.append(p)
        }
        guard !storage.isEmpty else { return 0 }

        let cPtrs: [UnsafePointer<CChar>?] = storage.map { UnsafePointer($0) }
        return cPtrs.withUnsafeBufferPointer { buf in
            Int(jieba_insert_user_words(handle, buf.baseAddress, buf.count))
        }
    }

    /// Inserts words from any sequence (copies to array for the batch C API).
    @discardableResult
    public func insertUserWords<S: Sequence>(_ words: S) -> Int where S.Element == String {
        insertUserWords(Array(words))
    }

    // MARK: Preheat

    /// Pre-warms the shared engine on a background thread.
    public static func preheat() {
        Task.detached(priority: .utility) {
            _ = try? JiebaEngine.bootstrap()
        }
    }
}
