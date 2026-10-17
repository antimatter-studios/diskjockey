/*
 * Shared host/DriverKit IPC types recovered from feat/driverkit-virtual-disk
 * (df5f5d1). The request and list layouts and selector values are preserved.
 * This contract describes read-only media; it has no writable mount option.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A uint64_t typedef preserves the prototype's selector width in C11 too;
 * fixed-underlying-type enums are not portable C until C23. */
typedef uint64_t DJVirtualDiskSelector;
enum {
    kDJSelectorMountImage = 0,   /* DJMountRequest in; one device ID out. */
    kDJSelectorUnmountImage = 1, /* One device ID in; no output. */
    kDJSelectorListMounts = 2,   /* DJMountInfo array out. */
};

typedef struct DJMountRequest {
    char path[1024];          /* Absolute, NUL-terminated image path. */
    uint64_t partOffset;     /* Byte offset in the decoded virtual image. */
    uint64_t partLength;     /* Zero means whole image, with offset zero. */
    uint32_t blockSize;      /* 0 defaults to 512; 512 and 4096 are supported. */
    uint32_t _pad;           /* Reserved; callers must initialize to zero. */
} DJMountRequest;

typedef struct DJMountInfo {
    uint64_t deviceID;
    char bsdName[32];
    char path[1024];
} DJMountInfo;

#define kDJMaxVirtualDisks 16

/* Local validated geometry, not a wire payload. The block count is
 * byteLength / blockSize; byteOffset applies to every backend read. */
typedef struct DJMountGeometry {
    uint64_t byteOffset;
    uint64_t byteLength;
    uint32_t blockSize;
} DJMountGeometry;

/* Validate a complete, aligned local request copy. The user client must
 * check the payload size before copying it, and validate its scalar counts
 * before publishing a child. virtualSize is the decoded image capacity,
 * never the compressed container's on-disk length. Failure leaves geometry
 * unchanged. File authorization and per-I/O bounds remain the caller's job. */
static inline bool DJMountRequestGetGeometry(
    const DJMountRequest *request,
    size_t requestSize,
    uint64_t virtualSize,
    DJMountGeometry *geometry)
{
    if (!request || !geometry || requestSize != sizeof(*request)) return false;
    if (request->_pad != 0 || request->path[0] != '/' ||
        !memchr(request->path, '\0', sizeof(request->path))) return false;

    const uint32_t blockSize = request->blockSize ? request->blockSize : 512;
    if (blockSize != 512 && blockSize != 4096) return false;
    if (request->partLength == 0 && request->partOffset != 0) return false;

    const uint64_t length = request->partLength ? request->partLength : virtualSize;
    /* Subtraction after the offset check avoids an overflowing end offset. */
    if (request->partOffset > virtualSize || length == 0 ||
        length > virtualSize - request->partOffset ||
        request->partOffset % blockSize != 0 || length % blockSize != 0) return false;

    geometry->byteOffset = request->partOffset;
    geometry->byteLength = length;
    geometry->blockSize = blockSize;
    return true;
}

#ifdef __cplusplus
}
#endif
