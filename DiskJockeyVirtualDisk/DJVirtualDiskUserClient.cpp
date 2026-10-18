#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSData.h>
#include <new>
#include <string.h>
#include <time.h>

#include "DJVirtualDiskUserClient.h"
#include "DJVirtualDiskUserClientDispatch.h"

using DJReadDispatch = DJUserClientDispatch<>;

static_assert(sizeof(DJReadRequest) <= sizeof(IOUserClientAsyncArgumentsArray),
              "a read request fits one async completion");

// One request-ID sequence per dext process, which hosts the service for its
// whole lifetime: reconnecting never restarts it.
static DJReadIdentities gDJReadIdentities;

struct DJVirtualDiskUserClient_IVars {
    DJVirtualDiskUserClient *client;
    IODispatchQueue *queue;
    IOTimerDispatchSource *timer;
    OSAction *timerAction;
    void (*fire)(void *);
    void *fireArgument;
    DJReadDispatch *dispatch;
};

// Both peers read CLOCK_UPTIME_RAW, the clock kIOTimerClockUptimeRaw names.
static uint64_t DJUserClientNow(void *)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static bool DJUserClientArm(void *context, uint64_t deadline, void (*fire)(void *), void *argument)
{
    auto *ivars = static_cast<DJVirtualDiskUserClient_IVars *>(context);
    ivars->fire = fire;
    ivars->fireArgument = argument;
    if (ivars->timer->WakeAtTime(kIOTimerClockUptimeRaw, deadline, 0) == kIOReturnSuccess) return true;
    ivars->fire = nullptr;
    return false;
}

// A callback already queued finds no handler: cancel drains on the queue.
static void DJUserClientCancel(void *context)
{
    auto *ivars = static_cast<DJVirtualDiskUserClient_IVars *>(context);
    ivars->fire = nullptr;
    ivars->fireArgument = nullptr;
}

static bool DJUserClientDeliver(void *context, void *endpoint, const DJReadRequest &request)
{
    auto *ivars = static_cast<DJVirtualDiskUserClient_IVars *>(context);
    IOUserClientAsyncArgumentsArray data = {};
    memcpy(data, &request, sizeof(request));
    ivars->client->AsyncCompletion(static_cast<OSAction *>(endpoint), kIOReturnSuccess, data,
                            (sizeof(request) + sizeof(data[0]) - 1) / sizeof(data[0]));
    return true;
}

static void DJUserClientRelease(void *, void *endpoint)
{
    static_cast<OSAction *>(endpoint)->release();
}

static kern_return_t DJUserClientStatus(DJDispatchResult result)
{
    switch (result) {
    case DJDispatchResult::Success: return kIOReturnSuccess;
    case DJDispatchResult::BadArgument: return kIOReturnBadArgument;
    case DJDispatchResult::Unsupported: return kIOReturnUnsupported;
    case DJDispatchResult::NotReady: return kIOReturnNotReady;
    case DJDispatchResult::Busy: return kIOReturnBusy;
    }
    return kIOReturnError;
}

bool DJVirtualDiskUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(DJVirtualDiskUserClient_IVars, 1);
    return ivars != nullptr;
}

void DJVirtualDiskUserClient::free()
{
    if (ivars) {
        if (ivars->dispatch) {
            ivars->dispatch->~DJReadDispatch();
            IOFree(ivars->dispatch, sizeof(DJReadDispatch));
        }
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->timer);
        OSSafeReleaseNULL(ivars->queue);
    }
    IOSafeDeleteNULL(ivars, DJVirtualDiskUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(DJVirtualDiskUserClient, Start)
{
    kern_return_t result = super::Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;

    result = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
    if (result == kIOReturnSuccess) result = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
    if (result == kIOReturnSuccess) result = CreateActionReadDeadlineOccurred(0, &ivars->timerAction);
    if (result == kIOReturnSuccess) result = ivars->timer->SetHandler(ivars->timerAction);
    ivars->client = this;
    if (result == kIOReturnSuccess) {
        void *memory = IOMallocZero(sizeof(DJReadDispatch));
        if (memory) {
            ivars->dispatch = new (memory) DJReadDispatch(gDJReadIdentities, {
                ivars, DJUserClientNow, DJUserClientArm, DJUserClientCancel,
                DJUserClientDeliver, DJUserClientRelease,
            });
        } else {
            result = kIOReturnNoMemory;
        }
    }
    if (result != kIOReturnSuccess) super::Stop(provider, SUPERDISPATCH);
    return result;
}

// Client death and close arrive here too: every pending read fails first.
kern_return_t IMPL(DJVirtualDiskUserClient, Stop)
{
    if (ivars->dispatch) ivars->dispatch->stop();
    DJUserClientCancel(ivars);
    if (ivars->timer) ivars->timer->Cancel(^{});
    return super::Stop(provider, SUPERDISPATCH);
}

void IMPL(DJVirtualDiskUserClient, ReadDeadlineOccurred)
{
    void (*const fire)(void *) = ivars->fire;
    void *const argument = ivars->fireArgument;
    ivars->fire = nullptr;
    ivars->fireArgument = nullptr;
    if (fire) fire(argument);
}

kern_return_t DJVirtualDiskUserClient::ExternalMethod(uint64_t selector,
                                                      IOUserClientMethodArguments *arguments,
                                                      const IOUserClientMethodDispatch *,
                                                      OSObject *, void *)
{
    if (!ivars->dispatch) return kIOReturnNotReady;
    IOMemoryMap *map = nullptr;
    DJDispatchArguments call = {};
    call.scalarInput = arguments->scalarInput;
    call.scalarInputCount = arguments->scalarInputCount;
    // The one structure input is the reply payload: inline up to 4096 bytes,
    // a descriptor above. A call carrying both is malformed.
    if (arguments->structureInput && arguments->structureInputDescriptor) return kIOReturnBadArgument;
    if (arguments->structureInput) {
        call.payload = arguments->structureInput->getBytesNoCopy();
        call.payloadSize = arguments->structureInput->getLength();
    }
    if (arguments->structureInputDescriptor) {
        const kern_return_t mapped = arguments->structureInputDescriptor->CreateMapping(
            kIOMemoryMapReadOnly, 0, 0, 0, 0, &map);
        if (mapped != kIOReturnSuccess) return mapped;
        call.payload = reinterpret_cast<const void *>(map->GetAddress());
        call.payloadSize = map->GetLength();
    }
    call.scalarOutputCount = arguments->scalarOutputCount;
    call.structureOutputMaximumSize = arguments->structureOutputMaximumSize;
    call.completion = arguments->completion;

    // The completion is borrowed for this call; the core keeps it only on a
    // successful connect and then releases it exactly once.
    if (arguments->completion) arguments->completion->retain();
    const DJDispatchResult result = ivars->dispatch->externalMethod(selector, call);
    if (arguments->completion &&
        (result != DJDispatchResult::Success || selector != kDJSelectorConnectReadEndpoint))
        arguments->completion->release();
    OSSafeReleaseNULL(map);
    return DJUserClientStatus(result);
}
