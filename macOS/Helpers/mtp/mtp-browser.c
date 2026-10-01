// Read-only MTP bridge. stdout is one JSON document; library diagnostics use stderr.
#include <libmtp.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static FILE *json;

static void string(const char *value) {
    fputc('"', json);
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') fprintf(json, "\\%c", *p);
        else if (*p < 0x20) fprintf(json, "\\u%04x", *p);
        else fputc(*p, json);
    }
    fputc('"', json);
}

static void device_key(const LIBMTP_raw_device_t *raw, char *key, size_t capacity) {
    snprintf(key, capacity, "%" PRIu32 "-%u-%04x-%04x", raw->bus_location,
             raw->devnum, raw->device_entry.vendor_id, raw->device_entry.product_id);
}

static int number(const char *text, uint64_t maximum, uint64_t *result) {
    if (!text || !*text || *text == '-' || *text == '+') return 0;
    char *end;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || *end || value > maximum) return 0;
    *result = value;
    return 1;
}

static int list(LIBMTP_mtpdevice_t *device, uint32_t storage, uint32_t parent) {
    if (LIBMTP_Get_Storage(device, 0) != 0) return 3;
    if (storage == 0) {
        // Locked phones can expose no storage. Do not present that as an empty disk.
        if (!device->storage) return 2;
        fputs("{\"entries\":[", json);
        int comma = 0;
        for (LIBMTP_devicestorage_t *s = device->storage; s; s = s->next) {
            if (comma++) fputc(',', json);
            fprintf(json, "{\"objectID\":4294967295,\"storageID\":%" PRIu32 ",\"name\":", s->id);
            string(s->StorageDescription && *s->StorageDescription ? s->StorageDescription : "存储空间");
            fprintf(json, ",\"isDirectory\":true,\"isStorage\":true,\"size\":%" PRIu64
                    ",\"modified\":0}", s->MaxCapacity);
        }
        fputs("]}\n", json);
        return 0;
    }
    int found = 0;
    for (LIBMTP_devicestorage_t *s = device->storage; s; s = s->next) if (s->id == storage) found = 1;
    if (!found) return 4;
    if (parent != UINT32_MAX) {
        LIBMTP_file_t *folder = LIBMTP_Get_Filemetadata(device, parent);
        int valid = folder && folder->storage_id == storage && folder->filetype == LIBMTP_FILETYPE_FOLDER;
        if (folder) LIBMTP_destroy_file_t(folder);
        if (!valid) return 4;
    }
    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage, parent);
    // A null list without an error is a valid empty directory. Any error makes
    // even a partial list unusable, otherwise a disconnected device looks empty.
    int failed = LIBMTP_Get_Errorstack(device) != NULL;
    if (!failed) fputs("{\"entries\":[", json);
    int comma = 0;
    while (files) {
        LIBMTP_file_t *file = files;
        files = file->next;
        if (!failed) {
            if (comma++) fputc(',', json);
            fprintf(json, "{\"objectID\":%" PRIu32 ",\"storageID\":%" PRIu32 ",\"name\":",
                    file->item_id, file->storage_id);
            string(file->filename);
            fprintf(json, ",\"isDirectory\":%s,\"isStorage\":false,\"size\":%" PRIu64
                    ",\"modified\":%" PRId64 "}",
                    file->filetype == LIBMTP_FILETYPE_FOLDER ? "true" : "false",
                    file->filesize, (int64_t)file->modificationdate);
        }
        LIBMTP_destroy_file_t(file);
    }
    if (failed) return 3;
    fputs("]}\n", json);
    return 0;
}

static int download(LIBMTP_mtpdevice_t *device, uint32_t storage, uint32_t object,
                    const char *name, uint64_t size, const char *modified, const char *path) {
    LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(device, object);
    char timestamp[32];
    snprintf(timestamp, sizeof(timestamp), "%" PRId64, file ? (int64_t)file->modificationdate : 0);
    int valid = file && file->filetype != LIBMTP_FILETYPE_FOLDER && file->storage_id == storage
        && file->filename && strcmp(file->filename, name) == 0 && file->filesize == size
        && strcmp(timestamp, modified) == 0;
    if (file) LIBMTP_destroy_file_t(file);
    if (!valid) return 4;
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0) return 6;
    int result = LIBMTP_Get_File_To_File_Descriptor(device, object, fd, NULL, NULL);
    struct stat info;
    int complete = result == 0 && fstat(fd, &info) == 0 && info.st_size >= 0
        && (uint64_t)info.st_size == size;
    if (close(fd) != 0) complete = 0;
    if (!complete) { unlink(path); return 3; }
    fputs("{}\n", json);
    return 0;
}

int main(int argc, char **argv) {
    int scanning = argc == 2 && strcmp(argv[1], "devices") == 0;
    int listing = argc == 5 && strcmp(argv[1], "list") == 0;
    int downloading = argc == 9 && strcmp(argv[1], "download") == 0;
    if (!scanning && !listing && !downloading) return 64;
    uint64_t storage = 0, object = 0, size = 0;
    if (!scanning && (!number(argv[3], UINT32_MAX, &storage) || !number(argv[4], UINT32_MAX, &object))) return 64;
    if (downloading && !number(argv[6], INT64_MAX, &size)) return 64;
    // libmtp prints some discovery messages to stdout; keep JSON on its own fd.
    int output = dup(STDOUT_FILENO);
    if (output < 0) return 6;
    json = fdopen(output, "w");
    if (!json || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 6;
    LIBMTP_Init();
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t error = LIBMTP_Detect_Raw_Devices(&raw, &count);
    if (error != LIBMTP_ERROR_NONE && error != LIBMTP_ERROR_NO_DEVICE_ATTACHED) { free(raw); return 2; }
    if (scanning) {
        fputs("{\"devices\":[", json);
        for (int i = 0; i < count; ++i) {
            char key[80];
            device_key(&raw[i], key, sizeof(key));
            if (i) fputc(',', json);
            fputs("{\"id\":", json); string(key);
            fputs(",\"name\":", json);
            string(raw[i].device_entry.product ? raw[i].device_entry.product : "MTP 设备");
            fputc('}', json);
        }
        fputs("]}\n", json);
        free(raw);
        return fclose(json) == 0 ? 0 : 6;
    }
    LIBMTP_mtpdevice_t *device = NULL;
    for (int i = 0; i < count; ++i) {
        char key[80];
        device_key(&raw[i], key, sizeof(key));
        if (strcmp(key, argv[2]) == 0) { device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]); break; }
    }
    free(raw);
    if (!device) return 2;
    LIBMTP_Clear_Errorstack(device);
    int result = listing ? list(device, (uint32_t)storage, (uint32_t)object)
        : download(device, (uint32_t)storage, (uint32_t)object, argv[5], size, argv[7], argv[8]);
    if (result) LIBMTP_Dump_Errorstack(device);
    LIBMTP_Release_Device(device);
    if (fclose(json) != 0 && result == 0) result = 6;
    return result;
}
