#include "DJAgentBridge.hpp"
#include <cassert>
#include <cstring>
#include <string>

namespace {
// Every boundary call, in order, so the guard can assert sequencing.
struct World {
    std::string log;
    bool authorize = true, discover = true, open = true, publish = true, remove = true;
    bool appearOnPublish = true;
    uint64_t now = 100;
    void (*timer)(void *) = nullptr;
    void *timerContext = nullptr;
    DJAgentBridge *bridge = nullptr;
    int proofSeen = -1;
    uint64_t identitySeen = 0;
    unsigned closes = 0, releases = 0;
};
World *world;
int endpointToken;

void note(const char *event) {
    if (!world->log.empty()) world->log += ' ';
    world->log += event;
}

bool authorize(void *, const char *path, int proof) {
    note("authorize");
    assert(std::strcmp(path, "/images/disk.vhdx") == 0);
    world->proofSeen = proof;
    return world->authorize;
}
uint32_t discover(void *) { note("discover"); return world->discover ? 0x1234 : 0; }
void release(void *, uint32_t service) {
    note("release"); assert(service == 0x1234); ++world->releases;
}
void *open(void *, uint32_t service, const DJMountRequest *mount, int proof, uint64_t identity) {
    note("open");
    assert(service == 0x1234 && mount && proof == world->proofSeen);
    world->identitySeen = identity;
    return world->open ? &endpointToken : nullptr;
}
void close(void *, void *endpoint) {
    note("close"); assert(endpoint == &endpointToken); ++world->closes;
}

uint64_t now(void *) { return world->now; }
bool arm(void *, uint64_t, void (*callback)(void *), void *context) {
    world->timer = callback; world->timerContext = context; return true;
}
void cancel(void *) { world->timer = nullptr; world->timerContext = nullptr; }
bool publish(void *, uint64_t attachmentID) {
    note("publish");
    assert(attachmentID == 9);
    if (world->publish && world->appearOnPublish)
        world->bridge->lifecycle().appeared(9, "/dev/disk7", sizeof("/dev/disk7"));
    return world->publish;
}
bool unmount(void *, uint64_t attachmentID, uint64_t, const char *) {
    note("unmount"); assert(attachmentID == 9); return true;
}
bool remove(void *, uint64_t attachmentID) {
    note("remove"); assert(attachmentID == 9); return world->remove;
}

struct Outcome {
    unsigned calls = 0;
    DJAttachmentResult result = DJAttachmentResult::Detached;
};
void completed(void *context, DJAttachmentResult result, const char *) {
    auto *outcome = static_cast<Outcome *>(context);
    ++outcome->calls; outcome->result = result;
}

const DJAgentBridgePlatform platform = {nullptr, authorize, discover, release, open, close};
// The lifecycle's own close hook is deliberately null: the bridge owns close.
const DJAgentAttachment::Hooks lifecycle = {nullptr, now, arm, cancel, publish, unmount, remove, nullptr};

DJMountRequest request() {
    DJMountRequest mount = {};
    std::strcpy(mount.path, "/images/disk.vhdx");
    return mount;
}

constexpr uint64_t attachWait = 1000;

// Drive one detach, or the cleanup a failure started, to its unmount reply.
void unmounted(DJAgentBridge &bridge) { bridge.lifecycle().unmounted(9, 1, true); }
} // namespace

