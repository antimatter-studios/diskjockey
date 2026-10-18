#include <DriverKit/IOLib.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <new>
#include <string.h>

#include "DJVirtualDiskDevice.h"
#include "DJVirtualDiskBlockIO.h"
#include "DJVirtualDiskShared.h"

static constexpr size_t kDJDeviceOutstanding = 16;
using DJDeviceBlockIO = DJBlockIO<kDJDeviceOutstanding>;

struct DJVirtualDiskDevice_IVars;

// One accepted request, from submit until its one completion.
struct DJDeviceRequest {
    DJVirtualDiskDevice_IVars *ivars;
    uint32_t requestID;
    uint64_t dmaAddr;
    bool used;
};

struct DJVirtualDiskDevice_IVars {
    DJVirtualDiskDevice *device;
    uint64_t identity;
    DJMountGeometry geometry;
    DJDeviceBlockIO *io;
    DJDeviceRequest requests[kDJDeviceOutstanding];
};

static kern_return_t DJDeviceStatus(DJBlockIOResult result)
{
    switch (result) {
    case DJBlockIOResult::Success: return kIOReturnSuccess;
    case DJBlockIOResult::BadArgument: return kIOReturnBadArgument;
    case DJBlockIOResult::OutOfRange: return kIOReturnOverrun;
    case DJBlockIOResult::ReadOnly: return kIOReturnNotWritable;
    case DJBlockIOResult::Busy: return kIOReturnBusy;
    case DJBlockIOResult::NotReady: return kIOReturnNotReady;
    case DJBlockIOResult::Timeout: return kIOReturnTimeout;
    case DJBlockIOResult::IOFailure:
    case DJBlockIOResult::ShortRead: return kIOReturnIOError;
    }
    return kIOReturnIOError;
}

// bytes is non-null only on Success, exactly the requested length.
static void DJDeviceCompleted(void *context, DJBlockIOResult result, const void *bytes, size_t length)
{
    auto *request = static_cast<DJDeviceRequest *>(context);
    const DJDeviceRequest done = *request;
    request->used = false;
    if (result == DJBlockIOResult::Success)
        memcpy(reinterpret_cast<void *>(done.dmaAddr), bytes, length);
    done.ivars->device->CompleteIO(done.requestID, result == DJBlockIOResult::Success ? length : 0,
                                   DJDeviceStatus(result));
}

static bool DJDeviceNumber(OSDictionary *properties, const char *key, uint64_t *value)
{
    auto *number = OSDynamicCast(OSNumber, properties->getObject(key));
    if (!number) return false;
    *value = number->unsigned64BitValue();
    return true;
}

static void DJDeviceString(struct DeviceString *string, const char *text)
{
    if (string) strlcpy(string->data, text, sizeof(string->data));
}

bool DJVirtualDiskDevice::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(DJVirtualDiskDevice_IVars, 1);
    return ivars != nullptr;
}

void DJVirtualDiskDevice::free()
{
    IOSafeDeleteNULL(ivars, DJVirtualDiskDevice_IVars, 1);
    super::free();
}

kern_return_t IMPL(DJVirtualDiskDevice, Start)
{
    // The identity and geometry come from the publish hook's properties; a
    // child without both serves nothing.
    OSDictionary *properties = nullptr;
    kern_return_t result = CopyProperties(&properties);
    if (result != kIOReturnSuccess) return result;
    uint64_t identity = 0, offset = 0, length = 0, block = 0;
    const bool complete = DJDeviceNumber(properties, kDJAttachmentIdentityKey, &identity) &&
        DJDeviceNumber(properties, kDJDeviceByteOffsetKey, &offset) &&
        DJDeviceNumber(properties, kDJDeviceByteLengthKey, &length) &&
        DJDeviceNumber(properties, kDJDeviceBlockSizeKey, &block);
    OSSafeReleaseNULL(properties);
    if (!complete || !identity || block > UINT32_MAX) return kIOReturnBadArgument;

    ivars->device = this;
    ivars->identity = identity;
    ivars->geometry = {offset, length, uint32_t(block)};
    void *memory = IOMallocZero(sizeof(DJDeviceBlockIO));
    if (!memory) return kIOReturnNoMemory;
    // No read backend yet: every read is refused NotReady, and compressed
    // container bytes are never served as raw disk bytes.
    ivars->io = new (memory) DJDeviceBlockIO(ivars->geometry, DJBlockReadBackend{nullptr, nullptr});
    if (!ivars->io->blockCount()) {
        ivars->io->~DJDeviceBlockIO();
        IOFree(memory, sizeof(DJDeviceBlockIO));
        ivars->io = nullptr;
        return kIOReturnBadArgument;
    }

    result = super::Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;
    // The identity on the child's own registry entry is what the agent's
    // matcher finds in the IOMedia ancestry.
    OSDictionary *published = OSDictionary::withCapacity(1);
    OSNumber *number = OSNumber::withNumber(identity, 64);
    if (published && number && published->setObject(kDJAttachmentIdentityKey, number))
        result = SetProperties(published);
    else
        result = kIOReturnNoMemory;
    OSSafeReleaseNULL(number);
    OSSafeReleaseNULL(published);
    if (result == kIOReturnSuccess) result = RegisterDext();
    if (result != kIOReturnSuccess) Stop(provider, SUPERDISPATCH);
    return result;
}

