#pragma once
/* Private types shared across DiskJockeyVirtualDisk .cpp files. Not included
 * by DiskJockeyAgent or the app — use DJVirtualDiskShared.h for IPC types. */

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include "DJVirtualDiskShared.h"

/* -------------------------------------------------------------------------
 * Instance variable structs
 *
 * Phase-1: raw file I/O via POSIX fd. No Rust libs in the dext — QCOW2/VHDX
 * decompression lives in the app process and will be bridged via IPC in Phase 2.
 * ------------------------------------------------------------------------- */

class DJVirtualDiskDevice;

struct DJVirtualDiskService_IVars {
    uint64_t             deviceIDs[kDJMaxVirtualDisks];
    DJVirtualDiskDevice* devices[kDJMaxVirtualDisks];
    uint64_t             nextDeviceID;
    IOLock*              lock;
};

struct DJVirtualDiskDevice_IVars {
    int      fd;          /* POSIX file descriptor for the raw image */
    uint64_t sizeBytes;
    uint32_t blockSize;
    uint64_t deviceID;
    char     imagePath[1024];
};

struct DJVirtualDiskUserClient_IVars {
    /* weak ref to provider — valid for the client's lifetime */
    void* service;
};
