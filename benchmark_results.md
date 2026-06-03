# JiebaTokenizer Complete Performance Benchmark Report

- **Corpus Details**: Mixed Chinese/English text, 5000 documents.
- **Corpus Size**: 2.82 MB (2953890 bytes).
- **Platform**: 版本26.3（版号25D125） (10 Cores).

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| Jieba (Default) | 1891.63 | 1.49 |
| Jieba (With Stopwords) | 2039.70 | 1.38 |
| Jieba (No Folding) | 1872.17 | 1.50 |


## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| Jieba (Default) | 2013.91 | 1.40 |
| Jieba (With Stopwords) | 2188.16 | 1.29 |
| SQLite unicode61 | 105.56 | 26.69 |

*(测试结果在运行时自动计算生成)*
