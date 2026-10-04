#ifndef SLSK_ZLIB_SHIMS_H
#define SLSK_ZLIB_SHIMS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Compress `input` into a standard zlib stream (level 4, matching Nicotine+).
 * On success returns 0 and sets *output / *output_len; caller must free()
 * the buffer. Returns non-zero on failure. */
int slsk_zlib_compress(const uint8_t *input, size_t input_len,
                       uint8_t **output, size_t *output_len);

/* Decompress a zlib stream. Never allocates more than max_output bytes.
 * On success returns 0 and sets *output / *output_len; caller must free().
 * Returns non-zero on failure or if the stream exceeds max_output. */
int slsk_zlib_decompress(const uint8_t *input, size_t input_len,
                         uint8_t **output, size_t *output_len,
                         size_t max_output);

void slsk_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* SLSK_ZLIB_SHIMS_H */
