// CJiebaWrapper.cpp
// C++ implementation of the callback-based C interface.
//
// Hot path avoids building cppjieba::Word.string (no per-token substr heap).
// Emits only (offset, length) spans into the original UTF-8 buffer.

#include "CJiebaWrapper.h"

#include "cppjieba/MixSegment.hpp"
#include "cppjieba/PreFilter.hpp"
#include "cppjieba/QuerySegment.hpp"
#include "cppjieba/Unicode.hpp"

#include <algorithm>
#include <cstdint>
#include <new>
#include <shared_mutex>
#include <string>
#include <unordered_set>
#include <vector>

// SQLite result codes used at the ABI boundary (avoid linking sqlite headers here).
static constexpr int kSqliteOk = 0;
static constexpr int kSqliteError = 1;

// MARK: - Subclasses expose SegmentBase::symbols_ for PreFilter

struct MixSegEx : public cppjieba::MixSegment {
    using cppjieba::MixSegment::MixSegment;
    const std::unordered_set<cppjieba::Rune>& symbols() const { return symbols_; }
};

struct QuerySegEx : public cppjieba::QuerySegment {
    using cppjieba::QuerySegment::QuerySegment;
    const std::unordered_set<cppjieba::Rune>& symbols() const { return symbols_; }
};

// MARK: - Internal segmenter

struct JiebaSegmenter {
    cppjieba::DictTrie dict_trie;
    cppjieba::HMMModel model;
    MixSegEx mix_seg;
    QuerySegEx query_seg;
    std::shared_mutex rw_mutex;

    JiebaSegmenter(const std::string& dict_path,
                   const std::string& hmm_path,
                   const std::string& user_dict_path)
        : dict_trie(dict_path, user_dict_path),
          model(hmm_path),
          mix_seg(&dict_trie, &model),
          query_seg(&dict_trie, &model) {}
};

// MARK: - Span helpers (no token string storage)

struct TokenSpan {
    uint32_t offset;
    uint32_t length;
};

static inline TokenSpan span_from_word_range(const cppjieba::WordRange& wr) {
    // Mirrors cppjieba::GetWordFromRunes length calculation without substr.
    const uint32_t offset = wr.left->offset;
    const uint32_t length = wr.right->offset - wr.left->offset + wr.right->len;
    return TokenSpan{offset, length};
}

static void append_word_ranges(const std::vector<cppjieba::WordRange>& wrs,
                               std::vector<TokenSpan>& out) {
    out.reserve(out.size() + wrs.size());
    for (const auto& wr : wrs) {
        out.push_back(span_from_word_range(wr));
    }
}

/// FTS5 Method 3 order: offset ascending, longer token first at same offset.
static int process_and_emit_spans(std::vector<TokenSpan>& spans,
                                  void* ctx,
                                  JiebaTokenEmitCallback callback) {
    if (spans.empty()) {
        return kSqliteOk;
    }

    std::sort(spans.begin(), spans.end(), [](const TokenSpan& lhs, const TokenSpan& rhs) {
        if (lhs.offset != rhs.offset) {
            return lhs.offset < rhs.offset;
        }
        return lhs.length > rhs.length;
    });

    uint32_t prev_offset = UINT32_MAX;
    uint32_t last_emitted_offset = UINT32_MAX;
    uint32_t last_emitted_length = UINT32_MAX;
    bool has_last = false;

    for (const auto& sp : spans) {
        // Dedup identical spans (same offset + byte length ⇒ same original bytes).
        if (has_last
            && sp.offset == last_emitted_offset
            && sp.length == last_emitted_length) {
            continue;
        }
        const bool is_col = (prev_offset != UINT32_MAX && sp.offset == prev_offset);
        const int rc = callback(ctx, sp.offset, sp.length, is_col ? 1 : 0);
        if (rc != kSqliteOk) {
            return rc;
        }
        last_emitted_offset = sp.offset;
        last_emitted_length = sp.length;
        has_last = true;
        if (!is_col) {
            prev_offset = sp.offset;
        }
    }
    return kSqliteOk;
}

