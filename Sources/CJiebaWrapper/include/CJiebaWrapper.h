// CJiebaWrapper.h
// Pure C interface over cppjieba::Jieba, optimized for zero-heap-allocation.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Engine lifecycle

/// Opaque handle to a JiebaSegmenter instance.
typedef void* JiebaHandle;

/// Creates a Jieba segmentation engine.
/// All path arguments must be valid UTF-8 absolute paths.
/// Returns NULL on allocation failure or if any file cannot be opened.
JiebaHandle jieba_create(const char* dict_path,
                          const char* hmm_path,
                          const char* user_dict_path);

/// Destroys the engine and frees all associated memory.
void jieba_free(JiebaHandle handle);

// MARK: - Callback Type

/// Callback invoked for each token.
/// - offset: byte start position in the original text.
/// - length: byte length of the token in the original text.
/// - is_colocated: 1 if this token shares its start offset with the previous token, 0 otherwise.
/// - Returns: SQLITE_OK (0) to continue, or any other value to abort.
typedef int (*JiebaTokenEmitCallback)(void* ctx, uint32_t offset, uint32_t length, int is_colocated);

// MARK: - Segmentation

/// Precise segmentation (MixSeg: Maximum-Probability + HMM) with callback.
/// Intended for FTS5 query tokenization.
/// Returns SQLITE_OK (0) on success, or the callback error code.
int jieba_cut(JiebaHandle handle,
              const char* text,
              size_t      len,
              void*       ctx,
              JiebaTokenEmitCallback callback);

/// Search-engine segmentation (QuerySeg) with callback.
/// Intended for FTS5 document tokenization.
/// Returns SQLITE_OK (0) on success, or the callback error code.
int jieba_cut_for_search(JiebaHandle handle,
                         const char* text,
                         size_t      len,
                         void*       ctx,
                         JiebaTokenEmitCallback callback);

// MARK: - Dynamic Dictionary

/// Dynamically inserts a word into the dictionary at runtime.
/// Thread-safe via internal unique lock.
void jieba_insert_user_word(JiebaHandle handle, const char* word);

#ifdef __cplusplus
}
#endif
