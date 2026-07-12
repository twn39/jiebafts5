// CJiebaWrapper.h
// Pure C interface over cppjieba, optimized for zero-heap-allocation emit.

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
/// Intended for FTS5 **query** tokenization.
/// Returns 0 (SQLITE_OK) on success, non-zero on callback abort or internal error.
int jieba_cut(JiebaHandle handle,
              const char* text,
              size_t      len,
              void*       ctx,
              JiebaTokenEmitCallback callback);

/// Search-engine segmentation (QuerySeg) with callback.
/// Intended for FTS5 **document** tokenization.
/// Returns 0 (SQLITE_OK) on success, non-zero on callback abort or internal error.
int jieba_cut_for_search(JiebaHandle handle,
                         const char* text,
                         size_t      len,
                         void*       ctx,
                         JiebaTokenEmitCallback callback);

// MARK: - Dynamic Dictionary

/// Dynamically inserts a word into the dictionary at runtime.
/// Thread-safe via internal unique lock.
/// Returns 1 on success, 0 on failure.
int jieba_insert_user_word(JiebaHandle handle, const char* word);

/// Inserts multiple user words under a **single** write lock.
/// `words` is an array of `count` UTF-8 C strings (NULL entries are skipped).
/// Returns the number of successful inserts.
int jieba_insert_user_words(JiebaHandle handle, const char* const* words, size_t count);

#ifdef __cplusplus
}
#endif
