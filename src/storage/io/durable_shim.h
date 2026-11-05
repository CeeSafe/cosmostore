/* durable_shim.h: prototypes for durable_shim.c (contract in that file and ADR-002). */
#ifndef COSMO_DURABLE_SHIM_H
#define COSMO_DURABLE_SHIM_H
#include <stddef.h>
#include <stdint.h>
int32_t cosmo_open(const char *path, int32_t flags);
int32_t cosmo_close(int32_t fd);
int64_t cosmo_pread(int32_t fd, uint8_t *buf, size_t len, uint64_t offset);
int64_t cosmo_pwrite_all(int32_t fd, const uint8_t *buf, size_t len, uint64_t offset);
int32_t cosmo_sync_data(int32_t fd);
int32_t cosmo_sync_dir(const char *path);
int64_t cosmo_size(int32_t fd);
int32_t cosmo_truncate(int32_t fd, uint64_t length);
int32_t cosmo_rename(const char *from, const char *to);
int32_t cosmo_unlink(const char *path);
int32_t cosmo_mkdir(const char *path);
#endif
