#include "DJAgentBridge.hpp"
#include <cassert>
#include <cstring>
#include <string>

namespace {
constexpr int32_t success = 0;
constexpr int32_t notReady = int32_t(0xe00002d8);  // kIOReturnNotReady
constexpr int32_t notFound = int32_t(0xe00002f0);  // kIOReturnNotFound
constexpr int32_t failed = int32_t(0xe00002bc);    // kIOReturnError

// The dext's side of the connection, as the user client answers it.
struct World {
    std::string log;
    int32_t mountStatus = success, unmountStatus = success;
    uint64_t deviceID = 9;  // what the mount selector returns; the identity
    bool appearOnMount = true, diskUnmounts = true, childPublished = false;
    uint64_t now = 100;
    void (*timer)(void *) = nullptr;
    void *timerContext = nullptr;
    DJAgentBridge *bridge = nullptr;
    unsigned closes = 0, releases = 0;
};
World *world;
int endpointToken;

void note(const char *event) {
    if (!world->log.empty()) world->log += ' ';
    world->log += event;
}

DJMountRequest request() {
    DJMountRequest mount = {};
    std::strcpy(mount.path, "/images/disk.vhdx");
    mount.partOffset = 4096;
    mount.partLength = 1 << 20;
    mount.blockSize = 4096;
    return mount;
}

bool authorize(void *, const char *, int) { return true; }
uint32_t discover(void *) { return 0x1234; }
void release(void *, uint32_t service) {
    note("release"); assert(service == 0x1234); ++world->releases;
}
void *open(void *, uint32_t, const DJMountRequest *, int, uint64_t) { return &endpointToken; }
void close(void *, void *endpoint) {
    note("close"); assert(endpoint == &endpointToken); ++world->closes;
}

// The selector shapes are #460's kDJMountMethods: mount takes the identity
// and the request and returns one device ID; unmount takes the identity.
int32_t call(void *, void *endpoint, uint64_t selector, const uint64_t *input,
             uint32_t inputCount, const void *structure, size_t structureSize,
             uint64_t *output, uint32_t *outputCount) {
    assert(endpoint == &endpointToken && outputCount);
    assert(inputCount == 1 && input && input[0] == 9);
    if (selector == kDJSelectorMountImage) {
        note("mount-selector");
        const DJMountRequest expected = request();
        assert(structure && structureSize == sizeof(DJMountRequest));
        assert(std::memcmp(structure, &expected, sizeof(expected)) == 0);
        assert(output && *outputCount == 1);
        if (world->mountStatus != success) return world->mountStatus;
        world->childPublished = true;
        output[0] = world->deviceID;
        if (world->appearOnMount)
            world->bridge->lifecycle().appeared(9, "/dev/disk7", sizeof("/dev/disk7"));
        return success;
    }
    assert(selector == kDJSelectorUnmountImage);
    assert(!structure && structureSize == 0 && *outputCount == 0);
    note("unmount-selector");
    if (world->unmountStatus != success) return world->unmountStatus;
    // The dext answers NotFound for an identity that owns no child.
    if (!world->childPublished) return notFound;
    world->childPublished = false;
    return success;
}

uint64_t now(void *) { return world->now; }
bool arm(void *, uint64_t, void (*callback)(void *), void *context) {
    world->timer = callback; world->timerContext = context; return true;
}
void cancel(void *) { world->timer = nullptr; world->timerContext = nullptr; }
// The lifecycle's publish and remove are the bridge's: these must never run.
bool lifecyclePublish(void *, uint64_t) { assert(!"lifecycle publish called"); return false; }
bool lifecycleRemove(void *, uint64_t) { assert(!"lifecycle remove called"); return false; }
// The disk unmount stays the lifecycle's (DiskArbitration), replied later.
bool unmount(void *, uint64_t attachmentID, uint64_t, const char *) {
    note("disk-unmount"); assert(attachmentID == 9); return true;
}

struct Outcome {
    unsigned calls = 0;
    DJAttachmentResult result = DJAttachmentResult::Detached;
};
void completed(void *context, DJAttachmentResult result, const char *) {
    auto *outcome = static_cast<Outcome *>(context);
    ++outcome->calls; outcome->result = result;
}

const DJAgentBridgePlatform platform = {nullptr, authorize, discover, release, open, close, call};
const DJAgentAttachment::Hooks lifecycle = {
    nullptr, now, arm, cancel, lifecyclePublish, unmount, lifecycleRemove, nullptr};

constexpr uint64_t attachWait = 1000;
void diskUnmounted(DJAgentBridge &bridge, uint64_t attempt = 1, bool ok = true) {
    bridge.lifecycle().unmounted(9, attempt, ok);
}
} // namespace

