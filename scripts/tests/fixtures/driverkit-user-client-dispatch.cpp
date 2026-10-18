#include "DJVirtualDiskUserClientDispatch.h"
#include <stdio.h>
#include <string.h>
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL  line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
using Dispatch = DJUserClientDispatch<>;
struct Completion {
    unsigned calls = 0;
    DJReadResult result = DJReadResult::Success;
    size_t count = 0;
    unsigned char bytes[512] = {};
    static void done(void *context, DJReadResult result, const void *data, size_t size) {
        auto &self = *static_cast<Completion *>(context);
        ++self.calls; self.result = result; self.count = size;
        CHECK((result == DJReadResult::Success) == (data != nullptr));
        if (size) { CHECK(size == sizeof(self.bytes)); memcpy(self.bytes, data, sizeof(self.bytes)); }
    }
};
// The agent's side of the user client: it only ever sees delivered requests
// and answers through the dispatch core's external methods.
struct Endpoint {
    uint64_t now = 100, deadline = 0;
    void (*fire)(void *) = nullptr;
    void *timerContext = nullptr;
    DJReadRequest sent[32] = {};
    void *sentTo[32] = {};
    unsigned sends = 0, releases = 0;
    void *released = nullptr;
    bool deliverOK = true;
    static uint64_t time(void *p) { return static_cast<Endpoint *>(p)->now; }
    static bool arm(void *p, uint64_t deadline, void (*fire)(void *), void *context) {
        auto &e = *static_cast<Endpoint *>(p);
        e.deadline = deadline; e.fire = fire; e.timerContext = context;
        return true;
    }
    static void cancel(void *p) { static_cast<Endpoint *>(p)->deadline = 0; }
    static bool deliver(void *p, void *completion, const DJReadRequest &request) {
        auto &e = *static_cast<Endpoint *>(p);
        if (e.sends < 32) { e.sentTo[e.sends] = completion; e.sent[e.sends] = request; }
        ++e.sends;
        return e.deliverOK;
    }
    static void release(void *p, void *completion) {
        auto &e = *static_cast<Endpoint *>(p);
        ++e.releases; e.released = completion;
    }
    Dispatch::Platform platform() { return {this, time, arm, cancel, deliver, release}; }
    void advance(uint64_t value) {
        now = value;
        if (deadline && now >= deadline) { deadline = 0; fire(timerContext); }
    }
};
static const DJMountGeometry geometry = {4096, 2097152, 512};
static int token;
static void *const action = &token; // Stands in for the agent's OSAction.
static const uint64_t version[1] = {kDJReadProtocolVersion};
static DJDispatchArguments connectArguments() {
    DJDispatchArguments a = {};
    a.scalarInput = version; a.scalarInputCount = 1; a.completion = action;
    return a;
}
static DJDispatchArguments replyArguments(const DJReadReply *reply, const void *payload, size_t size) {
    DJDispatchArguments a = {};
    a.structureInput = reply; a.structureInputSize = sizeof(*reply);
    a.payload = payload; a.payloadSize = size;
    return a;
}
static void fill(unsigned char *bytes, size_t size, uint64_t offset) {
    for (size_t i = 0; i < size; ++i) bytes[i] = (offset + i) % 251;
}
static bool read(Dispatch &d, Completion &c, uint64_t deadline = 1000) {
    return d.submit(geometry, 11, 512, 512, deadline, Completion::done, &c);
}
int main() {
    DJReadIdentities ids;
    Endpoint e; Dispatch d(ids, e.platform());
    Completion early; CHECK(!read(d, early) && early.calls == 0 && e.sends == 0);

    // Connect: every argument shape other than the table's exact one is refused
    // and leaves no endpoint connected.
    for (unsigned kind = 0; kind < 8; ++kind) {
        DJDispatchArguments a = connectArguments();
        const uint64_t two[2] = {kDJReadProtocolVersion, 0}, wrong[1] = {kDJReadProtocolVersion + 1};
        unsigned char extra[8] = {};
        if (kind == 0) a.scalarInputCount = 0;
        if (kind == 1) { a.scalarInput = two; a.scalarInputCount = 2; }
        if (kind == 2) a.scalarInput = wrong;
        if (kind == 3) { a.structureInput = extra; a.structureInputSize = sizeof(extra); }
        if (kind == 4) a.completion = nullptr;
        if (kind == 5) a.scalarOutputCount = 1;
        if (kind == 6) a.structureOutputMaximumSize = 8;
        if (kind == 7) { a.payload = extra; a.payloadSize = sizeof(extra); }
        CHECK(d.externalMethod(kDJSelectorConnectReadEndpoint, a) == DJDispatchResult::BadArgument);
        CHECK(!d.connected());
    }
    CHECK(d.externalMethod(6, connectArguments()) == DJDispatchResult::Unsupported);
    CHECK(d.externalMethod(UINT64_MAX, connectArguments()) == DJDispatchResult::Unsupported);
    CHECK(!d.connected() && e.releases == 0);
    CHECK(d.externalMethod(kDJSelectorConnectReadEndpoint, connectArguments()) == DJDispatchResult::Success);
    CHECK(d.connected());
    int other; DJDispatchArguments second = connectArguments(); second.completion = &other;
    CHECK(d.externalMethod(kDJSelectorConnectReadEndpoint, second) == DJDispatchResult::Busy);
    CHECK(e.releases == 0);

    // Exact bytes at the translated offset arrive at the connected endpoint.
    Completion first; CHECK(read(d, first));
    CHECK(e.sends == 1 && e.sentTo[0] == action);
    CHECK(e.sent[0].imageOffset == 4608 && e.sent[0].byteCount == 512);
    CHECK(e.sent[0].deviceID == 11 && e.sent[0].deadlineNanoseconds == 1000);
    CHECK(d.pendingCount() == 1);

    // Wrong sizes and unknown selectors are refused before any copy and never
    // retire, fail or answer the pending request.
    unsigned char payload[512]; fill(payload, sizeof(payload), e.sent[0].imageOffset);
    DJReadReply reply = {e.sent[0].requestID, 512, kDJReadReplySuccess, kDJReadProtocolVersion, 0};
    unsigned char header[sizeof(reply) + 1] = {};
    memcpy(header, &reply, sizeof(reply));
    for (unsigned kind = 0; kind < 11; ++kind) {
        DJDispatchArguments a = replyArguments(&reply, payload, sizeof(payload));
        if (kind == 0) { a.structureInput = header; a.structureInputSize = sizeof(reply) - 1; }
        if (kind == 1) { a.structureInput = header; a.structureInputSize = sizeof(reply) + 1; }
        if (kind == 2) a.structureInput = nullptr;
        if (kind == 3) a.structureInputSize = 0;
        if (kind == 4) a.payloadSize = size_t(kDJReadMaxBytes) + 1; // Never read: refused on size.
        if (kind == 5) a.payload = nullptr;
        if (kind == 6) { a.scalarInput = version; a.scalarInputCount = 1; }
        if (kind == 7) a.completion = action;
        if (kind == 8) a.scalarOutputCount = 1;
        if (kind == 9) a.structureOutputMaximumSize = 512;
        if (kind == 10) a.scalarInputCount = 1; // A count without scalars is refused too.
        CHECK(d.externalMethod(kDJSelectorDeliverReadReply, a) == DJDispatchResult::BadArgument);
        CHECK(first.calls == 0 && d.pendingCount() == 1 && d.connected());
    }
    CHECK(d.externalMethod(6, replyArguments(&reply, payload, sizeof(payload))) == DJDispatchResult::Unsupported);
    CHECK(d.externalMethod(UINT64_MAX, replyArguments(&reply, payload, sizeof(payload))) == DJDispatchResult::Unsupported);
    DJDispatchArguments badDisconnect = {}; badDisconnect.scalarInput = version; badDisconnect.scalarInputCount = 1;
    CHECK(d.externalMethod(kDJSelectorDisconnectReadEndpoint, badDisconnect) == DJDispatchResult::BadArgument);
    badDisconnect = {}; badDisconnect.completion = action;
    CHECK(d.externalMethod(kDJSelectorDisconnectReadEndpoint, badDisconnect) == DJDispatchResult::BadArgument);
    badDisconnect = {}; badDisconnect.structureInput = &reply; badDisconnect.structureInputSize = sizeof(reply);
    CHECK(d.externalMethod(kDJSelectorDisconnectReadEndpoint, badDisconnect) == DJDispatchResult::BadArgument);
    CHECK(first.calls == 0 && d.pendingCount() == 1 && d.connected() && e.releases == 0);

    // A complete reply through the reply selector publishes exactly those bytes.
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&reply, payload, sizeof(payload))) == DJDispatchResult::Success);
    CHECK(first.calls == 1 && first.result == DJReadResult::Success && first.count == 512);
    for (size_t i = 0; i < 512; ++i) CHECK(first.bytes[i] == (4608 + i) % 251);
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&reply, payload, sizeof(payload))) == DJDispatchResult::Success);
    CHECK(first.calls == 1 && d.pendingCount() == 0);

    // Short and error replies are well-formed calls that fail their request.
    Completion shortRead; CHECK(read(d, shortRead));
    DJReadReply shortReply = {e.sent[e.sends - 1].requestID, 511, kDJReadReplySuccess, kDJReadProtocolVersion, 0};
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&shortReply, payload, 511)) == DJDispatchResult::Success);
    CHECK(shortRead.calls == 1 && shortRead.result == DJReadResult::InvalidReply && shortRead.count == 0);
    CHECK(shortRead.bytes[0] == 0);
    Completion errorRead; CHECK(read(d, errorRead));
    DJReadReply errorReply = {e.sent[e.sends - 1].requestID, 0, kDJReadReplyIOError, kDJReadProtocolVersion, 0};
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&errorReply, nullptr, 0)) == DJDispatchResult::Success);
    CHECK(errorRead.calls == 1 && errorRead.result == DJReadResult::InvalidReply && errorRead.count == 0);

    // A timeout fails the request with no reply from the endpoint.
    Completion slow; CHECK(read(d, slow, 1500));
    e.advance(1500);
    CHECK(slow.calls == 1 && slow.result == DJReadResult::Timeout && slow.count == 0);
    DJReadReply late = {e.sent[e.sends - 1].requestID, 512, kDJReadReplySuccess, kDJReadProtocolVersion, 0};
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&late, payload, sizeof(payload))) == DJDispatchResult::Success);
    CHECK(slow.calls == 1);
    e.now = 100;

    // A delivery the endpoint cannot accept fails its request at once.
    Completion undelivered; e.deliverOK = false; CHECK(read(d, undelivered));
    CHECK(undelivered.calls == 1 && undelivered.result == DJReadResult::IOFailure);
    e.deliverOK = true;

    // Disconnect fails every pending request and releases the endpoint once.
    Completion dropped; CHECK(read(d, dropped));
    DJDispatchArguments disconnect = {};
    CHECK(d.externalMethod(kDJSelectorDisconnectReadEndpoint, disconnect) == DJDispatchResult::Success);
    CHECK(dropped.calls == 1 && dropped.result == DJReadResult::Disconnected && dropped.count == 0);
    CHECK(!d.connected() && e.releases == 1 && e.released == action && e.deadline == 0);
    CHECK(d.externalMethod(kDJSelectorDisconnectReadEndpoint, disconnect) == DJDispatchResult::Success);
    CHECK(e.releases == 1);
    DJReadReply afterDrop = {e.sent[e.sends - 1].requestID, 512, kDJReadReplySuccess, kDJReadProtocolVersion, 0};
    CHECK(d.externalMethod(kDJSelectorDeliverReadReply, replyArguments(&afterDrop, payload, sizeof(payload))) == DJDispatchResult::NotReady);
    Completion offline; CHECK(!read(d, offline) && offline.calls == 0);

    // Delivery is bounded by the sixteen pending slots.
    CHECK(d.externalMethod(kDJSelectorConnectReadEndpoint, connectArguments()) == DJDispatchResult::Success);
    Completion many[17]; const unsigned before = e.sends;
    for (unsigned i = 0; i < 16; ++i) CHECK(read(d, many[i]));
    CHECK(!read(d, many[16]) && many[16].calls == 0);
    CHECK(e.sends - before == 16 && d.pendingCount() == 16);

    // The client dying is a disconnect: every slot fails, nothing leaks.
    d.stop();
    for (unsigned i = 0; i < 16; ++i) CHECK(many[i].calls == 1 && many[i].result == DJReadResult::Disconnected);
    CHECK(!d.connected() && e.releases == 2 && d.pendingCount() == 0);

    // Destroying a connected core fails its work and releases the endpoint.
    Endpoint f; Completion orphan;
    {
        Dispatch temporary(ids, f.platform());
        CHECK(temporary.externalMethod(kDJSelectorConnectReadEndpoint, connectArguments()) == DJDispatchResult::Success);
        CHECK(read(temporary, orphan));
    }
    CHECK(orphan.calls == 1 && orphan.result == DJReadResult::Disconnected && f.releases == 1);
    return fails != 0;
}
