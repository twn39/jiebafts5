// JiebaEngine.swift
// JiebaFTS5
//
// Global singleton that owns the cppjieba segmentation engine.
//
// ## Architecture: two-layer separation
//
// GRDB creates one FTS5CustomTokenizer per database connection.  A DatabasePool
// with the default 5 readers + 1 writer would create 6 tokenizer instances.
// Each cppjieba instance builds its own Trie tree (~20-30 MB) on top of
// the shared dictionary data.  On iOS, 6 × 25 MB ≈ 150 MB is unacceptable.
//
// The solution: one global JiebaEngine (heavyweight) shared by all lightweight
// JiebaTokenizer instances (one per connection).
//
// ## Thread safety
//
// `static let` is initialised exactly once across all threads, equivalent to
// a dispatch_once.  After initialisation, JiebaEngine calls only jieba_cut /
// jieba_cut_for_search, which map to cppjieba `const` methods that perform no
// writes.  Concurrent reads are therefore safe without any additional locking.
//
// `@unchecked Sendable` is justified:
//   - `handle` is written once in `init()`, before any concurrent access.
//   - All post-init C calls are read-only (const cppjieba segmenters).

import CJiebaWrapper
import Foundation

// MARK: - JiebaEngine

/// Wraps the cppjieba segmentation engine as a process-lifetime global singleton.
final class JiebaEngine: @unchecked Sendable {

    // MARK: Singleton

    /// The shared engine, lazily initialised on first access.
    ///
    /// `static let` guarantees thread-safe, once-only initialisation with no
    /// manual locking.  The closure executes the first time any code accesses
    /// `JiebaEngine.shared` — typically during the first FTS5 tokenizer
    /// instantiation inside `Configuration.prepareDatabase`.
    static let shared: JiebaEngine = {
        let fm = FileManager.default

        guard
            let dictPath = Bundle.module.path(forResource: "jieba.dict", ofType: "utf8"),
            let hmmPath  = Bundle.module.path(forResource: "hmm_model", ofType: "utf8"),
            let userPath = Bundle.module.path(forResource: "user.dict", ofType: "utf8")
        else {
            // Missing bundled dictionaries is a programming error (bad SPM
            // resources configuration).  Crash early so it is caught during
            // development rather than silently producing empty search results.
            fatalError(
                "[JiebaFTS5] Dictionary files not found in module Bundle.\n" +
                "Ensure jieba.dict.utf8, hmm_model.utf8, and user.dict.utf8\n" +
                "are listed under `resources:` in Package.swift and that\n" +
                "`swift build` has been run to regenerate the bundle.\n" +
                "Bundle path: \(Bundle.module.bundlePath)"
            )
        }
        return JiebaEngine(dictPath: dictPath, hmmPath: hmmPath, userDictPath: userPath)
    }()

    // MARK: State

    /// Opaque C handle to the underlying JiebaSegmenter (MixSegment + QuerySegment).
    let handle: JiebaHandle

    // MARK: Init / deinit

    private init(dictPath: String, hmmPath: String, userDictPath: String) {
        // Pre-flight check: emit a targeted diagnostic before calling into C++,
        // so the crash message names the exact missing file rather than just
        // "jieba_create returned NULL".
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: dictPath) { missing.append("  • dict: \(dictPath)") }
        if !fm.fileExists(atPath: hmmPath) { missing.append("  • hmm:  \(hmmPath)") }
        if !fm.fileExists(atPath: userDictPath) { missing.append("  • user: \(userDictPath)") }

        if !missing.isEmpty {
            fatalError(
                "[JiebaFTS5] Dictionary file(s) exist in Bundle.module paths but " +
                "are not readable by FileManager:\n" +
                missing.joined(separator: "\n") + "\n" +
                "Check file permissions and that the SPM build succeeded."
            )
        }

        guard let h = jieba_create(dictPath, hmmPath, userDictPath) else {
            fatalError(
                "[JiebaFTS5] jieba_create() returned NULL.\n" +
                "Files were found but the C++ engine rejected them.\n" +
                "  dict: \(dictPath)\n" +
                "  hmm:  \(hmmPath)\n" +
                "  user: \(userDictPath)\n" +
                "Verify that the files are valid, uncorrupted jieba dictionaries."
            )
        }
        handle = h
    }

    deinit {
        // Reached only in test teardown; the singleton lives for the process lifetime.
        jieba_free(handle)
    }

    // MARK: Segmentation

    /// Precise segmentation (MixSeg: MP + HMM). Used for **query** tokenization.
    ///
    /// - Important: Use `text.utf8.count` — not `strlen` — to pass the byte
    ///   length.  Swift `String` may contain embedded NUL characters (`U+0000`);
    ///   `strlen` would silently truncate the input at the first NUL.
    func cut(_ text: String) -> JiebaTokenList {
        let byteCount = text.utf8.count   // O(1) for native UTF-8 storage (Swift 5.7+)
        return text.withCString { ptr in
            jieba_cut(handle, ptr, byteCount)
        }
    }

    /// Search-engine segmentation (QuerySeg: MixSeg + shorter sub-words).
    /// Used for **document** tokenization to maximise recall.
    func cutForSearch(_ text: String) -> JiebaTokenList {
        let byteCount = text.utf8.count
        return text.withCString { ptr in
            jieba_cut_for_search(handle, ptr, byteCount)
        }
    }

    // MARK: Warm-up

    /// Pre-warms the shared engine on a background thread.
    ///
    /// The first access to `JiebaEngine.shared` loads ~5 MB of dictionary data
    /// and constructs a Trie (~25 MB), taking 100–300 ms.  Call this at app
    /// launch to ensure the first user search does not incur that latency.
    ///
    /// ```swift
    /// func applicationDidFinishLaunching(_ application: UIApplication) -> Bool {
    ///     JiebaEngine.preheat()
    ///     return true
    /// }
    /// ```
    static func preheat() {
        // Task.detached avoids inheriting the caller's actor context, ensuring
        // the dictionary load runs on the cooperative thread pool, not the main actor.
        Task.detached(priority: .utility) { _ = JiebaEngine.shared }
    }
}
