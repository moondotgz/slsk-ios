#include "shims.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

void slsk_free(void *ptr) {
    free(ptr);
}

int slsk_zlib_compress(const uint8_t *input, size_t input_len,
                       uint8_t **output, size_t *output_len) {
    if (input == NULL && input_len > 0) {
        return -1;
    }

    uLong bound = compressBound((uLong)input_len);
    uint8_t *out = malloc(bound ? bound : 1);
    if (out == NULL) {
        return -2;
    }

    uLongf out_len = bound;
    int status = compress2(out, &out_len, input, (uLong)input_len, 4);
    if (status != Z_OK) {
        free(out);
        return -3;
    }

    *output = out;
    *output_len = (size_t)out_len;
    return 0;
}

int slsk_zlib_decompress(const uint8_t *input, size_t input_len,
                         uint8_t **output, size_t *output_len,
                         size_t max_output) {
    if (input == NULL && input_len > 0) {
        return -1;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit(&stream) != Z_OK) {
        return -2;
    }

    size_t capacity = input_len * 4 + 65536;
    if (capacity > max_output) {
        capacity = max_output;
    }

    uint8_t *out = malloc(capacity ? capacity : 1);
    if (out == NULL) {
        inflateEnd(&stream);
        return -3;
    }

    size_t produced = 0;
    int status = Z_OK;

    stream.next_in = (Bytef *)(uintptr_t)input;
    stream.avail_in = (uInt)input_len;

    while (1) {
        stream.next_out = out + produced;
        stream.avail_out = (uInt)(capacity - produced);
        status = inflate(&stream, Z_NO_FLUSH);

        if (status == Z_STREAM_END) {
            produced = capacity - stream.avail_out;
            break;
        }
        if (status != Z_OK && status != Z_BUF_ERROR) {
            free(out);
            inflateEnd(&stream);
            return -4;
        }

        produced = capacity - stream.avail_out;

        if (stream.avail_in == 0 && status == Z_BUF_ERROR) {
            /* Input exhausted without a stream end marker */
            free(out);
            inflateEnd(&stream);
            return -5;
        }
        if (stream.avail_out == 0) {
            if (capacity >= max_output) {
                free(out);
                inflateEnd(&stream);
                return -6;
            }
            size_t new_capacity = capacity * 2;
            if (new_capacity > max_output) {
                new_capacity = max_output;
            }
            uint8_t *grown = realloc(out, new_capacity);
            if (grown == NULL) {
                free(out);
                inflateEnd(&stream);
                return -7;
            }
            out = grown;
            capacity = new_capacity;
        }
    }

    inflateEnd(&stream);
    *output = out;
    *output_len = produced;
    return 0;
}
