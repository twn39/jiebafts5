# JiebaEngine 生命周期契约

## 1. 进程级单例

`JiebaEngine.shared` / `bootstrap()` 在进程内持有一份 cppjieba 实例（主词典 + HMM + 用户词典，内存约数十 MB）。

```
configure(paths)?  →  bootstrap() / shared  →  可选 shutdown  →  再次 bootstrap/shared 重新加载
```

| API | 行为 |
|---|---|
| `configure(dictPath:hmmPath:userDictPath:)` | 仅当 **尚未** 创建 `_shared` 时生效；返回 `true`。若已初始化返回 `false`（配置被忽略，不崩溃）。 |
| `bootstrap()` | 懒加载并返回 shared；字典缺失或 `jieba_create` 失败时 **抛出** `JiebaEngineError`。 |
| `shared` | 调用 `bootstrap()`；失败时 **`fatalError`**（兼容 FTS5 注册路径）。 |
| `make(dictPath:hmmPath:userDictPath:)` | 创建 **独立** 引擎实例（不装入 shared）。 |
| `register(name:engine:)` / `unregister(name:)` | 命名引擎注册表；供 FTS5 `options.engineName` 解析。 |
| `resolve(name:)` | 按名取引擎；空/`shared`/`default` → bootstrap shared。 |
| `bundledDictionaryPaths` | Bundle 内默认三份字典路径（若存在）。 |
| `shutdown()` | 仅释放 **shared**；**不**清空命名注册表。 |
| `preheat()` | 后台 `try? bootstrap()`，降低首次查询延迟。 |
| `insertUserWord(_:)` / `insertUserWords(_:)` | 运行时插词；批量接口单次写锁。线程安全。 |

## 2. 推荐用法

### App 启动（可恢复错误）

```swift
// 可选：外置字典（必须在任何 DB / shared 访问之前）
_ = JiebaEngine.configure(
    dictPath: dictURL.path,
    hmmPath: hmmURL.path,
    userDictPath: userURL.path
)

do {
    try JiebaEngine.bootstrap()
} catch {
    // 降级：禁用搜索 UI、提示用户、或换路径后 shutdown + configure + bootstrap
    logger.error("Jieba load failed: \(error)")
}

JiebaEngine.preheat() // 若尚未 bootstrap，会在后台再试

var config = Configuration()
config.addJiebaTokenizer()
let pool = try DatabasePool(path: path, configuration: config)
```

### 外置字典与包体积

- 默认字典经 `Bundle.module` 打进 App（约数 MB）。
- 需要减体积时：将 `jieba.dict.utf8` / `hmm_model.utf8` / `user.dict.utf8` 放到下载目录或 On-Demand Resource，**在首次访问 engine 之前** `configure` 到本地路径。

### 内存告警 / 测试 teardown

```swift
JiebaEngine.shutdown()
// 之后下次 FTS 操作会重新加载字典
```

### 测试中更换字典

```swift
JiebaEngine.shutdown()
XCTAssertTrue(JiebaEngine.configure(dictPath:..., hmmPath:..., userDictPath:...))
try JiebaEngine.bootstrap()
```

### 独立引擎 + FTS5 表级绑定

```swift
let engine = try JiebaEngine.make(dictPath:..., hmmPath:..., userDictPath:...)
JiebaEngine.register(name: "domain", engine: engine)

var opts = JiebaTokenizerOptions.recommended
opts.engineName = "domain"
// FTS5 参数会编码为 engine domain；表创建前必须已 register
t.tokenizer = .jieba(options: opts)

// 离线 / 测试也可不注册：
let tok = JiebaTokenizer(engine: engine, options: .recommended)
let tokens = tok.suggestTokens(for: "清华大学")
```

字典裁剪与外置见 [DICTIONARY_PACKAGING.md](DICTIONARY_PACKAGING.md)。

## 3. 与 FTS5 的关系

- 所有通过 `db.add(tokenizer: JiebaTokenizer.self)` 注册的连接共用 **`JiebaEngine.shared`**。
- `shutdown` 后若仍有打开的连接继续分词，会自动重建 engine（使用当时的 configure 状态）。
- 动态插词影响 **整个进程** 内后续 document/query 分词，不区分数据库文件。

### 3.1 插词不会自动重建索引

`insertUserWord` / `insertUserWords` **只改变之后的分词结果**，不会更新已经写入 FTS5 的行。

若新词需要命中历史文档，必须对该行 **UPDATE / 重建虚拟表 / 应用层 reindex**。文档侧与查询侧必须始终使用同一 tokenizer options。

## 4. 错误语义

| 场景 | `bootstrap()` / `make` | `shared` |
|---|---|---|
| Bundle 缺字典且未 configure | `missingBundleResources` | `fatalError` |
| 路径不存在 | `missingDictionaryFiles` | `fatalError` |
| `jieba_create` 失败 | `createFailed` | `fatalError` |
| `configure` 在已初始化后 | 返回 `false`，打日志，**不**改路径 | 同左 |
| 分词 C++ 异常 | C 层返回非 0（`SQLITE_ERROR`），不静默当成功 | 同左 |
| `insertUserWord` 失败 | 返回 `false` | 同左 |