/// Cut via WordRange only (no per-token std::string).
template <typename SegT, typename CutFn>
static int cut_spans_and_emit(SegT& seg,
                              const std::unordered_set<cppjieba::Rune>& symbols,
                              const std::string& sentence,
                              void* ctx,
                              JiebaTokenEmitCallback callback,
                              CutFn&& cut_range) {
    cppjieba::PreFilter pre_filter(symbols, sentence);
    thread_local std::vector<cppjieba::WordRange> tl_wrs;
    thread_local std::vector<TokenSpan> tl_spans;
    tl_wrs.clear();
    tl_spans.clear();
    tl_wrs.reserve(sentence.size() / 2);
    tl_spans.reserve(sentence.size() / 2);

    while (pre_filter.HasNext()) {
        const cppjieba::PreFilter::Range range = pre_filter.Next();
        if (range.begin >= range.end) {
            continue;
        }
        tl_wrs.clear();
        cut_range(seg, range.begin, range.end, tl_wrs);
        append_word_ranges(tl_wrs, tl_spans);
    }

    return process_and_emit_spans(tl_spans, ctx, callback);
}

// MARK: - C API

extern "C" {

JiebaHandle jieba_create(const char* dict_path,
                         const char* hmm_path,
                         const char* user_dict_path) {
    try {
        return new (std::nothrow) JiebaSegmenter(
            dict_path ? dict_path : "",
            hmm_path ? hmm_path : "",
            user_dict_path ? user_dict_path : "");
    } catch (...) {
        return nullptr;
    }
}

void jieba_free(JiebaHandle handle) {
    delete static_cast<JiebaSegmenter*>(handle);
}

int jieba_cut(JiebaHandle handle,
              const char* text,
              size_t len,
              void* ctx,
              JiebaTokenEmitCallback callback) {
    if (!handle || !text || len == 0 || !callback) {
        return kSqliteOk;
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::shared_lock<std::shared_mutex> lock(seg->rw_mutex);

        thread_local std::string tl_sentence;
        tl_sentence.assign(text, len);

        return cut_spans_and_emit(
            seg->mix_seg,
            seg->mix_seg.symbols(),
            tl_sentence,
            ctx,
            callback,
            [](MixSegEx& mix,
               cppjieba::RuneStrArray::const_iterator begin,
               cppjieba::RuneStrArray::const_iterator end,
               std::vector<cppjieba::WordRange>& wrs) {
                mix.Cut(begin, end, wrs, /*hmm=*/true);
            });
    } catch (...) {
        return kSqliteError;
    }
}

int jieba_cut_for_search(JiebaHandle handle,
                         const char* text,
                         size_t len,
                         void* ctx,
                         JiebaTokenEmitCallback callback) {
    if (!handle || !text || len == 0 || !callback) {
        return kSqliteOk;
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::shared_lock<std::shared_mutex> lock(seg->rw_mutex);

        thread_local std::string tl_sentence;
        tl_sentence.assign(text, len);

        return cut_spans_and_emit(
            seg->query_seg,
            seg->query_seg.symbols(),
            tl_sentence,
            ctx,
            callback,
            [](QuerySegEx& query,
               cppjieba::RuneStrArray::const_iterator begin,
               cppjieba::RuneStrArray::const_iterator end,
               std::vector<cppjieba::WordRange>& wrs) {
                query.Cut(begin, end, wrs, /*hmm=*/true);
            });
    } catch (...) {
        return kSqliteError;
    }
}

int jieba_insert_user_word(JiebaHandle handle, const char* word) {
    if (!handle || !word || word[0] == '\0') {
        return 0;
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::unique_lock<std::shared_mutex> lock(seg->rw_mutex);
        const bool ok = seg->dict_trie.InsertUserWord(word);
        return ok ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

int jieba_insert_user_words(JiebaHandle handle, const char* const* words, size_t count) {
    if (!handle || !words || count == 0) {
        return 0;
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::unique_lock<std::shared_mutex> lock(seg->rw_mutex);
        int ok = 0;
        for (size_t i = 0; i < count; ++i) {
            const char* w = words[i];
            if (!w || w[0] == '\0') {
                continue;
            }
            if (seg->dict_trie.InsertUserWord(w)) {
                ++ok;
            }
        }
        return ok;
    } catch (...) {
        return 0;
    }
}

} // extern "C"
