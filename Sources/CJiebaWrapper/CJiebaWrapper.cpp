// CJiebaWrapper.cpp
// C++ implementation of the callback-based C interface.

#include "CJiebaWrapper.h"

#include "cppjieba/MixSegment.hpp"
#include "cppjieba/QuerySegment.hpp"

#include <algorithm>
#include <cstdint>
#include <new>
#include <shared_mutex>
#include <string>
#include <vector>

// SQLite result codes used at the ABI boundary (avoid linking sqlite headers here).
static constexpr int kSqliteOk = 0;
static constexpr int kSqliteError = 1;

// MARK: - Internal segmenter

struct JiebaSegmenter {
    cppjieba::DictTrie dict_trie;
    cppjieba::HMMModel model;
    cppjieba::MixSegment mix_seg;
    cppjieba::QuerySegment query_seg;
    std::shared_mutex rw_mutex;

    JiebaSegmenter(const std::string& dict_path,
                   const std::string& hmm_path,
                   const std::string& user_dict_path)
        : dict_trie(dict_path, user_dict_path),
          model(hmm_path),
          mix_seg(&dict_trie, &model),
          query_seg(&dict_trie, &model) {}
};

// MARK: - Helper

static int process_and_emit(std::vector<cppjieba::Word>& words,
                            void* ctx,
                            JiebaTokenEmitCallback callback) {
    if (words.empty()) {
        return kSqliteOk;
    }

    // Primary: ascending offset.
    // Secondary: descending length so the longest token is first (FTS5 colocated).
    std::sort(words.begin(), words.end(), [](const cppjieba::Word& lhs, const cppjieba::Word& rhs) {
        if (lhs.offset != rhs.offset) {
            return lhs.offset < rhs.offset;
        }
        return lhs.word.size() > rhs.word.size();
    });

    uint32_t prev_offset = UINT32_MAX;
    uint32_t last_emitted_offset = UINT32_MAX;
    const std::string* last_emitted_word = nullptr;

    for (const auto& w : words) {
        if (last_emitted_word != nullptr
            && w.offset == last_emitted_offset
            && w.word == *last_emitted_word) {
            continue;
        }
        const bool is_col = (prev_offset != UINT32_MAX && w.offset == prev_offset);
        const int rc = callback(ctx, w.offset, static_cast<uint32_t>(w.word.size()), is_col ? 1 : 0);
        if (rc != kSqliteOk) {
            return rc;
        }
        last_emitted_offset = w.offset;
        last_emitted_word = &w.word;
        if (!is_col) {
            prev_offset = w.offset;
        }
    }
    return kSqliteOk;
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
        thread_local std::vector<cppjieba::Word> tl_words;

        tl_sentence.assign(text, len);
        tl_words.clear();
        tl_words.reserve(len / 3);

        seg->mix_seg.Cut(tl_sentence, tl_words, /*hmm=*/true);

        return process_and_emit(tl_words, ctx, callback);
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
        thread_local std::vector<cppjieba::Word> tl_words;

        tl_sentence.assign(text, len);
        tl_words.clear();
        tl_words.reserve(len / 2);

        seg->query_seg.Cut(tl_sentence, tl_words, /*hmm=*/true);

        return process_and_emit(tl_words, ctx, callback);
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

} // extern "C"
