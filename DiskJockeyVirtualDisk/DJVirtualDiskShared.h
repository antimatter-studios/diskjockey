/*
 * DJVirtualDiskShared.h — IPC types shared between the DiskJockeyVirtualDisk
 * DriverKit extension (C++) and DiskJockeyAgent (Swift via bridging header).
 *
 * Pure C — no C++, no Objective-C, no Swift.
 */

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum DJVirtualDiskSelector : uint64_t {
    kDJSelectorMountImage   = 0,   // structureInput: DJMountRequest, scalarOutput[0]: deviceID
    kDJSelectorUnmountImage = 1,   // scalarInput[0]: deviceID
    kDJSelectorListMounts   = 2,   // structureOutput: array of DJMountInfo
} DJVirtualDiskSelector;

typedef struct DJMountRequest {
    char     path[1024];     // null-terminated absolute UTF-8 path to the image file
    uint64_t partOffset;     // byte offset of partition within the image (0 = whole device)
    uint64_t partLength;     // byte length of partition (0 = whole device)
    uint32_t blockSize;      // preferred block size in bytes (0 → default 512)
    uint32_t _pad;
} DJMountRequest;

typedef struct DJMountInfo {
    uint64_t deviceID;       // opaque handle used by UnmountImage
    char     bsdName[32];    // BSD node name, e.g. "disk5"
    char     path[1024];     // image path used at mount time
} DJMountInfo;

#define kDJMaxVirtualDisks 16

#ifdef __cplusplus
}
#endif
