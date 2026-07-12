# 字典打包与体积优化

## 默认资源

| 文件 | 典型体积 | 作用 |
|---|---|---|
| `jieba.dict.utf8` | ~4.8 MB | 主词典（词 / 词频 / 词性） |
| `hmm_model.utf8` | ~0.5 MB | HMM 模型（未登录词） |
| `user.dict.utf8` | 极小 | 用户词典种子 |

三者经 SPM `resources: [.copy(...)]` 打进 `Bundle.module`。

## 外置字典（减包体）

1. 构建时 **不要** 依赖 Bundle 内超大 dict（可继续保留 hmm + 空 user，或三者都外置）。
2. App 首次启动下载 / On-Demand Resource 解压到 Application Support。
3. **在任何 DB / `shared` 访问之前**：

```swift
let base = appSupportURL
_ = JiebaEngine.configure(
    dictPath: base.appendingPathComponent("jieba.dict.utf8").path,
    hmmPath: base.appendingPathComponent("hmm_model.utf8").path,
    userDictPath: base.appendingPathComponent("user.dict.utf8").path
)
try JiebaEngine.bootstrap()
```

或使用命名引擎（多租户 / 多词典）：

```swift
let eng = try JiebaEngine.make(dictPath:..., hmmPath:..., userDictPath:...)
JiebaEngine.register(name: "tenant_a", engine: eng)

try db.create(virtualTable: "docs", using: FTS5()) { t in
    var opts = JiebaTokenizerOptions.recommended
    opts.engineName = "tenant_a"
    t.tokenizer = .jieba(options: opts)
    t.column("body")
}
```

`JiebaEngine.bundledDictionaryPaths` 可读取包内默认路径，便于测试或作为下载失败时的回退。

## 裁剪主词典

使用仓库脚本按词频阈值过滤（**不修改** 仓库内默认 Resources）：

```bash
python3 Scripts/trim_jieba_dict.py \
  -i Sources/JiebaFTS5/Resources/jieba.dict.utf8 \
  -o /tmp/jieba.dict.min5.utf8 \
  --min-freq 5
```

- 提高 `--min-freq` → 更小、召回略降（长尾专有名词更依赖 `insertUserWord` / 用户词典）。
- 裁剪后务必用真实语料跑 golden / 业务搜索回归。
- HMM 模型一般保留；未登录中文仍依赖 HMM。

## 运行时插词与体积

- `insertUserWord` / `insertUserWords` 不增加包体，只增加进程内存。
- 插词 **不会** 重建已有 FTS5 行；历史文档需 UPDATE / 重建索引。

## 建议策略

| 场景 | 建议 |
|---|---|
| 通用中文 App | 默认 Bundle 字典 |
| 包体敏感 | 外置全量 dict 或 `--min-freq` 裁剪后外置 |
| 垂直领域 | 小主词典 + 领域 `user.dict` + 运行时 `insertUserWords` |
| 多租户 | `make` + `register` + `engineName` |
