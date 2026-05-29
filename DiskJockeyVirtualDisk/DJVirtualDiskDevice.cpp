#define DJVirtualDiskDevice_DECLARE_IVARS \
    DJVirtualDiskDevice_IVars *ivars;

#include "DJVirtualDiskPriv.h"
#include "DJVirtualDiskDevice.h"

#include <stdint.h>
#include <string.h>

static constexpr uint32_t kMaxIOSize      = 1u << 20;
static constexpr uint32_t kOutstandingIOs = 32;

/* DriverKit doesn't ship POSIX headers; declare the few syscalls we need. */
extern "C" {
typedef long long  off_t;
typedef long       ssize_t;
ssize_t pread (int fd, void*       buf, size_t count, off_t offset);
ssize_t pwrite(int fd, const void* buf, size_t count, off_t offset);
int     fsync (int fd);
int     close (int fd);
}

static void uint64ToHex16(char* out, uint64_t val)
{
    const char hex[] = "0123456789ABCDEF";
    for (int i = 15; i >= 0; i--) { out[i] = hex[val & 0xF]; val >>= 4; }
    out[16] = '\0';
}

static void fillDeviceString(struct DeviceString* s, const char* str)
{
    if (!s) return;
    strlcpy(s->data, str ? str : "", sizeof(s->data));
}

kern_return_t IMPL(DJVirtualDiskDevice, Start)
{
    kern_return_t ret = super::Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    if (!ivars || ivars->fd < 0) return kIOReturnInternalError;

    ret = RegisterDext();
    if (ret != kIOReturnSuccess) return ret;

    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, Stop)
{
    if (ivars) {
        if (ivars->fd >= 0) {
            close(ivars->fd);
            ivars->fd = -1;
        }
        IODelete(ivars, DJVirtualDiskDevice_IVars, 1);
        ivars = nullptr;
    }
    return super::Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncReadWrite)
{
    if (!ivars || ivars->fd < 0) {
        CompleteIO(requestID, 0, kIOReturnNotReady);
        return kIOReturnSuccess;
    }

    auto* buf = reinterpret_cast<uint8_t*>(dmaAddr);
    off_t byteOffset = (off_t)(lba * ivars->blockSize);

    ssize_t rc;
    if (isRead) {
        rc = pread(ivars->fd, buf, (size_t)size, byteOffset);
    } else {
        rc = pwrite(ivars->fd, buf, (size_t)size, byteOffset);
    }

    if (rc == (ssize_t)size) {
        CompleteIO(requestID, (uint64_t)size, kIOReturnSuccess);
    } else {
        CompleteIO(requestID, 0, kIOReturnIOError);
    }
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncEjectMedia)
{
    Complete(requestID, kIOReturnSuccess);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncSynchronize)
{
    if (ivars && ivars->fd >= 0) fsync(ivars->fd);
    Complete(requestID, kIOReturnSuccess);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetDeviceParams)
{
    if (!deviceParams || !ivars) return kIOReturnBadArgument;
    uint64_t blockSize = ivars->blockSize ? ivars->blockSize : 512;
    deviceParams->numOfBlocks            = ivars->sizeBytes / blockSize;
    deviceParams->blockSize              = (uint32_t)blockSize;
    deviceParams->maxIOSize              = kMaxIOSize;
    deviceParams->numOfOutstandingIOs    = kOutstandingIOs;
    deviceParams->maxNumOfUnmapRegions   = 0;
    deviceParams->minSegmentAlignment    = 1;
    deviceParams->numOfAddressBits       = 64;
    deviceParams->isUnmapSupported       = false;
    deviceParams->isFUASupported         = false;
    return kIOReturnSuccess;
}

kern_return_t DJVirtualDiskDevice::DoAsyncUnmapPriv(uint32_t requestID, struct BlockRange* ranges, uint32_t numOfRanges)
{
    (void)ranges; (void)numOfRanges;
    Complete(requestID, kIOReturnSuccess);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetVendorString)
{
    fillDeviceString(vendor, "DiskJockey");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetProductString)
{
    if (!product || !ivars) return kIOReturnBadArgument;
    char buf[kMaxDeviceStringLength];
    char hex[17];
    uint64ToHex16(hex, ivars->deviceID);
    strlcpy(buf, "IMG-", sizeof(buf));
    strlcat(buf, hex, sizeof(buf));
    fillDeviceString(product, buf);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetRevisionString)
{
    fillDeviceString(revision, "1.0");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetAdditionalInfoString)
{
    fillDeviceString(additionalInfo, "");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, ReportEjectability)
{
    if (!isEjectable) return kIOReturnBadArgument;
    *isEjectable = true;
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, ReportRemovability)
{
    if (!isRemovable) return kIOReturnBadArgument;
    *isRemovable = true;
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, ReportWriteProtection)
{
    if (!isWriteProtected) return kIOReturnBadArgument;
    *isWriteProtected = false;
    return kIOReturnSuccess;
}
