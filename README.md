# JiebaFTS5

A Swift Package that integrates [cppjieba](https://github.com/yanyiwu/cppjieba) with [GRDB](https://github.com/groue/GRDB.swift) as a custom FTS5 tokenizer, enabling high-performance, memory-efficient Chinese full-text search in SQLite on iOS and macOS.

## Features

- **Jieba Word Segmentation** — Accurate Chinese tokenization via cppjieba's MixSeg (MP + HMM) and QuerySeg algorithms.
- **COLOCATED Synonym Indexing** — Sub-words (e.g., `清华`, `大学`) are indexed alongside the full compound (`清华大学`), enabling partial-word search without false positives (FTS5 Method 3).
- **Zero-Allocation Token Emission** — Direct token output from SQLite's buffer without any heap allocations on hot paths (CJK characters and ASCII).
- **Unicode folding** — Fully customizable folding pipeline:
  - **Case Folding**: Converts ASCII & Unicode characters to lowercase.
  - **Width Folding**: Normalizes full-width alphanumeric characters (NFKC mapping).
  - **Diacritic Folding**: Strips accent marks (e.g., `café` -> `cafe`).
  - **CJK Block Fast Path**: Bypasses Foundation Unicode string folding for CJK unified ideographs (`U+4E00`-`U+9FFF`), keeping CJK tokenization entirely heap-allocation-free.
- **Stopwords Filtering** — High-performance flat byte buffer container with pointer-based, bounds-checking-free binary search for high-frequency stopword exclusion on hot paths.
- **Dynamic User Dictionary** — Safe thread-local runtime insertion of user dictionary terms (`insertUserWord(_:)`) protected by C++ `std::shared_mutex` to allow concurrent indexing and lookups without thread contention.
- **Preallocated Thread-Local Buffers** — C++ layer utilizes `thread_local` caching for std::string and std::vector to avoid allocation-contention and heap allocations during indexing loop iterations.

## Usage

### 1. Register the tokenizer

```swift
import GRDB
import JiebaFTS5

var config = Configuration()
config.addJiebaTokenizer()

let dbPool = try DatabasePool(path: path, configuration: config)
```

### 2. Create an FTS5 virtual table

```swift
try dbPool.write { db in
    try db.create(virtualTable: "articles", using: FTS5()) { t in
        // Default options: caseFolding: true, widthFolding: true, diacriticFolding: true, stopwords: nil
        t.tokenizer = .jieba()
        t.column("title")
        t.column("body")
    }
}
```

#### Profiles & custom options:
```swift
// Recommended: all folding + Chinese/English stopwords
t.tokenizer = .jieba(options: .recommended)

// Strict: no folding
t.tokenizer = .jieba(options: .strictMatch)

// Custom folding & stopwords
t.tokenizer = .jieba(
    caseFolding: true,
    widthFolding: true,
    diacriticFolding: true,
    stopwords: ["的", "了", "和", "the", "a"]
)
// or: stopwords: StopwordPresets.chinese
```

See [docs/TOKENIZATION_PROFILE.md](docs/TOKENIZATION_PROFILE.md) and [docs/ENGINE_LIFECYCLE.md](docs/ENGINE_LIFECYCLE.md).

### 3. Insert and search

```swift
// Insert
try dbPool.write { db in
    try db.execute(
        sql: "INSERT INTO articles (title, body) VALUES (?, ?)",
        arguments: ["清华大学", "清华大学是中国顶尖高校之一。"]
    )
}

// Search — matches "清华大学", "清华", "大学", "华大"
try dbPool.read { db in
    let pattern = FTS5Pattern(matchingPhrase: "清华")
    let rows = try Row.fetchAll(
        db,
        sql: "SELECT * FROM articles WHERE articles MATCH ?",
        arguments: [pattern]
    )
}
```

### 4. Dynamic User Dictionary Insertion

To insert custom vocabularies dynamically at runtime without restarting the engine:
```swift
let ok = JiebaEngine.shared.insertUserWord("男默女泪")
// ok == false if insertion failed
```
This operation is thread-safe and safely isolated under exclusive write locks.

### 5. Snippet highlighting

```swift
let sql = """
    SELECT snippet(articles, 0, '<<', '>>', '...', 10)
    FROM articles WHERE articles MATCH ?
    """
let snippet = try db.read { db in
    try String.fetchOne(db, sql: sql, arguments: [FTS5Pattern(matchingPhrase: "清华大学")])
}
// "<<清华大学>>是中国顶尖高校之一。"
```

### 6. Preheat on app launch

The engine takes 100–300 ms to initialise. Call `preheat()` at launch to avoid latency on the first search:

```swift
// SwiftUI
@main struct MyApp: App {
    init() { JiebaEngine.preheat() }
}

// UIKit
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    JiebaEngine.preheat()
    return true
}
```

---

## Performance & Benchmarks

The benchmarks below were measured by indexing a **2.82 MB** corpus consisting of 5,000 mixed CJK and English documents on a **macOS 10-core M-series processor** in Release mode (`-c release`).

### Raw Tokenizer Throughput (pure CPU segmentation)
*Measures direct calling of the custom tokenizer on CPU, excluding SQLite database IO.*

| Configuration | Time (ms) | Throughput (MB/s) |
| :--- | :---: | :---: |
| **Jieba (Default)** | 205.49 | **13.71** |
| **Jieba (With Stopwords)** | 185.78 | **15.16** |
| **Jieba (No Folding)** | 168.34 | **16.73** |

### FTS5 Indexing Throughput
*Measures end-to-end SQLite virtual table batch insertion and FTS5 index building (includes DB I/O & B-tree updates).*

| Virtual Table Tokenizer | Time (ms) | Throughput (MB/s) |
| :--- | :---: | :---: |
| **Jieba (Default)** | 225.63 | **12.49** |
| **Jieba (With Stopwords)** | 229.14 | **12.29** |
| **SQLite unicode61 (Reference)** | 60.70 | 46.41 |

*(To reproduce the results, run `swift test -c release --filter JiebaPerformanceTests`)*

---

## CI & Testing

Every commit and pull request is automatically verified via a parallel test matrix on GitHub Actions:
- **Environment**: `macos-14`
- **Swift Versions**: `5.9`, `5.10`, `6.0`
- **GRDB.swift Versions**: `7.5.0`, `7.8.0`, `7.10.0`

Our test suite contains 64 rigorous test cases covering concurrency stress tests, memory allocation trackers, Unicode folding matrices, dynamic dictionary mutations, and malformed C-string boundaries.

---

## License

MIT — see [LICENSE](LICENSE).

Bundles [cppjieba](https://github.com/yanyiwu/cppjieba) (MIT; header-only, no limonp since upstream removed that dependency).
