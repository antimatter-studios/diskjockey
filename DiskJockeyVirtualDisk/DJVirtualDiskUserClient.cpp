#define DJVirtualDiskService_DECLARE_IVARS \
    DJVirtualDiskService_IVars *ivars;
#define DJVirtualDiskUserClient_DECLARE_IVARS \
    DJVirtualDiskUserClient_IVars *ivars;

#include "DJVirtualDiskPriv.h"
#include "DJVirtualDiskUserClient.h"
#include "DJVirtualDiskService.h"

#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSData.h>
#include <string.h>

kern_return_t IMPL(DJVirtualDiskUserClient, Start)
{
    kern_return_t ret = super::Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    ivars = IONewZero(DJVirtualDiskUserClient_IVars, 1);
    if (!ivars) { Stop(provider); return kIOReturnNoMemory; }

    ivars->service = OSDynamicCast(DJVirtualDiskService, provider);
    if (!ivars->service) { Stop(provider); return kIOReturnBadArgument; }

    return kIOReturnSuccess;
}

kern_return_t IMPL(DJVirtualDiskUserClient, Stop)
{
    if (ivars) {
        IODelete(ivars, DJVirtualDiskUserClient_IVars, 1);
        ivars = nullptr;
    }
    return super::Stop(provider, SUPERDISPATCH);
}

/* ExternalMethod is LOCALONLY in IOUserClient — implemented as plain C++ override */
kern_return_t DJVirtualDiskUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments* arguments,
    const IOUserClientMethodDispatch* dispatch,
    OSObject* target,
    void* reference)
{
    auto* svc = static_cast<DJVirtualDiskService*>(ivars ? ivars->service : nullptr);
    if (!svc || !arguments) return kIOReturnNotReady;

    switch ((DJVirtualDiskSelector)selector) {

    case kDJSelectorMountImage: {
        OSData* structIn = arguments->structureInput;
        if (!structIn || structIn->getLength() < sizeof(DJMountRequest))
            return kIOReturnBadArgument;
        const DJMountRequest* req =
            reinterpret_cast<const DJMountRequest*>(structIn->getBytesNoCopy());
        uint64_t deviceID = 0;
        kern_return_t ret = svc->MountImage(req, &deviceID);
        if (ret != kIOReturnSuccess) return ret;
        if (arguments->scalarOutput && arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = deviceID;
            arguments->scalarOutputCount = 1;
        }
        return kIOReturnSuccess;
    }

    case kDJSelectorUnmountImage: {
        if (arguments->scalarInputCount < 1) return kIOReturnBadArgument;
        return svc->UnmountImage(arguments->scalarInput[0]);
    }

    case kDJSelectorListMounts: {
        uint64_t maxBytes = arguments->structureOutputMaximumSize;
        if (maxBytes < sizeof(DJMountInfo)) return kIOReturnBadArgument;
        uint32_t capacity = (uint32_t)(maxBytes / sizeof(DJMountInfo));
        auto* infos = IONewZero(DJMountInfo, capacity);
        if (!infos) return kIOReturnNoMemory;
        kern_return_t ret = svc->ListMounts(infos, &capacity);
        if (ret == kIOReturnSuccess) {
            OSData* out = OSData::withBytes(infos, (uint32_t)(capacity * sizeof(DJMountInfo)));
            IODelete(infos, DJMountInfo, capacity);
            if (!out) return kIOReturnNoMemory;
            arguments->structureOutput = out;
            out->release();
        } else {
            IODelete(infos, DJMountInfo, capacity);
        }
        return ret;
    }

    default:
        return kIOReturnUnsupported;
    }
}
