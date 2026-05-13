// CJiebaWrapper.h
// Pure C interface over cppjieba::Jieba.
//
// Design rationale:
//   - Swift can import C headers natively without extra build flags.
//   - Avoids .interoperabilityMode(.Cxx) which "infects" all transitive Swift
//     targets (including GRDB).
//   - C++ exceptions are caught in the .cpp implementation and never cross
//     into Swift frames (crossing language boundaries with live exceptions is UB).

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Engine lifecycle

/// Opaque handle to a cppjieba::Jieba instance.
typedef void* JiebaHandle;

/// Creates a Jieba segmentation engine.
/// All path arguments must be valid UTF-8 absolute paths.
/// Returns NULL on allocation failure or if any file cannot be opened.
JiebaHandle jieba_create(const char* dict_path,
                          const char* hmm_path,
                          const char* user_dict_path);

/// Destroys the engine and frees all associated memory.
void jieba_free(JiebaHandle handle);

// MARK: - Token types

/// A single token with its position in the original source text.
typedef struct {
    /// NUL-terminated UTF-8 token string.
    /// Memory owned by the JiebaTokenList; freed via jieba_token_list_free().
    const char* word;

    /// Byte offset of this token's start in the original source text.
    uint32_t offset;

    /// Byte length of this token in the original source text.
    /// Exclusive end position = offset + length.
    uint32_t length;
} JiebaToken;

/// An ordered list of tokens produced by one segmentation call.
typedef struct {
    JiebaToken* tokens; ///< NULL when count == 0.
    size_t      count;
} JiebaTokenList;

// MARK: - Segmentation

/// Precise segmentation (MixSeg: Maximum-Probability + HMM).
/// Intended for FTS5 **query** tokenization: emits one word per position
/// with no synonyms, preventing false-positive matches.
/// The caller must release the result with jieba_token_list_free().
JiebaTokenList jieba_cut(JiebaHandle handle,
                          const char* text,
                          size_t      len);

/// Search-engine segmentation (QuerySeg: MixSeg words + shorter sub-words).
/// Intended for FTS5 **document** tokenization: emits both long and short
/// forms so that sub-word queries can match.
/// The caller must release the result with jieba_token_list_free().
JiebaTokenList jieba_cut_for_search(JiebaHandle handle,
                                     const char* text,
                                     size_t      len);

/// Releases all memory owned by a JiebaTokenList.
/// Safe to call when count == 0.
void jieba_token_list_free(JiebaTokenList list);

#ifdef __cplusplus
}
#endif
