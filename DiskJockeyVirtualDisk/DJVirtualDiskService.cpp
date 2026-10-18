#include <DriverKit/IOUserClient.h>

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
    // Each user client fails its own pending reads in its Stop.
    return super::Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(DJVirtualDiskService, NewUserClient)
{
    IOService *client = nullptr;
    kern_return_t result = Create(this, "UserClientProperties", &client);
    if (result != kIOReturnSuccess) return result;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient) return kIOReturnSuccess;
    client->release();
    return kIOReturnError;
}
