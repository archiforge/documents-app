#ifndef NATIVE_ARCHIVES_C_H
#define NATIVE_ARCHIVES_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NAArchiveReader NAArchiveReader;

/** Opens an archive and enables every format/filter compiled into libarchive. */
NAArchiveReader *na_archive_open(
    const char *path,
    char *error_buffer,
    size_t error_buffer_length
);

/**
 * Advances to the next entry.
 *
 * Returns 0 for an entry, 1 at end of archive, and -1 for a malformed or
 * unreadable archive. The returned pathname is owned by libarchive and stays
 * valid until the next call or close.
 */
int na_archive_next(
    NAArchiveReader *reader,
    const char **pathname,
    int32_t *entry_kind,
    int64_t *entry_size,
    char *error_buffer,
    size_t error_buffer_length
);

/** Reads decompressed bytes for the current regular-file entry. */
int na_archive_read(
    NAArchiveReader *reader,
    void *buffer,
    size_t buffer_length,
    size_t *bytes_read,
    char *error_buffer,
    size_t error_buffer_length
);

/** Skips the remainder of the current entry. */
int na_archive_skip(
    NAArchiveReader *reader,
    char *error_buffer,
    size_t error_buffer_length
);

void na_archive_close(NAArchiveReader *reader);

#ifdef __cplusplus
}
#endif

#endif
