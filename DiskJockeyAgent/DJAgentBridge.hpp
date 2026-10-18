/* One attachment's platform resources in the agent (#456, part of #452).
 * Host-only; never include in the dext. The bridge authorizes the caller's
 * image first, then discovers the dext service, then opens the image reader
 * and read endpoint (#443), and only then starts the DJAgentAttachment
 * lifecycle (#447). A refused or invalid request opens nothing.
 *
 * The lifecycle's close hook is the bridge's: the endpoint closes and the
 * service is released exactly once, only after removal (or before
 * publication). Authorization, discovery, opening and the publish, unmount
 * and remove hooks stay injected; #458 backs the last three with #394's
 * selectors. Same serial queue and lifetime rules as DJAgentAttachment.
 */
#pragma once
#include "DJAgentAttachment.hpp"
#include "../DiskJockeyVirtualDisk/DJVirtualDiskShared.h"

struct DJAgentBridgePlatform {
    void *context;
    /* AgentAuthority.attachableImage: path is the image, proof the caller's
     * open descriptor. Called before anything is discovered or opened. */
    bool (*authorize)(void *, const char *path, int proof);
    /* The dext service, or 0 (IO_OBJECT_NULL) when there is none. */
    uint32_t (*discover)(void *);
    void (*release)(void *, uint32_t service);
    /* DJAgentReadEndpointOpen: the reader and the user-client connection.
     * Null means nothing stayed open. */
    void *(*open)(void *, uint32_t service, const DJMountRequest *, int proof, uint64_t identity);
    void (*close)(void *, void *endpoint);
};

class DJAgentBridge {
public:
    /* lifecycle supplies the clock, timer and child hooks; its close hook is
     * ignored, because closing belongs to the bridge. */
    DJAgentBridge(uint64_t owner, uint64_t identity, DJAgentBridgePlatform platform,
                  DJAgentAttachment::Hooks lifecycle)
        : platform_(platform), lifecycle_(lifecycle), attachment_(owner, identity, hooks(this)),
          owner_(owner), identity_(identity) {}
    DJAgentBridge(const DJAgentBridge &) = delete;
    DJAgentBridge &operator=(const DJAgentBridge &) = delete;
    ~DJAgentBridge() { assert(!service_ && !endpoint_); }

    /* One attempt per bridge. False opens nothing and never calls completion.
     * True is DJAgentAttachment::start's: exactly one attach completion. */
    bool attach(const DJMountRequest &mount, int proof, uint64_t waitNanoseconds,
                DJAgentAttachment::Completion completion, void *context) {
        if (attempted_ || !owner_ || !identity_ || proof < 0 || !completion ||
            !waitNanoseconds || waitNanoseconds > DJAgentAttachment::maxWaitNanoseconds ||
            !memchr(mount.path, '\0', sizeof(mount.path)) || !complete()) return false;
        attempted_ = true;
        if (!platform_.authorize(platform_.context, mount.path, proof)) return false;
        if (!(service_ = platform_.discover(platform_.context))) return false;
        endpoint_ = platform_.open(platform_.context, service_, &mount, proof, identity_);
        if (!endpoint_ || !attachment_.start(waitNanoseconds, completion, context)) {
            closeResources();
            return false;
        }
        return true;
    }
    /* appeared, detach, unmounted and disconnect go to the lifecycle. */
    DJAgentAttachment &lifecycle() { return attachment_; }

private:
    DJAgentBridgePlatform platform_;
    DJAgentAttachment::Hooks lifecycle_;
    DJAgentAttachment attachment_;
    const uint64_t owner_, identity_;
    uint32_t service_ = 0;
    void *endpoint_ = nullptr;
    bool attempted_ = false;

    bool complete() const {
        return platform_.authorize && platform_.discover && platform_.release &&
            platform_.open && platform_.close && lifecycle_.now && lifecycle_.arm &&
            lifecycle_.cancel && lifecycle_.publish && lifecycle_.unmount && lifecycle_.remove;
    }
    void closeResources() {
        if (endpoint_) { void *const endpoint = endpoint_; endpoint_ = nullptr;
            platform_.close(platform_.context, endpoint); }
        if (service_) { const uint32_t service = service_; service_ = 0;
            platform_.release(platform_.context, service); }
    }
    static DJAgentBridge &self(void *context) { return *static_cast<DJAgentBridge *>(context); }
    static uint64_t now(void *c) { auto &b = self(c); return b.lifecycle_.now(b.lifecycle_.context); }
    static bool arm(void *c, uint64_t deadline, void (*callback)(void *), void *context) {
        auto &b = self(c); return b.lifecycle_.arm(b.lifecycle_.context, deadline, callback, context);
    }
    static void cancel(void *c) { auto &b = self(c); b.lifecycle_.cancel(b.lifecycle_.context); }
    static bool publish(void *c, uint64_t id) {
        auto &b = self(c); return b.lifecycle_.publish(b.lifecycle_.context, id);
    }
    static bool unmount(void *c, uint64_t id, uint64_t attempt, const char *device) {
        auto &b = self(c); return b.lifecycle_.unmount(b.lifecycle_.context, id, attempt, device);
    }
    static bool remove(void *c, uint64_t id) {
        auto &b = self(c); return b.lifecycle_.remove(b.lifecycle_.context, id);
    }
    static void close(void *c) { self(c).closeResources(); }
    static DJAgentAttachment::Hooks hooks(DJAgentBridge *bridge) {
        return {bridge, now, arm, cancel, publish, unmount, remove, close};
    }
};
