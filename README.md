# JiebaFTS5

A Swift Package that integrates [cppjieba](https://github.com/yanyiwu/cppjieba) with [GRDB](https://github.com/groue/GRDB.swift) as a custom FTS5 tokenizer, enabling high-quality Chinese full-text search in SQLite on iOS and macOS.

## Features

- **Jieba word segmentation** — accurate Chinese tokenization via cppjieba's MixSeg (MP + HMM) and QuerySeg algorithms
- **COLOCATED synonym indexing** — sub-words (`清华`, `大学`) are indexed alongside the full compound (`清华大学`), enabling partial-word search without false positives (FTS5 Method 3)
- **Zero-copy token emission** — tokens are emitted directly from SQLite's own buffer with no intermediate heap allocation
- **Case folding** — optional ASCII/Latin lowercasing, with a stack-buffer fast path for uppercase ASCII and Unicode-aware folding for full-width characters
- **Memory-efficient** — one shared cppjieba engine (~25 MB) across all `DatabasePool` connections via a process-lifetime singleton
- **Thread-safe** — `static let` initialisation; all post-init C calls are read-only

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
        t.tokenizer = .jieba()          // caseFolding: true (default)
        t.column("title")
        t.column("body")
    }
}
```

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

### 4. Case-sensitive search

```swift
t.tokenizer = .jieba(caseFolding: false)
```

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

## License

MIT — see [LICENSE](LICENSE).

Bundles [cppjieba](https://github.com/yanyiwu/cppjieba) and [limonp](https://github.com/yanyiwu/limonp) (both MIT).
