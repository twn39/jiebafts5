# JiebaEngine 生命周期契约

## 1. 进程级单例

`JiebaEngine.shared` 在进程内持有一份 cppjieba 实例（主词典 + HMM + 用户词典，内存约数十 MB）。

```
configure(paths)?  →  首次访问 shared  →  可选 shutdown  →  再次 shared 重新加载
```

| API | 行为 |
|---|---|
| `configure(dictPath:hmmPath:userDictPath:)` | 仅当 **尚未** 创建 `_shared` 时生效；返回 `true`。若已初始化返回 `false`（配置被忽略，不崩溃）。 |
| `shared` | 懒加载：优先 custom paths，否则 `Bundle.module` 内置字典。 |
| `shutdown()` | 释放当前实例；之后再次访问 `shared` 会按 **当前** `customConfig`（若仍有）或 Bundle 重建。 |
| `preheat()` | 后台触发一次 `shared`，降低首次查询延迟。 |
| `insertUserWord(_:)` | 运行时插词；返回 `Bool`（失败时为 `false`，不抛错）。线程安全（C++ `shared_mutex`）。 |

## 2. 推荐用法

### App 启动

```swift
// 可选：外置字典（必须在任何 DB / shared 访问之前）
_ = JiebaEngine.configure(
    dictPath: dictURL.path,
    hmmPath: hmmURL.path,
    userDictPath: userURL.path
)
JiebaEngine.preheat()

var config = Configuration()
config.addJiebaTokenizer()
let pool = try DatabasePool(path: path, configuration: config)
```

### 内存告警 / 测试 teardown

```swift
JiebaEngine.shutdown()
// 之后下次 FTS 操作会重新加载字典
```

### 测试中更换字典

```swift
JiebaEngine.shutdown()
XCTAssertTrue(JiebaEngine.configure(dictPath:..., hmmPath:..., userDictPath:...))
_ = JiebaEngine.shared
```

## 3. 与 FTS5 的关系

- 所有连接上的 `JiebaTokenizer` 共用同一 `JiebaEngine.shared`。
- `shutdown` 后若仍有打开的连接继续分词，会自动重建 engine（使用当时的 configure 状态）。
- 动态插词影响 **整个进程** 内后续 document/query 分词，不区分数据库文件。

## 4. 错误语义

| 场景 | 行为 |
|---|---|
| Bundle 缺字典且未 configure | `shared` 初始化时 `fatalError` |
| 路径不存在 / `jieba_create` 失败 | `fatalError`（避免半初始化单例） |
| `configure` 在已初始化后 | 返回 `false`，打日志，**不**改路径 |
| 分词 C++ 异常 | C 层返回非 0（`SQLITE_ERROR`），不静默当成功 |
| `insertUserWord` 失败 | 返回 `false` |