int main() {
    // The whole life: the mount selector publishes, the unmount selector
    // removes, and the reader and connection close only after removal.
    {
        World w; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome attached, detached;
        assert(bridge.attach(request(), 11, attachWait, completed, &attached));
        assert(attached.calls == 1 && attached.result == DJAttachmentResult::Attached);
        assert(w.log == "mount-selector" && w.childPublished);
        assert(bridge.lifecycle().detach(3, 9, completed, &detached));
        assert(w.log == "mount-selector disk-unmount" && w.closes == 0);
        diskUnmounted(bridge);
        assert(detached.calls == 1 && detached.result == DJAttachmentResult::Detached);
        assert(w.log == "mount-selector disk-unmount unmount-selector close release");
        assert(!w.childPublished && w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    // A refused mount selector is a publication failure: cleanup runs, the
    // never-created child reads as already removed, and only then closes.
    {
        World w; w.mountStatus = notReady; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(outcome.calls == 1 && outcome.result == DJAttachmentResult::PublicationFailure);
        assert(w.log == "mount-selector disk-unmount" && w.closes == 0);
        diskUnmounted(bridge);
        assert(w.log == "mount-selector disk-unmount unmount-selector close release");
        assert(w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    // A device ID other than the identity is not this attachment's child:
    // publication fails, and the child the dext did create is removed.
    {
        World w; w.deviceID = 10; w.appearOnMount = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(outcome.result == DJAttachmentResult::PublicationFailure && w.closes == 0);
        diskUnmounted(bridge);
        assert(w.log == "mount-selector disk-unmount unmount-selector close release");
        assert(!w.childPublished && w.closes == 1);
    }
    // The media never appeared: the timeout enters the same cleanup.
    {
        World w; w.appearOnMount = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(outcome.calls == 0 && w.timer);
        w.now += attachWait;
        w.timer(w.timerContext);
        assert(outcome.calls == 1 && outcome.result == DJAttachmentResult::AppearanceTimeout);
        assert(w.log == "mount-selector disk-unmount" && w.closes == 0);
        diskUnmounted(bridge);
        assert(w.log == "mount-selector disk-unmount unmount-selector close release");
        assert(!w.childPublished && w.closes == 1);
    }
    // A failed disk unmount retains everything: no selector, nothing closed;
    // the trusted retry removes and closes once.
    {
        World w; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome attached, detached;
        assert(bridge.attach(request(), 11, attachWait, completed, &attached));
        assert(bridge.lifecycle().detach(3, 9, completed, &detached));
        diskUnmounted(bridge, 1, false);
        assert(detached.result == DJAttachmentResult::UnmountFailure);
        assert(w.log == "mount-selector disk-unmount" && w.closes == 0 && w.childPublished);
        bridge.lifecycle().disconnect();
        diskUnmounted(bridge, 2);
        assert(w.log == "mount-selector disk-unmount disk-unmount unmount-selector close release");
        assert(w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    // A failed unmount selector is a removal failure: the reader and
    // connection stay open, and the retry closes them after removal.
    {
        World w; w.unmountStatus = failed; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome attached, detached;
        assert(bridge.attach(request(), 11, attachWait, completed, &attached));
        assert(bridge.lifecycle().detach(3, 9, completed, &detached));
        diskUnmounted(bridge);
        assert(detached.result == DJAttachmentResult::RemovalFailure);
        assert(w.closes == 0 && w.releases == 0 && w.childPublished);
        w.unmountStatus = success;
        bridge.lifecycle().disconnect();
        diskUnmounted(bridge, 2);
        assert(w.log == "mount-selector disk-unmount unmount-selector disk-unmount unmount-selector close release");
        assert(!w.childPublished && w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    // Without a connection call the bridge refuses before authorizing.
    {
        World w; world = &w;
        DJAgentBridgePlatform partial = platform; partial.call = nullptr;
        DJAgentBridge bridge(3, 9, partial, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(!bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log.empty() && outcome.calls == 0);
    }
    return 0;
}
