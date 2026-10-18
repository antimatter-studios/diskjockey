#include "DJAgentAttachment.hpp"
#include <cassert>
#include <cstring>
#include <string>
#include <vector>

using Result = DJAttachmentResult;
struct Fake {
    uint64_t now = 100, deadline = 0, attempt = 0;
    void (*fire)(void *) = nullptr;
    void *argument = nullptr;
    bool timerOK = true, publishOK = true, unmountOK = true, removeOK = true;
    bool synchronousAppearance = false, synchronousUnmount = false;
    unsigned closes = 0;
    DJAgentAttachment *lifecycle = nullptr;
    std::vector<std::string> actions;
    std::vector<Result> results;
    std::vector<std::string> devices;
    DJAgentAttachment::Hooks hooks() {
        return {this,
            [](void *p) { return static_cast<Fake *>(p)->now; },
            [](void *p, uint64_t deadline, void (*fire)(void *), void *argument) {
                auto &f = *static_cast<Fake *>(p);
                f.deadline = deadline; f.fire = fire; f.argument = argument;
                return f.timerOK;
            },
            [](void *p) { static_cast<Fake *>(p)->fire = nullptr; },
            [](void *p, uint64_t id) {
                auto &f = *static_cast<Fake *>(p); assert(id == 7);
                f.actions.push_back("publish");
                if (f.synchronousAppearance) f.appear();
                return f.publishOK;
            },
            [](void *p, uint64_t id, uint64_t attempt, const char *device) {
                auto &f = *static_cast<Fake *>(p); assert(id == 7);
                f.attempt = attempt;
                assert(!device || std::strcmp(device, "/dev/disk42") == 0);
                f.actions.push_back("unmount");
                if (f.synchronousUnmount) f.lifecycle->unmounted(id, attempt, true);
                return f.unmountOK;
            },
            [](void *p, uint64_t id) {
                auto &f = *static_cast<Fake *>(p); assert(id == 7);
                assert(f.actions.back() == "unmount");
                f.actions.push_back("remove"); return f.removeOK;
            },
            [](void *p) { auto &f = *static_cast<Fake *>(p); ++f.closes; f.actions.push_back("close"); }};
    }
    static void completion(void *p, Result result, const char *device) {
        auto &f = *static_cast<Fake *>(p); f.results.push_back(result);
        f.devices.emplace_back(device ? device : "");
        if (result != Result::Attached) assert(!device);
    }
    void appear(uint64_t id = 7, const char *device = "/dev/disk42") {
        lifecycle->appeared(id, device, std::strlen(device) + 1);
    }
    void tick(uint64_t time) {
        now = time;
        if (fire) { auto callback = fire; fire = nullptr; callback(argument); }
    }
    void cleanup() {
        lifecycle->disconnect(); lifecycle->unmounted(7, attempt, true);
        assert(lifecycle->closed()); assert(closes == 1);
    }
    void unmounted(bool success, uint64_t id = 7) { lifecycle->unmounted(id, attempt, success); }
};
#define SETUP Fake f; DJAgentAttachment a(3, 7, f.hooks()); f.lifecycle = &a
static void attached(Fake &f, DJAgentAttachment &a) {
    assert(a.start(50, Fake::completion, &f)); f.appear();
    assert(f.results == std::vector<Result>{Result::Attached});
    assert(f.devices[0] == "/dev/disk42");
}
int main() {
    { // Invalid arguments take no completion and cause no platform effects.
        SETUP;
        assert(!a.start(0, Fake::completion, &f));
        assert(!a.start(DJAgentAttachment::maxWaitNanoseconds + 1, Fake::completion, &f));
        assert(!a.start(50, nullptr, &f));
        f.now = UINT64_MAX - 1; assert(!a.start(50, Fake::completion, &f));
        assert(f.actions.empty() && f.results.empty());
    }
    { Fake f; DJAgentAttachment a(0, 7, f.hooks());
      assert(!a.start(50, Fake::completion, &f)); }
    { Fake f; DJAgentAttachment a(3, 0, f.hooks());
      assert(!a.start(50, Fake::completion, &f)); }
    { SETUP; a.disconnect(); assert(!a.start(50, Fake::completion, &f));
      assert(f.actions.empty() && f.results.empty()); }
    { // Unrelated identities, malformed names and duplicate events never escape.
        SETUP; assert(a.start(50, Fake::completion, &f));
        f.appear(8); f.appear(7, "/dev/disk42s1"); f.appear(7, "/dev/disk");
        f.appear(7, "/dev/disk42/../disk9");
        a.appeared(7, "/dev/disk42", 10); a.appeared(7, nullptr, 11);
        assert(f.results.empty());
        f.appear(); f.appear(7, "/dev/disk99");
        assert(f.results.size() == 1 && f.devices[0] == "/dev/disk42");
        const auto before = f.actions;
        assert(!a.detach(4, 7, Fake::completion, &f));
        assert(!a.detach(3, 8, Fake::completion, &f));
        assert(!a.detach(3, 7, nullptr, &f));
        assert(f.actions == before);
        assert(a.detach(3, 7, Fake::completion, &f));
        assert(!a.detach(3, 7, Fake::completion, &f));
        assert(f.actions.back() == "unmount" && f.closes == 0);
        f.unmounted(true, 8); assert(f.closes == 0);
        f.unmounted(true); f.unmounted(true); a.disconnect();
        assert(f.results == (std::vector<Result>{Result::Attached, Result::Detached}));
        assert(f.actions == (std::vector<std::string>{"publish", "unmount", "remove", "close"}));
        assert(a.closed() && f.closes == 1);
    }
    { // Timeout is active without disk events; late appearance cannot succeed.
        SETUP; assert(a.start(50, Fake::completion, &f));
        f.tick(149); assert(f.results.empty() && f.fire);
        f.tick(150); assert(f.results == std::vector<Result>{Result::AppearanceTimeout});
        f.appear(); assert(f.results.size() == 1);
        assert(f.actions.back() == "unmount" && f.closes == 0);
        f.unmounted(true); assert(a.closed() && f.closes == 1);
    }
    { // A matching event at the deadline is still a timeout.
        SETUP; assert(a.start(50, Fake::completion, &f)); f.now = 150; f.appear();
        assert(f.results == std::vector<Result>{Result::AppearanceTimeout}); f.cleanup();
    }
    { // Publication can synchronously emit an event before it reports failure.
        SETUP; f.publishOK = false; f.synchronousAppearance = true;
        assert(a.start(50, Fake::completion, &f));
        assert(f.results == std::vector<Result>{Result::PublicationFailure}); f.cleanup();
    }
    { SETUP; f.synchronousAppearance = true;
      assert(a.start(50, Fake::completion, &f));
      assert(f.results == std::vector<Result>{Result::Attached}); f.cleanup(); }
    { SETUP; assert(a.start(50, Fake::completion, &f));
      f.timerOK = false; f.tick(149);
      assert(f.results == std::vector<Result>{Result::TimerFailure});
      f.timerOK = true; f.cleanup(); }
    { SETUP; f.timerOK = false; assert(a.start(50, Fake::completion, &f));
      assert(f.results == std::vector<Result>{Result::TimerFailure});
      assert(f.actions == std::vector<std::string>{"close"}); assert(a.closed()); }
    { // Unmount failure must never remove a mounted device; owned retry works.
        SETUP; attached(f, a); assert(a.detach(3, 7, Fake::completion, &f));
        f.unmounted(false); assert(f.results.back() == Result::UnmountFailure);
        assert(f.actions.back() == "unmount" && !a.closed() && !f.closes);
        const uint64_t oldAttempt = f.attempt;
        assert(a.detach(3, 7, Fake::completion, &f));
        a.unmounted(7, oldAttempt, true); assert(!f.closes);
        f.unmounted(true);
        assert(f.results.back() == Result::Detached && f.closes == 1);
    }
    { // Failure to start unmount and missing unmount replies are bounded errors.
        SETUP; attached(f, a); f.unmountOK = false;
        assert(a.detach(3, 7, Fake::completion, &f));
        assert(f.results.back() == Result::UnmountFailure && !f.closes);
        f.unmountOK = true; assert(a.detach(3, 7, Fake::completion, &f));
        f.tick(f.deadline); assert(f.results.back() == Result::UnmountFailure && !f.closes);
        f.unmounted(true); assert(!f.closes); f.cleanup();
    }
    { // Removal failure retains ownership and resources until a successful retry.
        SETUP; attached(f, a); f.removeOK = false;
        assert(a.detach(3, 7, Fake::completion, &f)); f.unmounted(true);
        assert(f.results.back() == Result::RemovalFailure && !f.closes);
        f.removeOK = true; f.cleanup();
    }
    { SETUP; assert(a.start(50, Fake::completion, &f)); a.disconnect(); a.disconnect();
      assert(f.results == std::vector<Result>{Result::Disconnected});
      f.unmounted(true); assert(a.closed() && f.closes == 1); }
    { SETUP; attached(f, a); a.disconnect(); f.unmounted(true);
      assert(f.results.size() == 1 && a.closed() && f.closes == 1); }
    { SETUP; attached(f, a); assert(a.detach(3, 7, Fake::completion, &f));
      a.disconnect(); f.unmounted(true); f.unmounted(true);
      assert(f.results.size() == 2 && f.results.back() == Result::Detached && f.closes == 1); }
    { SETUP; attached(f, a); assert(a.detach(3, 7, Fake::completion, &f));
      f.now = f.deadline; f.unmounted(true);
      assert(f.results.back() == Result::UnmountFailure && !f.closes); f.cleanup(); }
    { SETUP; attached(f, a); assert(a.detach(3, 7, Fake::completion, &f));
      f.timerOK = false; f.tick(f.deadline - 1);
      assert(f.results.back() == Result::TimerFailure && !f.closes);
      f.timerOK = true; f.cleanup(); }
    { SETUP; attached(f, a); f.timerOK = false;
      assert(a.detach(3, 7, Fake::completion, &f));
      assert(f.results.back() == Result::TimerFailure && f.actions.back() == "publish");
      f.timerOK = true; f.cleanup(); }
    { // Synchronous callbacks and completion reentry cannot double-remove.
        SETUP; f.synchronousAppearance = true; f.synchronousUnmount = true;
        assert(a.start(50, [](void *p, Result r, const char *device) {
            auto &f = *static_cast<Fake *>(p); Fake::completion(p, r, device);
            assert(f.lifecycle->detach(3, 7, Fake::completion, p));
        }, &f));
        assert(f.results == (std::vector<Result>{Result::Attached, Result::Detached}));
        assert(a.closed() && f.closes == 1);
    }
}
