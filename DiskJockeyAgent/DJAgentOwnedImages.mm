// Real platform bindings for the injected bridge. All work shares the registry queue.
#import "DJAgentOwnedImages.h"
#include "DJAgentConnections.hpp"
#include "DJAgentReadEndpoint.h"
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/storage/IOMedia.h>

extern "C" bool DJAgentAuthorizeImage(const char *, int);
namespace {
struct Context {
    DJAgentConnectionTimer timer;
    uint64_t identity = 0;
    DJAgentOwnedAttachReply reply;
};
bool identity(void *media, uint64_t *value) {
    auto property = IORegistryEntrySearchCFProperty(io_registry_entry_t(uintptr_t(media)),
        kIOServicePlane, CFSTR(kDJAttachmentIdentityKey), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!property) return false;
    int64_t number = 0;
    const bool found = CFGetTypeID(property) == CFNumberGetTypeID() &&
        CFNumberGetValue(static_cast<CFNumberRef>(property), kCFNumberSInt64Type, &number);
    CFRelease(property);
    if (found) *value = uint64_t(number);
    return found && *value != 0;
}
void collect() {
    dispatch_async(DJAgentConnectionQueue(), ^{ DJAgentConnections().collectClosed(); });
}
void appeared(DADiskRef disk, void *) {
    auto description = DADiskCopyDescription(disk);
    auto media = DADiskCopyIOMedia(disk);
    if (description && media) {
        auto whole = CFDictionaryGetValue(description, kDADiskDescriptionMediaWholeKey);
        DJAgentMediaEvent event{DADiskGetBSDName(disk), whole == kCFBooleanTrue,
            reinterpret_cast<void *>(uintptr_t(media)), identity};
        DJAgentConnections().appeared(event);
    }
    if (media) IOObjectRelease(media);
    if (description) CFRelease(description);
    collect();
}
DASessionRef session() {
    static DASessionRef value = [] {
        auto s = DASessionCreate(kCFAllocatorDefault);
        if (s) {
            DARegisterDiskAppearedCallback(s, nullptr, appeared, nullptr);
            DASessionSetDispatchQueue(s, DJAgentConnectionQueue());
        }
        return s;
    }();
    return value;
}
struct UnmountReply { uint64_t identity, attempt; };
struct DetachReply { DJAgentOwnedDetachReply reply; };
void unmounted(DADiskRef, DADissenterRef dissenter, void *opaque) {
    std::unique_ptr<UnmountReply> reply(static_cast<UnmountReply *>(opaque));
    DJAgentConnections().unmounted(reply->identity, reply->attempt, !dissenter);
    collect();
}
bool unmount(void *, uint64_t owned, uint64_t attempt, const char *) {
    // Resolve the identity afresh, even when no appearance callback arrived.
    // Never use the lifecycle's cached BSD name: disk numbers can be reused.
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOMediaClass),
                                    &iterator) != KERN_SUCCESS) return false;
    DADiskRef disk = nullptr;
    bool failed = false;
    while (auto media = IOIteratorNext(iterator)) {
        uint64_t found = 0;
        if (identity(reinterpret_cast<void *>(uintptr_t(media)), &found) && found == owned) {
            failed = true; // Owned media without a resolvable whole disk is not absent.
            auto candidate = DADiskCreateFromIOMedia(kCFAllocatorDefault, session(), media);
            auto description = candidate ? DADiskCopyDescription(candidate) : nullptr;
            if (!description) failed = true;
            else if (CFDictionaryGetValue(description, kDADiskDescriptionMediaWholeKey) == kCFBooleanTrue) {
                disk = candidate; candidate = nullptr;
            }
            if (description) CFRelease(description);
            if (candidate) CFRelease(candidate);
        }
        IOObjectRelease(media);
        if (disk) break;
    }
    if (!IOIteratorIsValid(iterator)) failed = true;
    IOObjectRelease(iterator);
    if (disk) {
        DADiskUnmount(disk, kDADiskUnmountOptionWhole, unmounted, new UnmountReply{owned, attempt});
        CFRelease(disk);
    } else {
        // A failed publication may have no media; removal still runs next.
        DJAgentConnections().unmounted(owned, attempt, !failed);
    }
    return true;
}
DJAgentBridgePlatform platform(Context *context) {
    return {context,
        [](void *, const char *path, int proof) { return DJAgentAuthorizeImage(path, proof); },
        [](void *) -> uint32_t {
            auto matching = IOServiceMatching("IOUserService");
            if (!matching) return 0;
            NSDictionary *properties = @{@"IOUserClass": @"DJVirtualDiskService"};
            CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)properties);
            return IOServiceGetMatchingService(kIOMainPortDefault, matching);
        },
        [](void *, uint32_t service) { IOObjectRelease(service); },
        [](void *p, uint32_t service, const DJMountRequest *mount, int proof, uint64_t id) -> void * {
            static_cast<Context *>(p)->identity = id;
            return DJAgentReadEndpointOpen(service, mount, proof, id);
        },
        [](void *, void *endpoint) { DJAgentReadEndpointClose(static_cast<DJAgentReadEndpoint *>(endpoint)); },
        [](void *, void *endpoint, uint64_t selector, const uint64_t *input, uint32_t count,
           const void *structure, size_t size, uint64_t *output, uint32_t *outputCount) {
            return DJAgentReadEndpointCall(static_cast<DJAgentReadEndpoint *>(endpoint), selector,
                input, count, structure, size, output, outputCount);
        }};
}
DJAgentAttachment::Hooks hooks(Context *context) {
    return {context,
        [](void *) { return DJAgentConnectionTimer::now(); },
        [](void *p, uint64_t deadline, void (*callback)(void *), void *opaque) {
            return static_cast<Context *>(p)->timer.arm(deadline, callback, opaque);
        },
        [](void *p) { static_cast<Context *>(p)->timer.cancel(); },
        nullptr, unmount, nullptr, nullptr};
}
NSString *failure(DJAttachmentResult result) {
    switch (result) {
        case DJAttachmentResult::PublicationFailure: return @"DriverKit publication failed";
        case DJAttachmentResult::AppearanceTimeout: return @"DriverKit media appearance timed out";
        case DJAttachmentResult::TimerFailure: return @"DriverKit lifecycle timer failed";
        case DJAttachmentResult::UnmountFailure: return @"owned DriverKit disk could not be unmounted";
        case DJAttachmentResult::RemovalFailure: return @"owned DriverKit child could not be removed";
        case DJAttachmentResult::Disconnected: return @"DriverKit owner disconnected";
        default: return @"DriverKit attachment failed";
    }
}
}
void DJAgentOwnedImageAttach(uint64_t owner, const char *path, int proof,
    uint64_t offset, uint64_t length, uint32_t blockSize, DJAgentOwnedAttachReply reply) {
    dispatch_assert_queue(DJAgentConnectionQueue());
    DJMountRequest mount = {};
    if (!path || strnlen(path, sizeof(mount.path)) == sizeof(mount.path) || !session()) {
        reply(0, nil, @"invalid image path or DiskArbitration unavailable"); return;
    }
    memcpy(mount.path, path, strlen(path) + 1);
    mount.partOffset = offset; mount.partLength = length; mount.blockSize = blockSize;
    auto context = std::make_shared<Context>(); context->reply = [reply copy];
    const auto id = DJAgentConnections().attach(owner, mount, proof,
        DJAgentAttachment::maxWaitNanoseconds, platform(context.get()), hooks(context.get()),
        [](void *p, DJAttachmentResult result, const char *device) {
            auto &c = *static_cast<Context *>(p);
            c.reply(c.identity, device ? [NSString stringWithUTF8String:device] : nil,
                result == DJAttachmentResult::Attached ? nil : failure(result));
            c.reply = nil;
        }, context.get(), context);
    if (!id) reply(0, nil, @"DriverKit attach refused: owner, image proof, reader or service unavailable");
    collect();
}
void DJAgentOwnedImageDetach(uint64_t owner, uint64_t id, DJAgentOwnedDetachReply reply) {
    dispatch_assert_queue(DJAgentConnectionQueue());
    auto callback = new DetachReply{[reply copy]};
    if (!DJAgentConnections().detach(owner, id,
        [](void *p, DJAttachmentResult result, const char *) {
            std::unique_ptr<DetachReply> callback(static_cast<DetachReply *>(p));
            callback->reply(result == DJAttachmentResult::Detached,
                result == DJAttachmentResult::Detached ? nil : failure(result));
        }, callback)) {
        delete callback;
        reply(NO, @"DriverKit detach refused: attachment is not owned or is busy");
    }
    collect();
}