kern_return_t IMPL(DJVirtualDiskDevice, Stop)
{
    // Terminating the child completes every pending read, then releases the
    // state Start allocated.
    if (ivars->io) {
        ivars->io->failAll(DJBlockIOResult::IOFailure);
        ivars->io->~DJDeviceBlockIO();
        IOFree(ivars->io, sizeof(DJDeviceBlockIO));
        ivars->io = nullptr;
    }
    return super::Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncReadWrite)
{
    (void)size;
    (void)options;
    DJDeviceRequest *request = nullptr;
    for (auto &candidate : ivars->requests)
        if (!candidate.used) { request = &candidate; break; }
    DJBlockIOResult result = DJBlockIOResult::NotReady;
    if (!ivars->io) {
        result = DJBlockIOResult::NotReady;
    } else if (!request) {
        result = DJBlockIOResult::Busy;
    } else {
        *request = {ivars, requestID, dmaAddr, true};
        result = ivars->io->submit(isRead ? DJBlockIOKind::Read : DJBlockIOKind::Write, lba,
                                   numOfBlocks, DJDeviceCompleted, request);
        // Success hands the request to the core, which completes it once.
        if (result == DJBlockIOResult::Success) return kIOReturnSuccess;
        request->used = false;
    }
    CompleteIO(requestID, 0, DJDeviceStatus(result));
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncEjectMedia)
{
    Complete(requestID, kIOReturnSuccess);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, DoAsyncSynchronize)
{
    // Read-only media has nothing to flush.
    (void)lba;
    (void)numOfBlocks;
    Complete(requestID, kIOReturnSuccess);
    return kIOReturnSuccess;
}

kern_return_t DJVirtualDiskDevice::DoAsyncUnmapPriv(uint32_t requestID, struct BlockRange *ranges,
                                                   uint32_t numOfRanges)
{
    (void)ranges;
    (void)numOfRanges;
    Complete(requestID, kIOReturnNotWritable);
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetDeviceParams)
{
    if (!deviceParams || !ivars->io) return kIOReturnBadArgument;
    memset(deviceParams, 0, sizeof(*deviceParams));
    deviceParams->numOfBlocks = ivars->io->blockCount();
    deviceParams->blockSize = ivars->geometry.blockSize;
    // The read transport never clamps, so no request may exceed it.
    deviceParams->maxIOSize = kDJReadMaxBytes;
    deviceParams->numOfOutstandingIOs = kDJDeviceOutstanding;
    deviceParams->maxNumOfUnmapRegions = 0;
    deviceParams->minSegmentAlignment = 1;
    deviceParams->numOfAddressBits = 64;
    deviceParams->isUnmapSupported = false;
    deviceParams->isFUASupported = false;
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetVendorString)
{
    DJDeviceString(vendor, "DiskJockey");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetProductString)
{
    DJDeviceString(product, "Disk Image");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetRevisionString)
{
    DJDeviceString(revision, "1.0");
    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskDevice, GetAdditionalInfoString)
{
    DJDeviceString(additionalInfo, "");
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
    *isWriteProtected = true;
    return kIOReturnSuccess;
}
