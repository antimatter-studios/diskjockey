#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <new>
#include <string.h>
#include <time.h>

#include "DJVirtualDiskUserClient.h"
#include "DJVirtualDiskMountSelectors.h"
#include "DJVirtualDiskUserClientDispatch.h"

using DJReadDispatch = DJUserClientDispatch<>;

// The service personality key holding the block-device child's personality;
// each publish writes the identity and geometry into it before Create.
#define kDJDevicePropertiesKey "DJVirtualDiskDeviceProperties"

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
    IOService *service;
    DJMountTable *mounts;
    // The child each live identity published, held until its remove.
    struct {
        uint64_t identity;
        IOService *device;
    } children[kDJMaxVirtualDisks];
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

static kern_return_t DJUserClientMountStatus(DJMountResult result)
{
    switch (result) {
    case DJMountResult::Success: return kIOReturnSuccess;
    case DJMountResult::BadArgument: return kIOReturnBadArgument;
    case DJMountResult::Unsupported: return kIOReturnUnsupported;
    case DJMountResult::NotReady: return kIOReturnNotReady;
    case DJMountResult::Busy: return kIOReturnBusy;
    case DJMountResult::NoSpace: return kIOReturnNoSpace;
    case DJMountResult::NotFound: return kIOReturnNotFound;
    case DJMountResult::Failed: return kIOReturnError;
    }
    return kIOReturnError;
}

// No read backend is installed yet, so no identity has a virtual size and
// every mount is refused before a child is created.
static bool DJUserClientVirtualSize(void *, uint64_t, uint64_t *)
{
    return false;
}

static bool DJUserClientSetNumber(OSDictionary *dictionary, const char *key, uint64_t value)
{
    OSNumber *number = OSNumber::withNumber(value, 64);
    const bool set = number && dictionary->setObject(key, number);
    OSSafeReleaseNULL(number);
    return set;
}

// IOService::Create builds the child from a dictionary in the creating
// service's own properties, so the identity and geometry are written into the
// service's copy of the child personality first. Hooks run on this client's
// serial queue, one publish at a time.
static bool DJUserClientPublish(void *context, uint64_t identity, const DJMountGeometry &geometry)
{
    auto *ivars = static_cast<DJVirtualDiskUserClient_IVars *>(context);
    IOService *const service = ivars->service;
    auto *slot = &ivars->children[0];
    while (slot < ivars->children + kDJMaxVirtualDisks && slot->device) ++slot;
    if (!service || slot == ivars->children + kDJMaxVirtualDisks) return false;

    OSDictionary *properties = nullptr;
    if (service->CopyProperties(&properties) != kIOReturnSuccess) return false;
    auto *personality = OSDynamicCast(OSDictionary, properties->getObject(kDJDevicePropertiesKey));
    OSDictionary *device = personality
        ? OSDictionary::withDictionary(personality, personality->getCount() + 4) : nullptr;
    OSSafeReleaseNULL(properties);
    OSDictionary *update = OSDictionary::withCapacity(1);
    const bool ready = device && update &&
        DJUserClientSetNumber(device, kDJAttachmentIdentityKey, identity) &&
        DJUserClientSetNumber(device, kDJDeviceByteOffsetKey, geometry.byteOffset) &&
        DJUserClientSetNumber(device, kDJDeviceByteLengthKey, geometry.byteLength) &&
        DJUserClientSetNumber(device, kDJDeviceBlockSizeKey, geometry.blockSize) &&
        update->setObject(kDJDevicePropertiesKey, device) &&
        service->SetProperties(update) == kIOReturnSuccess;
    OSSafeReleaseNULL(update);
    OSSafeReleaseNULL(device);
    if (!ready) return false;

    IOService *child = nullptr;
    if (service->Create(service, kDJDevicePropertiesKey, &child) != kIOReturnSuccess || !child)
        return false;
    slot->identity = identity;
    slot->device = child;
    return true;
}

// Terminate starts an asynchronous termination that stops the child, which
// fails its pending reads. A refused Terminate leaves it published.
static bool DJUserClientRemove(void *context, uint64_t identity)
{
    auto *ivars = static_cast<DJVirtualDiskUserClient_IVars *>(context);
    for (auto &child : ivars->children) {
        if (!child.device || child.identity != identity) continue;
        if (child.device->Terminate(0) != kIOReturnSuccess) return false;
        OSSafeReleaseNULL(child.device);
        child.identity = 0;
        return true;
    }
    return false;
}

// The mount request (1056 bytes) arrives inline; the list output (one
// DJMountInfo per slot, above the 4096-byte inline limit) arrives as a
// descriptor. A descriptor output carries no used size back, so it is zeroed
// first and unused entries read as device ID zero.
static kern_return_t DJUserClientMount(DJVirtualDiskUserClient_IVars *ivars, uint64_t selector,
                                       IOUserClientMethodArguments *arguments)
{
    if (!ivars->mounts) return kIOReturnNotReady;
    if (arguments->structureInputDescriptor) return kIOReturnBadArgument;
    DJMountArguments call = {};
    call.scalarInput = arguments->scalarInput;
    call.scalarInputCount = arguments->scalarInputCount;
    if (arguments->structureInput) {
        call.structureInput = arguments->structureInput->getBytesNoCopy();
        call.structureInputSize = arguments->structureInput->getLength();
    }
    call.scalarOutput = arguments->scalarOutput;
    call.scalarOutputCount = arguments->scalarOutputCount;
    call.structureOutputMaximumSize = arguments->structureOutputMaximumSize;
    call.completion = arguments->completion;

    IOMemoryMap *map = nullptr;
    size_t used = 0;
    if (arguments->structureOutputDescriptor) {
        const kern_return_t mapped = arguments->structureOutputDescriptor->CreateMapping(
            0, 0, 0, 0, 0, &map);
        if (mapped != kIOReturnSuccess) return mapped;
        call.structureOutput = reinterpret_cast<void *>(map->GetAddress());
        call.structureOutputMaximumSize = map->GetLength();
        call.structureOutputSize = &used;
        if (selector == kDJSelectorListMounts) memset(call.structureOutput, 0, call.structureOutputMaximumSize);
    }
    const DJMountResult result = ivars->mounts->externalMethod(selector, call);
    OSSafeReleaseNULL(map);
    return DJUserClientMountStatus(result);
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
        if (ivars->mounts) {
            ivars->mounts->~DJMountTable();
            IOFree(ivars->mounts, sizeof(DJMountTable));
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
    ivars->service = provider;
    if (result == kIOReturnSuccess) {
        void *memory = IOMallocZero(sizeof(DJMountTable));
        if (memory) {
            ivars->mounts = new (memory) DJMountTable({
                ivars, DJUserClientVirtualSize, DJUserClientPublish, DJUserClientRemove,
            });
        } else {
            result = kIOReturnNoMemory;
        }
    }
    if (result != kIOReturnSuccess) super::Stop(provider, SUPERDISPATCH);
    return result;
}

// Client death and close arrive here too: every pending read fails first,
// then every child this client published is terminated.
kern_return_t IMPL(DJVirtualDiskUserClient, Stop)
{
    if (ivars->dispatch) ivars->dispatch->stop();
    for (auto &child : ivars->children) {
        if (child.device) child.device->Terminate(0);
        OSSafeReleaseNULL(child.device);
        child.identity = 0;
    }
    ivars->service = nullptr;
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
    // Mount, unmount and list (0..2) go to the mount table; the read
    // selectors (3..5) keep their own dispatch core.
    if (selector <= kDJSelectorListMounts) return DJUserClientMount(ivars, selector, arguments);
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
