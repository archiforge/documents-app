#include "NativeArchivesC.h"

#include <archive.h>
#include <archive_entry.h>
#include <stdlib.h>
#include <string.h>

struct NAArchiveReader {
    struct archive *archive;
    struct archive_entry *entry;
};

enum {
    NA_ENTRY_REGULAR = 1,
    NA_ENTRY_DIRECTORY = 2,
    NA_ENTRY_LINK = 3,
    NA_ENTRY_SPECIAL = 4
};

static void na_copy_error(
    struct archive *archive,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (error_buffer == NULL || error_buffer_length == 0) {
        return;
    }

    const char *message = archive == NULL ? NULL : archive_error_string(archive);
    if (message == NULL) {
        message = "The archive could not be read.";
    }

    strncpy(error_buffer, message, error_buffer_length - 1);
    error_buffer[error_buffer_length - 1] = '\0';
}

static void na_copy_static_error(
    const char *message,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (error_buffer == NULL || error_buffer_length == 0) {
        return;
    }
    strncpy(error_buffer, message, error_buffer_length - 1);
    error_buffer[error_buffer_length - 1] = '\0';
}

NAArchiveReader *na_archive_open(
    const char *path,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (path == NULL || path[0] == '\0') {
        na_copy_static_error("The archive path is empty.", error_buffer, error_buffer_length);
        return NULL;
    }

    struct archive *archive = archive_read_new();
    if (archive == NULL) {
        na_copy_static_error("The archive reader could not be created.", error_buffer, error_buffer_length);
        return NULL;
    }

    if (archive_read_support_filter_all(archive) != ARCHIVE_OK ||
        archive_read_support_format_all(archive) != ARCHIVE_OK ||
        archive_read_open_filename(archive, path, 10240) != ARCHIVE_OK) {
        na_copy_error(archive, error_buffer, error_buffer_length);
        archive_read_free(archive);
        return NULL;
    }

    NAArchiveReader *reader = (NAArchiveReader *)calloc(1, sizeof(NAArchiveReader));
    if (reader == NULL) {
        na_copy_static_error("The archive reader ran out of memory.", error_buffer, error_buffer_length);
        archive_read_close(archive);
        archive_read_free(archive);
        return NULL;
    }

    reader->archive = archive;
    return reader;
}

int na_archive_next(
    NAArchiveReader *reader,
    const char **pathname,
    int32_t *entry_kind,
    int64_t *entry_size,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (reader == NULL || reader->archive == NULL || pathname == NULL ||
        entry_kind == NULL || entry_size == NULL) {
        na_copy_static_error("The archive reader is invalid.", error_buffer, error_buffer_length);
        return -1;
    }

    int status = archive_read_next_header(reader->archive, &reader->entry);
    if (status == ARCHIVE_EOF) {
        return 1;
    }
    if (status != ARCHIVE_OK) {
        na_copy_error(reader->archive, error_buffer, error_buffer_length);
        return -1;
    }

    *pathname = archive_entry_pathname(reader->entry);
    *entry_size = (int64_t)archive_entry_size(reader->entry);

    if (archive_entry_symlink(reader->entry) != NULL ||
        archive_entry_hardlink(reader->entry) != NULL) {
        *entry_kind = NA_ENTRY_LINK;
    } else {
        mode_t type = archive_entry_filetype(reader->entry);
        if (type == AE_IFREG) {
            *entry_kind = NA_ENTRY_REGULAR;
        } else if (type == AE_IFDIR) {
            *entry_kind = NA_ENTRY_DIRECTORY;
        } else {
            *entry_kind = NA_ENTRY_SPECIAL;
        }
    }

    return 0;
}

int na_archive_read(
    NAArchiveReader *reader,
    void *buffer,
    size_t buffer_length,
    size_t *bytes_read,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (reader == NULL || reader->archive == NULL || buffer == NULL ||
        bytes_read == NULL || buffer_length == 0) {
        na_copy_static_error("The archive reader is invalid.", error_buffer, error_buffer_length);
        return -1;
    }

    la_ssize_t result = archive_read_data(reader->archive, buffer, buffer_length);
    if (result < 0) {
        na_copy_error(reader->archive, error_buffer, error_buffer_length);
        return -1;
    }

    *bytes_read = (size_t)result;
    return 0;
}

int na_archive_skip(
    NAArchiveReader *reader,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (reader == NULL || reader->archive == NULL) {
        na_copy_static_error("The archive reader is invalid.", error_buffer, error_buffer_length);
        return -1;
    }

    int status = archive_read_data_skip(reader->archive);
    if (status != ARCHIVE_OK) {
        na_copy_error(reader->archive, error_buffer, error_buffer_length);
        return -1;
    }
    return 0;
}

void na_archive_close(NAArchiveReader *reader) {
    if (reader == NULL) {
        return;
    }
    if (reader->archive != NULL) {
        archive_read_close(reader->archive);
        archive_read_free(reader->archive);
    }
    free(reader);
}
