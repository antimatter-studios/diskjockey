#include "DJAgentConnectionRegistry.hpp"
#include <cassert>
#include <cstring>
#include <vector>

static bool onQueue = false;
static unsigned checks = 0;
static void checkQueue() { assert(onQueue); ++checks; }
struct World {
    uint64_t identity = 0, attempt = 0;
    unsigned unmounts = 0, closes = 0, replies = 0;
    DJAttachmentResult result = DJAttachmentResult::Attached;
    DJAgentBridgePlatform platform() {
        return {this,
            [](void *, const char *, int) { checkQueue(); return true; },
            [](void *) -> uint32_t { checkQueue(); return 1; },
            [](void *, uint32_t) { checkQueue(); },
            [](void *p, uint32_t, const DJMountRequest *, int, uint64_t id) -> void * {
                checkQueue(); static_cast<World *>(p)->identity = id; return p;
            },
            [](void *p, void *) { checkQueue(); ++static_cast<World *>(p)->closes; },
            [](void *p, void *, uint64_t selector, const uint64_t *input, uint32_t,
               const void *, size_t, uint64_t *output, uint32_t *) -> int32_t {
                checkQueue(); assert(input[0] == static_cast<World *>(p)->identity);
                if (selector == kDJSelectorMountImage) output[0] = input[0];
                else assert(selector == kDJSelectorUnmountImage);
                return 0;
            }};
    }
    DJAgentAttachment::Hooks hooks() {
        return {this,
            [](void *) -> uint64_t { checkQueue(); return 100; },
            [](void *, uint64_t, void (*)(void *), void *) { checkQueue(); return true; },
            [](void *) { checkQueue(); }, nullptr,
            [](void *p, uint64_t, uint64_t attempt, const char *) {
                checkQueue(); auto &w = *static_cast<World *>(p);
                ++w.unmounts; w.attempt = attempt; return true;
            }, nullptr, nullptr};
    }
    static void completed(void *p, DJAttachmentResult result, const char *) {
        checkQueue(); auto &w = *static_cast<World *>(p); ++w.replies; w.result = result;
    }
};
static bool mediaIdentity(void *p, uint64_t *identity) {
    checkQueue(); *identity = *static_cast<uint64_t *>(p); return true;
}
int main() {
    onQueue = true;
    DJAgentConnectionRegistry registry(checkQueue);
    const uint64_t a = registry.connect(), b = registry.connect();
    assert(a && b && a != b);
    DJMountRequest mount = {}; std::strcpy(mount.path, "/image.vhdx");
    World first, second, foreign;
    auto attach = [&](uint64_t owner, World &w) {
        return registry.attach(owner, mount, 11, 1000, w.platform(), w.hooks(), World::completed, &w);
    };
    const uint64_t one = attach(a, first), two = attach(a, second), other = attach(b, foreign);
    assert(one && two && other && one != two && two != other && one != other);
    DJAgentMediaEvent event = {"disk7", true, &first.identity, mediaIdentity};
    registry.appeared(event);
    assert(first.replies == 1 && second.replies == 0 && foreign.replies == 0);
    assert(!registry.detach(b, one, World::completed, &foreign));
    assert(!registry.detach(0, one, World::completed, &foreign));
    assert(first.unmounts == 0 && first.closes == 0);
    registry.disconnect(a);
    assert(first.unmounts == 1 && second.unmounts == 1 && foreign.unmounts == 0);
    assert(second.replies == 1 && second.result == DJAttachmentResult::Disconnected);
    assert(!attach(a, first)); // An interrupted connection cannot acquire more work.
    assert(!registry.detach(a, one, World::completed, &first));
    registry.unmounted(one, first.attempt, false); // Retain failed cleanup for retry.
    registry.unmounted(two, second.attempt, true);
    registry.collectClosed();
    assert(first.closes == 0 && second.closes == 1 && foreign.closes == 0);
    registry.disconnect(a); // Invalidation after interruption retries retained work.
    assert(first.unmounts == 2 && second.unmounts == 1 && foreign.unmounts == 0);
    registry.unmounted(one, 1, true); // Stale reply cannot complete the retry.
    assert(first.closes == 0);
    registry.unmounted(one, first.attempt, true);
    registry.collectClosed();
    registry.disconnect(a); assert(first.closes == 1);
    event.media = &foreign.identity; registry.appeared(event);
    assert(foreign.replies == 1);
    assert(registry.detach(b, other, World::completed, &foreign));
    registry.unmounted(other, foreign.attempt, true); registry.collectClosed();
    assert(foreign.closes == 1 && foreign.replies == 2);
    registry.disconnect(b);
    std::vector<uint64_t> owners{a, b};
    for (unsigned i = 0; i < 1000; ++i) {
        const auto owner = registry.connect();
        for (auto previous : owners) assert(previous != owner);
        owners.push_back(owner); registry.disconnect(owner);
    }
    assert(checks > 1000);
    return 0;
}
