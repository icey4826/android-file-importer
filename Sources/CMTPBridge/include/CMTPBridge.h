#ifndef C_MTP_BRIDGE_H
#define C_MTP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MTPContext MTPContext;

typedef struct {
  uint32_t id;
  uint64_t capacity;
  uint64_t free_space;
  char *name;
} MTPStorage;

typedef struct {
  uint32_t id;
  uint32_t parent_id;
  uint32_t storage_id;
  uint64_t size;
  int64_t modified_at;
  int is_folder;
  char *name;
} MTPObject;

typedef int (*MTPProgressCallback)(uint64_t completed, uint64_t total, void *user_data);

MTPContext *mtp_context_create(void);
void mtp_context_destroy(MTPContext *context);

int mtp_connect(MTPContext *context, char *error, size_t error_size);
void mtp_disconnect(MTPContext *context);
int mtp_is_connected(MTPContext *context);

char *mtp_copy_device_name(MTPContext *context);
char *mtp_copy_device_serial(MTPContext *context);
void mtp_string_free(char *value);

int mtp_copy_storages(MTPContext *context, MTPStorage **storages, size_t *count,
                      char *error, size_t error_size);
void mtp_storages_free(MTPStorage *storages, size_t count);

int mtp_copy_children(MTPContext *context, uint32_t storage_id, uint32_t parent_id,
                      MTPObject **objects, size_t *count, char *error, size_t error_size);
void mtp_objects_free(MTPObject *objects, size_t count);

int mtp_copy_thumbnail(MTPContext *context, uint32_t object_id,
                       unsigned char **bytes, size_t *size,
                       char *error, size_t error_size);
void mtp_bytes_free(unsigned char *bytes);

int mtp_download(MTPContext *context, uint32_t object_id, const char *destination,
                 MTPProgressCallback progress, void *user_data,
                 char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
