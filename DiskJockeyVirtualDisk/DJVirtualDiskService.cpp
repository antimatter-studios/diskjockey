#include "DJVirtualDiskService.h"

kern_return_t IMPL(DJVirtualDiskService, Start)
{
    kern_return_t result = super::Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;

    result = RegisterService();
    if (result != kIOReturnSuccess) {
        super::Stop(provider, SUPERDISPATCH);
    }
    return result;
}

kern_return_t IMPL(DJVirtualDiskService, Stop)
{
    // No children, user clients, files or buffers exist in this slice.
    return super::Stop(provider, SUPERDISPATCH);
}