int main() {
    // The whole life: authorization, then discovery, then the reader and
    // endpoint, then publication; resources close only after removal.
    {
        World w; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome attached, detached;
        assert(bridge.attach(request(), 11, attachWait, completed, &attached));
        assert(attached.calls == 1 && attached.result == DJAttachmentResult::Attached);
        assert(w.identitySeen == 9 && w.proofSeen == 11);
        assert(w.log == "authorize discover open publish");
        assert(bridge.lifecycle().detach(3, 9, completed, &detached));
        assert(w.closes == 0 && w.releases == 0);
        unmounted(bridge);
        assert(detached.calls == 1 && detached.result == DJAttachmentResult::Detached);
        assert(w.log == "authorize discover open publish unmount remove close release");
        assert(w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    // A refused authorization opens nothing and takes no completion.
    {
        World w; w.authorize = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(!bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log == "authorize" && outcome.calls == 0);
        // One attempt per bridge: a retry after refusal still opens nothing.
        w.authorize = true;
        assert(!bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log == "authorize" && outcome.calls == 0);
    }
    // No dext service: nothing was opened, so nothing is released.
    {
        World w; w.discover = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(!bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log == "authorize discover" && outcome.calls == 0 && w.releases == 0);
    }
    // The reader or connection failed to open: the service is released and
    // no lifecycle starts, so nothing is published.
    {
        World w; w.open = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(!bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log == "authorize discover open release" && outcome.calls == 0);
        assert(w.closes == 0 && w.releases == 1);
    }
    // Requests the lifecycle would refuse are refused before authorization.
    {
        World w; world = &w;
        Outcome outcome;
        DJAgentBridge orphan(0, 9, platform, lifecycle); w.bridge = &orphan;
        assert(!orphan.attach(request(), 11, attachWait, completed, &outcome));
        DJAgentBridge anonymous(3, 0, platform, lifecycle); w.bridge = &anonymous;
        assert(!anonymous.attach(request(), 11, attachWait, completed, &outcome));
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        assert(!bridge.attach(request(), -1, attachWait, completed, &outcome));
        assert(!bridge.attach(request(), 11, 0, completed, &outcome));
        assert(!bridge.attach(request(), 11, DJAgentAttachment::maxWaitNanoseconds + 1, completed, &outcome));
        assert(!bridge.attach(request(), 11, attachWait, nullptr, &outcome));
        DJMountRequest unterminated = request();
        std::memset(unterminated.path, 'a', sizeof(unterminated.path));
        assert(!bridge.attach(unterminated, 11, attachWait, completed, &outcome));
        DJAgentBridgePlatform partial = platform; partial.release = nullptr;
        DJAgentBridge incomplete(3, 9, partial, lifecycle); w.bridge = &incomplete;
        assert(!incomplete.attach(request(), 11, attachWait, completed, &outcome));
        DJAgentAttachment::Hooks noRemove = lifecycle; noRemove.remove = nullptr;
        DJAgentBridge unremovable(3, 9, platform, noRemove); w.bridge = &unremovable;
        assert(!unremovable.attach(request(), 11, attachWait, completed, &outcome));
        assert(w.log.empty() && outcome.calls == 0);
    }
    // A failed publication (the mount selector) enters the lifecycle cleanup,
    // and the endpoint closes only after the owned child is removed.
    {
        World w; w.publish = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(outcome.calls == 1 && outcome.result == DJAttachmentResult::PublicationFailure);
        assert(w.log == "authorize discover open publish unmount" && w.closes == 0);
        unmounted(bridge);
        assert(w.log == "authorize discover open publish unmount remove close release");
        assert(w.closes == 1 && w.releases == 1);
    }
    // The media never appeared: the timeout enters the same cleanup.
    {
        World w; w.appearOnPublish = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome outcome;
        assert(bridge.attach(request(), 11, attachWait, completed, &outcome));
        assert(outcome.calls == 0 && w.timer);
        w.now += attachWait;
        w.timer(w.timerContext);
        assert(outcome.calls == 1 && outcome.result == DJAttachmentResult::AppearanceTimeout);
        assert(w.closes == 0);
        unmounted(bridge);
        assert(w.log == "authorize discover open publish unmount remove close release");
    }
    // A failed removal keeps the reader and connection open; the trusted
    // retry closes them once, after the removal succeeds.
    {
        World w; w.remove = false; world = &w;
        DJAgentBridge bridge(3, 9, platform, lifecycle); w.bridge = &bridge;
        Outcome attached, detached;
        assert(bridge.attach(request(), 11, attachWait, completed, &attached));
        assert(bridge.lifecycle().detach(3, 9, completed, &detached));
        unmounted(bridge);
        assert(detached.result == DJAttachmentResult::RemovalFailure && w.closes == 0);
        w.remove = true;
        bridge.lifecycle().disconnect();
        bridge.lifecycle().unmounted(9, 2, true);
        assert(w.log == "authorize discover open publish unmount remove unmount remove close release");
        assert(w.closes == 1 && w.releases == 1 && bridge.lifecycle().closed());
    }
    return 0;
}
