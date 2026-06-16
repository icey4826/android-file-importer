#include "CMTPBridge.h"

#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct MTPContext {
  LIBMTP_mtpdevice_t *device;
};

static void set_error(char *buffer, size_t size, const char *message) {
  if (buffer == NULL || size == 0) return;
  snprintf(buffer, size, "%s", message == NULL ? "Unknown MTP error" : message);
}

static void set_device_error(MTPContext *context, char *buffer, size_t size,
                             const char *fallback) {
  if (context != NULL && context->device != NULL) {
    LIBMTP_error_t *error = LIBMTP_Get_Errorstack(context->device);
    if (error != NULL && error->error_text != NULL) {
      set_error(buffer, size, error->error_text);
      LIBMTP_Clear_Errorstack(context->device);
      return;
    }
  }
  set_error(buffer, size, fallback);
}

MTPContext *mtp_context_create(void) {
  LIBMTP_Init();
  return calloc(1, sizeof(MTPContext));
}

void mtp_context_destroy(MTPContext *context) {
  if (context == NULL) return;
  mtp_disconnect(context);
  free(context);
}

int mtp_connect(MTPContext *context, char *error, size_t error_size) {
  if (context == NULL) return -1;
  mtp_disconnect(context);

  LIBMTP_raw_device_t *devices = NULL;
  int count = 0;
  LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
  if (result != LIBMTP_ERROR_NONE || count == 0) {
    free(devices);
    set_error(error, error_size,
              count == 0 ? "No MTP device found. Unlock the phone and select File transfer."
                         : "Unable to scan for MTP devices.");
    return -1;
  }

  for (int index = 0; index < count; index++) {
    context->device = LIBMTP_Open_Raw_Device_Uncached(&devices[index]);
    if (context->device != NULL) break;
  }
  free(devices);

  if (context->device == NULL) {
    set_error(error, error_size, "The MTP device could not be opened.");
    return -1;
  }
  if (LIBMTP_Get_Storage(context->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
    set_device_error(context, error, error_size, "Unable to read device storage.");
    mtp_disconnect(context);
    return -1;
  }
  return 0;
}

void mtp_disconnect(MTPContext *context) {
  if (context != NULL && context->device != NULL) {
    LIBMTP_Release_Device(context->device);
    context->device = NULL;
  }
}

int mtp_is_connected(MTPContext *context) {
  return context != NULL && context->device != NULL;
}

static char *copy_device_string(MTPContext *context,
                                char *(*getter)(LIBMTP_mtpdevice_t *)) {
  if (!mtp_is_connected(context)) return NULL;
  char *source = getter(context->device);
  if (source == NULL) return NULL;
  char *copy = strdup(source);
  LIBMTP_FreeMemory(source);
  return copy;
}

char *mtp_copy_device_name(MTPContext *context) {
  return copy_device_string(context, LIBMTP_Get_Modelname);
}

char *mtp_copy_device_serial(MTPContext *context) {
  return copy_device_string(context, LIBMTP_Get_Serialnumber);
}

void mtp_string_free(char *value) { free(value); }

int mtp_copy_storages(MTPContext *context, MTPStorage **storages, size_t *count,
                      char *error, size_t error_size) {
  if (!mtp_is_connected(context) || storages == NULL || count == NULL) {
    set_error(error, error_size, "No MTP device is connected.");
    return -1;
  }

  size_t total = 0;
  for (LIBMTP_devicestorage_t *item = context->device->storage; item; item = item->next) total++;
  MTPStorage *result = calloc(total, sizeof(MTPStorage));
  if (total > 0 && result == NULL) {
    set_error(error, error_size, "Out of memory while reading storage.");
    return -1;
  }

  size_t index = 0;
  for (LIBMTP_devicestorage_t *item = context->device->storage; item; item = item->next) {
    result[index].id = item->id;
    result[index].capacity = item->MaxCapacity;
    result[index].free_space = item->FreeSpaceInBytes;
    const char *name = item->StorageDescription ? item->StorageDescription : "Internal storage";
    result[index].name = strdup(name);
    index++;
  }
  *storages = result;
  *count = total;
  return 0;
}

void mtp_storages_free(MTPStorage *storages, size_t count) {
  if (storages == NULL) return;
  for (size_t index = 0; index < count; index++) free(storages[index].name);
  free(storages);
}

int mtp_copy_children(MTPContext *context, uint32_t storage_id, uint32_t parent_id,
                      MTPObject **objects, size_t *count, char *error, size_t error_size) {
  if (!mtp_is_connected(context) || objects == NULL || count == NULL) {
    set_error(error, error_size, "No MTP device is connected.");
    return -1;
  }

  uint32_t query_parent = parent_id == 0 ? LIBMTP_FILES_AND_FOLDERS_ROOT : parent_id;
  LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(context->device, storage_id, query_parent);
  if (files == NULL && LIBMTP_Get_Errorstack(context->device) != NULL) {
    set_device_error(context, error, error_size, "Unable to list this folder.");
    return -1;
  }

  size_t total = 0;
  for (LIBMTP_file_t *item = files; item; item = item->next) total++;
  MTPObject *result = calloc(total, sizeof(MTPObject));
  if (total > 0 && result == NULL) {
    while (files) { LIBMTP_file_t *next = files->next; LIBMTP_destroy_file_t(files); files = next; }
    set_error(error, error_size, "Out of memory while listing files.");
    return -1;
  }

  size_t index = 0;
  while (files) {
    LIBMTP_file_t *next = files->next;
    result[index].id = files->item_id;
    result[index].parent_id = files->parent_id;
    result[index].storage_id = files->storage_id;
    result[index].size = files->filesize;
    result[index].modified_at = files->modificationdate;
    result[index].is_folder = files->filetype == LIBMTP_FILETYPE_FOLDER;
    result[index].name = strdup(files->filename ? files->filename : "Untitled");
    LIBMTP_destroy_file_t(files);
    files = next;
    index++;
  }
  *objects = result;
  *count = total;
  return 0;
}

void mtp_objects_free(MTPObject *objects, size_t count) {
  if (objects == NULL) return;
  for (size_t index = 0; index < count; index++) free(objects[index].name);
  free(objects);
}

int mtp_copy_thumbnail(MTPContext *context, uint32_t object_id,
                       unsigned char **bytes, size_t *size,
                       char *error, size_t error_size) {
  if (!mtp_is_connected(context) || bytes == NULL || size == NULL) return -1;
  unsigned char *data = NULL;
  unsigned int length = 0;
  if (LIBMTP_Get_Thumbnail(context->device, object_id, &data, &length) != 0) {
    LIBMTP_Clear_Errorstack(context->device);
    set_error(error, error_size, "No thumbnail is available for this item.");
    return -1;
  }
  *bytes = data;
  *size = length;
  return 0;
}

void mtp_bytes_free(unsigned char *bytes) { LIBMTP_FreeMemory(bytes); }

typedef struct {
  MTPProgressCallback callback;
  void *user_data;
} ProgressBox;

static int progress_bridge(uint64_t completed, uint64_t total, const void *data) {
  ProgressBox *box = (ProgressBox *)data;
  return box->callback ? box->callback(completed, total, box->user_data) : 0;
}

int mtp_download(MTPContext *context, uint32_t object_id, const char *destination,
                 MTPProgressCallback progress, void *user_data,
                 char *error, size_t error_size) {
  if (!mtp_is_connected(context)) {
    set_error(error, error_size, "The phone disconnected.");
    return -1;
  }
  ProgressBox box = {progress, user_data};
  int result = LIBMTP_Get_File_To_File(context->device, object_id, destination,
                                       progress_bridge, &box);
  if (result != 0) {
    set_device_error(context, error, error_size, "The file transfer failed.");
    return -1;
  }
  return 0;
}
