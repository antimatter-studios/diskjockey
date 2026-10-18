/* One attachment's platform resources in the agent (#456, part of #452).
 * Host-only; never include in the dext. The bridge authorizes the caller's
 * image first, then discovers the dext service, then opens the image reader
 * and read endpoint (#443), and only then starts the DJAgentAttachment
 * lifecycle (#447). A refused or invalid request opens nothing.
 *
 * The lifecycle's close hook is the bridge's: the endpoint closes and the
 * service is released exactly once, only after removal (or before
 * publication). Authorization, discovery and opening stay injected.
 *
 * Publication is the dext's mount selector and removal its unmount selector
 * (#458), called on the open endpoint's connection; the dext validates the
 * request and decodes the geometry. The disk unmount between them stays the
 * lifecycle's hook. Same serial queue and lifetime rules as DJAgentAttachment.
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
    /* IOConnectCallMethod on the endpoint's user-client connection, returning
     * its kern_return_t. outputCount is the output capacity in, the count out. */
    int32_t (*call)(void *, void *endpoint, uint64_t selector, const uint64_t *input,
                    uint32_t inputCount, const void *structure, size_t structureSize,
                    uint64_t *output, uint32_t *outputCount);
};

class DJAgentBridge {
public:
    /* lifecycle supplies the clock, timer and disk unmount hooks; its publish,
     * remove and close hooks are ignored, because they belong to the bridge. */
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
        mount_ = mount;
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
    // kIOReturnNotFound: the dext holds no child for the identity.
    static constexpr int32_t notFound = int32_t(0xe00002f0);
    DJMountRequest mount_ = {};
    uint32_t service_ = 0;
    void *endpoint_ = nullptr;
    bool attempted_ = false;

    bool complete() const {
        return platform_.authorize && platform_.discover && platform_.release &&
            platform_.open && platform_.close && platform_.call && lifecycle_.now &&
            lifecycle_.arm && lifecycle_.cancel && lifecycle_.unmount;
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
    /* The identity and the request in; the device ID out, which must be the
     * identity, or the child is not this attachment's. */
    static bool publish(void *c, uint64_t id) {
        auto &b = self(c);
        uint64_t device = 0;
        uint32_t count = 1;
        return b.endpoint_ &&
            b.platform_.call(b.platform_.context, b.endpoint_, kDJSelectorMountImage, &id, 1,
                             &b.mount_, sizeof(b.mount_), &device, &count) == 0 &&
            count == 1 && device == id;
    }
    static bool unmount(void *c, uint64_t id, uint64_t attempt, const char *device) {
        auto &b = self(c); return b.lifecycle_.unmount(b.lifecycle_.context, id, attempt, device);
    }
    /* Idempotent: identities are never reused, so a dext holding no child for
     * this one (never created, or already removed) has removed it. */
    static bool remove(void *c, uint64_t id) {
        auto &b = self(c);
        uint32_t count = 0;
        if (!b.endpoint_) return false;
        const int32_t status = b.platform_.call(b.platform_.context, b.endpoint_,
                                                kDJSelectorUnmountImage, &id, 1, nullptr, 0,
                                                nullptr, &count);
        return status == 0 || status == notFound;
    }
    static void close(void *c) { self(c).closeResources(); }
    static DJAgentAttachment::Hooks hooks(DJAgentBridge *bridge) {
        return {bridge, now, arm, cancel, publish, unmount, remove, close};
    }
};
