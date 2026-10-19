/* Serialized host-side loop. Authorization precedes reader and connection
 * opening. The loop owns the reader; the connection owns callback delivery. */
#pragma once
#include "DJAgentReadServer.h"
#include <stdlib.h>

class DJAgentReadLoop;
struct DJAgentReadHooks {
    void *context;
    bool (*authorize)(const char *, int);
    DJAgentImageReader *(*open)(void *, int, DJAgentImageGeometry *);
    DJAgentReadFunction read;
    void (*close)(DJAgentImageReader *);
    uint64_t (*now)(void *);
    /* Version, identity and the reader's decoded virtual size, which the dext
     * records as that identity's capacity before it validates a mount. */
    bool (*connect)(void *, DJAgentReadLoop *, uint64_t, uint64_t, uint64_t);
    bool (*reply)(void *, const uint64_t *, uint32_t, const void *, size_t);
    void (*disconnect)(void *);
};
class DJAgentReadLoop {
    DJAgentReadHooks hooks;
    DJAgentImageReader *reader = nullptr;
    DJMountGeometry geometry = {};
    uint64_t deviceID = 0;
    void *payload = nullptr;
    bool connected = false;
public:
    explicit DJAgentReadLoop(DJAgentReadHooks h) : hooks(h) {}
    DJAgentReadLoop(const DJAgentReadLoop &) = delete;
    DJAgentReadLoop &operator=(const DJAgentReadLoop &) = delete;
    ~DJAgentReadLoop() { stop(); }
    bool start(const DJMountRequest &mount, int proof, uint64_t identity) {
        if (reader || !identity || !memchr(mount.path, '\0', sizeof(mount.path)) ||
            !hooks.authorize(mount.path, proof)) return false;
        DJAgentImageGeometry image = {};
        reader = hooks.open(hooks.context, proof, &image);
        if (!reader) return false;
        if (!DJMountRequestGetGeometry(&mount, sizeof(mount), image.virtualSize, &geometry) ||
            !(payload = malloc(kDJReadMaxBytes))) { stop(); return false; }
        deviceID = identity;
        connected = hooks.connect(hooks.context, this, kDJReadProtocolVersion, identity, image.virtualSize);
        if (!connected) { stop(); return false; }
        return true;
    }
    /* AsyncCompletion packs DJReadRequest into five native 64-bit words.
     * Check the count before copying, including the packed 32-bit fields. */
    void receive(bool success, const uint64_t *words, uint32_t count) {
        if (!connected) return;
        if (!success) { stop(); return; }
        static_assert(sizeof(DJReadRequest) == 5 * sizeof(uint64_t), "async request layout");
        if (!words || count != 5) return;
        DJReadRequest request;
        memcpy(&request, words, sizeof(request));
        if (request.deviceID != deviceID) return;
        DJReadReply answer;
        if (!DJAgentServeRead(&geometry, &request, sizeof(request), hooks.now(hooks.context),
                             hooks.read, reader, payload, kDJReadMaxBytes, &answer)) return;
        uint64_t scalars[kDJReadReplyScalarCount];
        DJReadReplyToScalars(&answer, scalars);
        if (!hooks.reply(hooks.context, scalars, kDJReadReplyScalarCount,
                         answer.byteCount ? payload : nullptr, answer.byteCount)) stop();
    }
    void stop() {
        if (connected) { connected = false; hooks.disconnect(hooks.context); }
        if (reader) { hooks.close(reader); reader = nullptr; }
        free(payload); payload = nullptr;
    }
};
