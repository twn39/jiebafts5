# JiebaTokenizer Complete Performance Benchmark Report

- **Corpus Details**: Mixed Chinese/English text, 5000 documents.
- **Corpus Size**: 2.82 MB (2953890 bytes).
- **Platform**: 版本26.3（版号25D125） (10 Cores).

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| Jieba (Default) | 1979.48 | 1.42 |
| Jieba (With Stopwords) | 2134.31 | 1.32 |
| Jieba (No Folding) | 1967.45 | 1.43 |


## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| Jieba (Default) | 2113.86 | 1.33 |
| Jieba (With Stopwords) | 2278.15 | 1.24 |
| SQLite unicode61 | 111.31 | 25.31 |

*(测试结果在运行时自动计算生成)*
