// CJiebaWrapper.cpp
// C++ implementation of the pure C interface declared in CJiebaWrapper.h.
//
// We use cppjieba's lower-level MixSegment and QuerySegment directly instead
// of the top-level Jieba class.  Jieba's constructor unconditionally loads
// KeywordExtractor (idf.utf8 + stop_words.utf8), which are not needed for FTS5
// tokenization and would require two more bundled files.

#include "CJiebaWrapper.h"

#include "cppjieba/MixSegment.hpp"
#include "cppjieba/QuerySegment.hpp"

#include <cstdlib>   // malloc, free
#include <cstring>   // strdup
#include <new>       // std::nothrow
#include <vector>

// MARK: - Internal engine struct

/// Groups the cppjieba objects needed for Cut and CutForSearch.
struct JiebaSegmenter {
    cppjieba::DictTrie  dict_trie;
    cppjieba::HMMModel  model;
    cppjieba::MixSegment   mix_seg;    // for Cut (MixSeg = MP + HMM)
    cppjieba::QuerySegment query_seg;  // for CutForSearch (MixSeg + sub-words)

    JiebaSegmenter(const std::string& dict_path,
                   const std::string& hmm_path,
                   const std::string& user_dict_path)
        : dict_trie(dict_path, user_dict_path),
          model(hmm_path),
          mix_seg(&dict_trie, &model),
          query_seg(&dict_trie, &model)
    {}
};

// MARK: - Internal helpers

static JiebaTokenList build_token_list(const std::vector<cppjieba::Word>& words) {
    JiebaTokenList result;
    result.count = words.size();

    if (result.count == 0) {
        result.tokens = nullptr;
        return result;
    }

    result.tokens = static_cast<JiebaToken*>(
        std::malloc(result.count * sizeof(JiebaToken)));

    if (!result.tokens) {
        result.count = 0;
        return result;
    }

    for (size_t i = 0; i < words.size(); ++i) {
        result.tokens[i].word   = strdup(words[i].word.c_str());
        result.tokens[i].offset = words[i].offset;
        result.tokens[i].length = static_cast<uint32_t>(words[i].word.size());
    }

    return result;
}

// MARK: - C API

extern "C" {

JiebaHandle jieba_create(const char* dict_path,
                          const char* hmm_path,
                          const char* user_dict_path) {
    try {
        return new(std::nothrow) JiebaSegmenter(
            dict_path      ? dict_path      : "",
            hmm_path       ? hmm_path       : "",
            user_dict_path ? user_dict_path : ""
        );
    } catch (...) {
        // cppjieba throws XCHECK failures on missing/malformed files.
        return nullptr;
    }
}

void jieba_free(JiebaHandle handle) {
    delete static_cast<JiebaSegmenter*>(handle);
}

JiebaTokenList jieba_cut(JiebaHandle handle,
                          const char* text,
                          size_t      len) {
    if (!handle || !text || len == 0) {
        return JiebaTokenList{nullptr, 0};
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::vector<cppjieba::Word> words;
        words.reserve(len / 3);
        seg->mix_seg.Cut(std::string(text, len), words, /*hmm=*/true);
        return build_token_list(words);
    } catch (...) {
        return JiebaTokenList{nullptr, 0};
    }
}

JiebaTokenList jieba_cut_for_search(JiebaHandle handle,
                                     const char* text,
                                     size_t      len) {
    if (!handle || !text || len == 0) {
        return JiebaTokenList{nullptr, 0};
    }
    try {
        auto* seg = static_cast<JiebaSegmenter*>(handle);
        std::vector<cppjieba::Word> words;
        words.reserve(len / 2);
        seg->query_seg.Cut(std::string(text, len), words, /*hmm=*/true);
        return build_token_list(words);
    } catch (...) {
        return JiebaTokenList{nullptr, 0};
    }
}

void jieba_token_list_free(JiebaTokenList list) {
    for (size_t i = 0; i < list.count; ++i) {
        free(const_cast<char*>(list.tokens[i].word));
    }
    free(list.tokens);
}

} // extern "C"
