# Tokenization Profile 契约

本文定义 **JiebaFTS5** 的分词配置契约：默认行为、命名 profile、document/query 语义、FTS5 参数 wire format，以及变更时的兼容性要求。

> **稳定性承诺：** 同一 major 版本内，已文档化的 profile 语义与 argument 关键字不得静默改变含义。新增开关须向后兼容（缺省 = 旧行为）。

---

## 1. 命名 Profile

| Profile | API | case / width / diacritic fold | stopwords |
|---|---|---|---|
| **Default** | `JiebaTokenizerOptions()` / `.jieba()` | 全部 `true` | **无** |
| **Recommended** | `.recommended` / `.jieba(options: .recommended)` | 全部 `true` | `StopwordPresets.cjkCommon` |
| **Strict match** | `.strictMatch` | 全部 `false` | 无 |

说明：

- **Default** 适合最大召回、自行管理停用词的调用方（与历史 API 兼容）。
- **Recommended** 适合中英混合全文检索「开箱即用」。
- **Strict match** 关闭所有折叠，大小写 / 全半角 / 变音符严格区分。

```swift
var opts = JiebaTokenizerOptions.recommended
opts.caseFolding = false  // 在推荐预设上微调
t.tokenizer = .jieba(options: opts)
```

---

## 2. Document vs Query 语义（契约）

采用 FTS5 synonym **方法 (3)**：子词 / 同位置 token 只在 **document** 侧以 `FTS5_TOKEN_COLOCATED` 形式写入。

| 规则 | Document（索引） | Query（查询） |
|---|---|---|
| 分词算法 | cppjieba **QuerySeg**（`jieba_cut_for_search`） | cppjieba **MixSeg**（`jieba_cut`） |
| 复合词主 token | 发出 | 发出（MixSeg，通常无细粒度 colocated） |
| 同位置子词（COLOCATED） | QuerySeg 产生时发出（长词优先） | **不发出** COLOCATED |
| 折叠 / 停用词 | 与 options 一致 | 与 options **必须一致** |

索引与查询必须使用 **同一 tokenizer 名称与同一 options**（由 FTS5 表定义固定）。

### 2.1 方法 (3) 不变量

1. Query 侧不得依赖 document 未写入的 token 字节。
2. Document 侧 COLOCATED 子词用于提升召回（如「清华」命中「清华大学」），不增加独立词位。
3. `snippet` / highlight 使用的 AUX 分词须与 document 位置对齐（由 SQLite FTS5 保证；测试覆盖 `snippet()`）。

---

## 3. FTS5 Argument Wire Format

`JiebaTokenizerOptions.arguments` 生成的参数列表（**不含** tokenizer 名 `jieba`；GRDB 可能在 `init` 前插入名称——解析时用 `contains` / 键值扫描）。

### 3.1 开关（缺省 = 启用对应能力）

| Argument token | 含义 |
|---|---|
| `no_case_fold` | `caseFolding = false` |
| `no_width_fold` | `widthFolding = false` |
| `no_diacritic_fold` | `diacriticFolding = false` |

### 3.2 停用词

| 形式 | 含义 |
|---|---|
| `stopwords_preset` + id | 内置预设：`en` / `zh` / `en+zh`（见 `StopwordPresets`） |
| `stopwords` + CSV | 自定义列表（逗号分隔，顺序无关；编码时排序以保证稳定） |

---

## 4. 规范化顺序（与 TokenNormalizer 一致）

对非「纯 CJK 统一汉字」token：

1. 可选宽度折叠（快路径：全角 ASCII 字节映射；慢路径：NFKC）
2. 可选变音符折叠 + 大小写折叠（`String.folding`）
3. 与按相同 options 构建的 `StopwordSet` 匹配

纯 CJK（UTF-8 下全部为 U+4E00–U+9FFF 三字节序列）走零拷贝路径，不应用 Latin 折叠。

---

## 5. 引擎与字典

见 [ENGINE_LIFECYCLE.md](ENGINE_LIFECYCLE.md)。字典缺失或 `jieba_create` 失败在当前版本仍会触发进程级失败（`fatalError`）；`configure` 须在首次使用 `shared` 之前调用。
