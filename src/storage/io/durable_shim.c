/*
 * durable_shim.c: the POSIX durable-file primitives CosmoStore needs and CeeSafe's
 * standard library does not yet provide (see CEESAFE_GAPS.md, G1-G6).
 *
 * Contract (ADR-002), shared by every function here:
 *  - Paths are NUL-terminated byte strings owned by the caller for the duration of
 *    the call. Nothing here keeps a pointer after returning.
 *  - Buffers are (pointer, length) pairs owned by the caller; length may be 0.
 *  - A file descriptor is an int32 >= 0 returned by cosmo_open and owned by the
 *    caller until it is passed to cosmo_close exactly once.
 *  - Errors are returned as a negative errno value (-EIO, -ENOSPC, ...). Success is
 *    >= 0. EINTR is retried here and never returned.
 *  - Nothing here allocates.
 *
 * This file is temporary: it is replaced by CeeSafe standard-library APIs once they
 * exist. Keep it small and audited.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdio.h> /* rename */
#include "durable_shim.h"

/* Open flags understood by cosmo_open. */
#define COSMO_O_READ    0x1  /* read only */
#define COSMO_O_RW      0x2  /* read and write */
#define COSMO_O_CREATE  0x4  /* create if missing */
#define COSMO_O_EXCL    0x8  /* fail with -EEXIST if it exists */

int32_t cosmo_open(const char *path, int32_t flags) {
    int oflags = O_CLOEXEC;
    if (flags & COSMO_O_RW) oflags |= O_RDWR; else oflags |= O_RDONLY;
    if (flags & COSMO_O_CREATE) oflags |= O_CREAT;
    if (flags & COSMO_O_EXCL) oflags |= O_EXCL;
    for (;;) {
        int fd = open(path, oflags, 0644);
        if (fd >= 0) return fd;
        if (errno != EINTR) return -errno;
    }
}

int32_t cosmo_close(int32_t fd) {
    /* close is not retried on EINTR: on Linux and macOS the descriptor is gone. */
    return close(fd) == 0 ? 0 : -errno;
}

/* Reads up to len bytes at offset; returns bytes read (0 at end of file). */
int64_t cosmo_pread(int32_t fd, uint8_t *buf, size_t len, uint64_t offset) {
    for (;;) {
        ssize_t n = pread(fd, buf, len, (off_t)offset);
        if (n >= 0) return (int64_t)n;
        if (errno != EINTR) return -errno;
    }
}

/* Writes exactly len bytes at offset, or fails; returns len. */
int64_t cosmo_pwrite_all(int32_t fd, const uint8_t *buf, size_t len, uint64_t offset) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(fd, buf + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) return -EIO;
        done += (size_t)n;
    }
    return (int64_t)len;
}

/*
 * Makes the file's data and the metadata needed to read it durable.
 * macOS: fsync() does not flush the drive's write cache; F_FULLFSYNC does.
 * Linux: fdatasync() is enough for data plus size.
 */
int32_t cosmo_sync_data(int32_t fd) {
#if defined(__APPLE__)
    if (fcntl(fd, F_FULLFSYNC) == 0) return 0;
    /* Some filesystems (network, FUSE) do not support F_FULLFSYNC. */
    if (errno != ENOTSUP && errno != EINVAL) return -errno;
    return fsync(fd) == 0 ? 0 : -errno;
#elif defined(__linux__)
    for (;;) {
        if (fdatasync(fd) == 0) return 0;
        if (errno != EINTR) return -errno;
    }
#else
    return fsync(fd) == 0 ? 0 : -errno;
#endif
}

/* Makes a directory's entries (created, renamed, removed files) durable. */
int32_t cosmo_sync_dir(const char *path) {
    int fd;
    for (;;) {
        fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd >= 0) break;
        if (errno != EINTR) return -errno;
    }
    int32_t r = cosmo_sync_data(fd);
    close(fd);
    return r;
}

/* The file's current size in bytes. */
int64_t cosmo_size(int32_t fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -errno;
    return (int64_t)st.st_size;
}

int32_t cosmo_truncate(int32_t fd, uint64_t length) {
    for (;;) {
        if (ftruncate(fd, (off_t)length) == 0) return 0;
        if (errno != EINTR) return -errno;
    }
}

/* Atomically replaces `to` with `from` (POSIX rename). The caller syncs the directory. */
int32_t cosmo_rename(const char *from, const char *to) {
    return rename(from, to) == 0 ? 0 : -errno;
}

/* Removes a file; a missing file is -ENOENT. */
int32_t cosmo_unlink(const char *path) {
    return unlink(path) == 0 ? 0 : -errno;
}

/* Creates a directory; an existing one is -EEXIST. */
int32_t cosmo_mkdir(const char *path) {
    return mkdir(path, 0755) == 0 ? 0 : -errno;
}
