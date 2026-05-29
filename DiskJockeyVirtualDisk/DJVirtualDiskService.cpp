/* IVars must be declared before the iig-generated header pulls in the class. */
#define DJVirtualDiskService_DECLARE_IVARS \
    DJVirtualDiskService_IVars *ivars;

#include "DJVirtualDiskPriv.h"
#include "DJVirtualDiskService.h"

#define DJVirtualDiskDevice_DECLARE_IVARS \
    DJVirtualDiskDevice_IVars *ivars;
#include "DJVirtualDiskDevice.h"

#define DJVirtualDiskUserClient_DECLARE_IVARS \
    DJVirtualDiskUserClient_IVars *ivars;
#include "DJVirtualDiskUserClient.h"

#include <DriverKit/OSCollections.h>
#include <stdint.h>
#include <string.h>

/* DriverKit doesn't ship POSIX headers, but the syscalls ARE in libsystem_kernel.
   Declare only what we need. */
extern "C" {
#define O_RDONLY 0x0000
#define O_RDWR   0x0002
#define SEEK_SET 0
#define SEEK_END 2
int    open(const char* path, int flags, ...);
int    close(int fd);
typedef long long off_t;
off_t  lseek(int fd, off_t offset, int whence);
}

static uint32_t effectiveBlockSize(uint32_t requested)
{
    return (requested == 0) ? 512 : requested;
}

kern_return_t IMPL(DJVirtualDiskService, Start)
{
    kern_return_t ret = super::Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    ivars = IONewZero(DJVirtualDiskService_IVars, 1);
    if (!ivars) { Stop(provider); return kIOReturnNoMemory; }

    ivars->nextDeviceID = 1;
    ivars->lock = IOLockAlloc();
    if (!ivars->lock) { Stop(provider); return kIOReturnNoMemory; }

    RegisterService();
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskService, Stop)
{
    if (ivars) {
        if (ivars->lock) {
            IOLockLock(ivars->lock);
            for (int i = 0; i < kDJMaxVirtualDisks; i++) {
                if (ivars->deviceIDs[i] != 0 && ivars->devices[i]) {
                    DJVirtualDiskDevice* dev = ivars->devices[i];
                    ivars->deviceIDs[i] = 0;
                    ivars->devices[i]   = nullptr;
                    IOLockUnlock(ivars->lock);
                    dev->Terminate(0);
                    dev->release();
                    IOLockLock(ivars->lock);
                }
            }
            IOLockUnlock(ivars->lock);
            IOLockFree(ivars->lock);
        }
        IODelete(ivars, DJVirtualDiskService_IVars, 1);
        ivars = nullptr;
    }
    return super::Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(DJVirtualDiskService, NewUserClient)
{
    DJVirtualDiskUserClient* client = OSTypeAlloc(DJVirtualDiskUserClient);
    if (!client || !client->init()) {
        if (client) client->release();
        return kIOReturnNoMemory;
    }
    *userClient = client;
    return kIOReturnSuccess;
}

kern_return_t DJVirtualDiskService::MountImage(const DJMountRequest* req, uint64_t* outDeviceID)
{
    if (!req || !outDeviceID || req->path[0] == '\0') return kIOReturnBadArgument;

    /* Phase 1: raw POSIX open. QCOW2/VHDX requires IPC to app (Phase 2). */
    int fd = open(req->path, O_RDWR);
    if (fd < 0) {
        fd = open(req->path, O_RDONLY);
        if (fd < 0) return kIOReturnIOError;
    }

    off_t fileEnd = lseek(fd, 0, SEEK_END);
    if (fileEnd <= 0) { close(fd); return kIOReturnIOError; }
    uint64_t sizeBytes = (uint64_t)fileEnd;

    if (req->partOffset > 0 && req->partLength > 0) {
        if (req->partOffset + req->partLength > sizeBytes) {
            close(fd); return kIOReturnBadArgument;
        }
        sizeBytes = req->partLength;
    }

    IOLockLock(ivars->lock);
    int slot = -1;
    for (int i = 0; i < kDJMaxVirtualDisks; i++) {
        if (ivars->deviceIDs[i] == 0) { slot = i; break; }
    }
    if (slot < 0) { IOLockUnlock(ivars->lock); close(fd); return kIOReturnNoResources; }
    uint64_t newID = ivars->nextDeviceID++;
    if (ivars->nextDeviceID == 0) ivars->nextDeviceID = 1;
    IOLockUnlock(ivars->lock);

    DJVirtualDiskDevice* child = OSTypeAlloc(DJVirtualDiskDevice);
    if (!child || !child->init()) {
        if (child) child->release();
        close(fd);
        return kIOReturnNoMemory;
    }

    child->ivars->fd        = fd;
    child->ivars->sizeBytes = sizeBytes;
    child->ivars->blockSize = effectiveBlockSize(req->blockSize);
    child->ivars->deviceID  = newID;
    strlcpy(child->ivars->imagePath, req->path, sizeof(child->ivars->imagePath));

    if (child->Start(this) != kIOReturnSuccess) {
        child->release();
        close(fd);
        return kIOReturnError;
    }

    IOLockLock(ivars->lock);
    ivars->deviceIDs[slot] = newID;
    ivars->devices[slot]   = child;
    IOLockUnlock(ivars->lock);

    *outDeviceID = newID;
    return kIOReturnSuccess;
}

kern_return_t DJVirtualDiskService::UnmountImage(uint64_t deviceID)
{
    if (deviceID == 0) return kIOReturnBadArgument;

    IOLockLock(ivars->lock);
    int slot = -1;
    for (int i = 0; i < kDJMaxVirtualDisks; i++) {
        if (ivars->deviceIDs[i] == deviceID) { slot = i; break; }
    }
    if (slot < 0) { IOLockUnlock(ivars->lock); return kIOReturnNotFound; }
    DJVirtualDiskDevice* dev = ivars->devices[slot];
    ivars->deviceIDs[slot] = 0;
    ivars->devices[slot]   = nullptr;
    IOLockUnlock(ivars->lock);

    dev->Terminate(0);
    dev->release();
    return kIOReturnSuccess;
}

kern_return_t DJVirtualDiskService::ListMounts(DJMountInfo* outInfos, uint32_t* outCount)
{
    if (!outInfos || !outCount || *outCount == 0) return kIOReturnBadArgument;
    uint32_t capacity = *outCount, written = 0;

    IOLockLock(ivars->lock);
    for (int i = 0; i < kDJMaxVirtualDisks && written < capacity; i++) {
        if (ivars->deviceIDs[i] == 0 || !ivars->devices[i]) continue;
        DJMountInfo& info = outInfos[written++];
        info.deviceID  = ivars->deviceIDs[i];
        info.bsdName[0] = '\0';
        strlcpy(info.path, ivars->devices[i]->ivars->imagePath, sizeof(info.path));
    }
    IOLockUnlock(ivars->lock);

    *outCount = written;
    return kIOReturnSuccess;
}
