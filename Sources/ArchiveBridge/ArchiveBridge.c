#include "ArchiveBridge.h"
#include "SystemArchive.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <unistd.h>

static int fail(char *error, int capacity, const char *message) {
    snprintf(error, capacity, "%s", message ? message : "Archive error");
    return -1;
}
static int safe_path(const char *path) {
    if (!path || !*path || *path == '/' || strchr(path, '\\')) return 0;
    const char *p = path;
    while (*p) {
        const char *end = strchr(p, '/');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        if (n == 2 && p[0] == '.' && p[1] == '.') return 0;
        if (!end) break;
        p = end + 1;
    }
    return 1;
}
static int make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(path, 0700); *p = '/'; }
    }
    return 0;
}
int sp_extract(const char *source, const char *destination, char *error, int capacity) {
    struct archive *a = archive_read_new();
    archive_read_support_format_zip(a);
    int result = 0, status, count = 0;
    long long total = 0;
    if (archive_read_open_filename(a, source, 65536) != ARCHIVE_OK) {
        result = fail(error, capacity, archive_error_string(a)); goto done;
    }
    struct archive_entry *entry;
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if (!safe_path(name) || archive_entry_symlink(entry) || archive_entry_hardlink(entry) || ++count > 20000) {
            result = fail(error, capacity, "Unsafe or oversized presentation archive"); break;
        }
        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s/%s", destination, name) >= sizeof(path)) {
            result = fail(error, capacity, "Archive path too long"); break;
        }
        make_parents(path);
        if (archive_entry_filetype(entry) == AE_IFDIR) { mkdir(path, 0700); continue; }
        if (archive_entry_filetype(entry) != AE_IFREG) { result = fail(error, capacity, "Unsupported archive entry"); break; }
        FILE *f = fopen(path, "wb");
        if (!f) { result = fail(error, capacity, "Cannot extract presentation"); break; }
        char buffer[65536]; ssize_t size;
        while ((size = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
            total += size;
            if (total > 1024LL * 1024 * 1024 || fwrite(buffer, 1, size, f) != size) { result = fail(error, capacity, "Presentation exceeds 1 GB or disk is full"); break; }
        }
        fclose(f);
        if (size < 0) result = fail(error, capacity, archive_error_string(a));
        if (result) break;
    }
    if (!result && status != ARCHIVE_EOF) result = fail(error, capacity, archive_error_string(a));
done:
    archive_read_free(a);
    return result;
}
static int pack_directory(struct archive *a, const char *root, const char *relative, char *error, int capacity) {
    char folder[PATH_MAX]; snprintf(folder, sizeof(folder), "%s/%s", root, relative);
    DIR *dir = opendir(folder);
    if (!dir) return fail(error, capacity, "Cannot read presentation folder");
    struct dirent *item; int result = 0;
    while ((item = readdir(dir))) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        char name[PATH_MAX], path[PATH_MAX];
        if (snprintf(name, sizeof(name), "%s%s%s", relative, *relative ? "/" : "", item->d_name) >= sizeof(name) ||
            snprintf(path, sizeof(path), "%s/%s", root, name) >= sizeof(path)) { result = fail(error, capacity, "Path too long"); break; }
        struct stat st;
        if (lstat(path, &st)) { result = fail(error, capacity, "Cannot read file"); break; }
        if (S_ISDIR(st.st_mode)) { result = pack_directory(a, root, name, error, capacity); if (result) break; continue; }
        if (!S_ISREG(st.st_mode)) { result = fail(error, capacity, "Unsupported file"); break; }
        struct archive_entry *entry = archive_entry_new();
        archive_entry_set_pathname(entry, name); archive_entry_set_size(entry, st.st_size);
        archive_entry_set_filetype(entry, AE_IFREG); archive_entry_set_perm(entry, 0644);
        int status = archive_write_header(a, entry); archive_entry_free(entry);
        if (status != ARCHIVE_OK) { result = fail(error, capacity, archive_error_string(a)); break; }
        FILE *f = fopen(path, "rb");
        if (!f) { result = fail(error, capacity, "Cannot read file"); break; }
        char buffer[65536]; size_t size;
        while ((size = fread(buffer, 1, sizeof(buffer), f))) {
            if (archive_write_data(a, buffer, size) != size) { result = fail(error, capacity, archive_error_string(a)); break; }
        }
        if (ferror(f)) result = fail(error, capacity, "File read failed");
        fclose(f); if (result) break;
    }
    closedir(dir); return result;
}
int sp_pack(const char *directory, const char *destination, char *error, int capacity) {
    struct archive *a = archive_write_new(); archive_write_set_format_zip(a);
    archive_write_set_options(a, "zip:compression=deflate");
    int result;
    if (archive_write_open_filename(a, destination) != ARCHIVE_OK) result = fail(error, capacity, archive_error_string(a));
    else result = pack_directory(a, directory, "", error, capacity);
    if (archive_write_close(a) != ARCHIVE_OK && !result) result = fail(error, capacity, archive_error_string(a));
    archive_write_free(a); return result;
}
