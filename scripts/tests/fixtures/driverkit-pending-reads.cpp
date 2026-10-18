#include "DJVirtualDiskPendingReads.h"
#include <stdio.h>
#include <string.h>
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL  line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
using Pending = DJPendingReads<2>;
struct Completion {
    unsigned calls = 0;
    DJReadResult result = DJReadResult::Success;
    size_t count = 0;
    unsigned char bytes[512] = {};
    static void done(void *context, DJReadResult result, const void *data, size_t size) {
        auto &self = *static_cast<Completion *>(context);
        ++self.calls; self.result = result; self.count = size;
        CHECK((result == DJReadResult::Success) == (data != nullptr));
        CHECK(result == DJReadResult::Success || size == 0);
        if (size) { CHECK(size == sizeof(self.bytes)); memcpy(self.bytes, data, sizeof(self.bytes)); }
    }
};
struct Agent {
    uint64_t now = 100, deadline = 0;
    void (*fire)(void *) = nullptr;
    void *timerContext = nullptr;
    DJReadRequest sent[32] = {};
    unsigned sends = 0;
    bool sendOK = true, timerOK = true, synchronous = false;
    Pending *pending = nullptr;
    static uint64_t time(void *p) { return static_cast<Agent *>(p)->now; }
    static bool send(void *p, const DJReadRequest &request) {
        auto &a = *static_cast<Agent *>(p);
        a.sent[a.sends++] = request;
        if (a.synchronous) a.reply(request);
        return a.sendOK;
    }
    static bool arm(void *p, uint64_t deadline, void (*fire)(void *), void *context) {
        auto &a = *static_cast<Agent *>(p);
        a.deadline = deadline; a.fire = fire; a.timerContext = context;
        return a.timerOK;
    }
    static void cancel(void *p) { static_cast<Agent *>(p)->deadline = 0; }
    Pending::Hooks hooks() { return {this, time, send, arm, cancel}; }
    void advance(uint64_t value) {
        now = value;
        if (deadline && now >= deadline) { deadline = 0; fire(timerContext); }
    }
    void reply(const DJReadRequest &r) {
        unsigned char bytes[512];
        for (size_t i = 0; i < sizeof(bytes); ++i) bytes[i] = (r.imageOffset + i) % 251;
        DJReadReply reply = {r.requestID, r.byteCount, 0, kDJReadProtocolVersion, 0};
        pending->reply(&reply, sizeof(reply), bytes, sizeof(bytes));
    }
};
static const DJMountGeometry geometry = {4096, 2097152, 512};
static bool read(Pending &p, Completion &c, uint64_t deadline = 1000) {
    return p.submit(geometry, 11, 512, 512, deadline, Completion::done, &c);
}
int main() {
    DJReadIdentities ids;
    Agent a; Pending p(ids, a.hooks()); a.pending = &p;
    Completion first, second, excess;
    CHECK(!read(p, first) && first.calls == 0);
    CHECK(p.connect());
    CHECK(read(p, first));
    CHECK(a.sent[0].imageOffset == 4608 && a.sent[0].byteCount == 512);
    CHECK(a.sent[0].deviceID == 11 && a.sent[0].deadlineNanoseconds == 1000);
    CHECK(read(p, second, 2000));
    CHECK(!read(p, excess) && excess.calls == 0 && a.sends == 2);
    CHECK(p.pendingCount() == 2 && a.deadline == 1000);
    a.reply(a.sent[0]);
    CHECK(first.calls == 1 && first.result == DJReadResult::Success && first.count == 512);
    for (size_t i = 0; i < 512; ++i) CHECK(first.bytes[i] == (4608 + i) % 251);
    a.reply(a.sent[0]); CHECK(first.calls == 1);
    CHECK(p.pendingCount() == 1 && a.deadline == 2000);
    CHECK(read(p, excess, 1500));
    CHECK(a.sent[2].requestID != a.sent[0].requestID);
    a.reply(a.sent[0]); CHECK(excess.calls == 0); // Old slot identity cannot complete new work.
    a.advance(1500); // No agent reply drives this timeout.
    CHECK(excess.calls == 1 && excess.result == DJReadResult::Timeout && excess.count == 0);
    CHECK(excess.bytes[0] == 0 && a.deadline == 2000);
    a.reply(a.sent[2]); CHECK(excess.calls == 1);
    p.disconnect();
    CHECK(second.calls == 1 && second.result == DJReadResult::Disconnected && a.deadline == 0);
    p.disconnect(); CHECK(second.calls == 1 && p.pendingCount() == 0);
    CHECK(p.connect()); a.now = 100;
    Completion reconnected; CHECK(read(p, reconnected));
    a.reply(a.sent[1]); CHECK(reconnected.calls == 0);
    a.reply(a.sent[3]); CHECK(reconnected.calls == 1);
    // Every malformed matching reply fails without reading the supplied payload.
    for (unsigned kind = 0; kind < 7; ++kind) {
        Completion c; CHECK(read(p, c)); auto request = a.sent[a.sends - 1];
        DJReadReply reply = {request.requestID, 512, 0, 1, 0};
        size_t payloadSize = 512; const void *payload = reinterpret_cast<const void *>(1);
        if (kind == 0) payloadSize = 511;
        if (kind == 1) payloadSize = 513;
        if (kind == 2) reply.status = kDJReadReplyIOError;
        if (kind == 3) ++reply.version;
        if (kind == 4) reply.reserved = 1;
        if (kind == 5) payload = nullptr;
        if (kind == 6) --reply.byteCount;
        p.reply(&reply, sizeof(reply), payload, payloadSize);
        CHECK(c.calls == 1 && c.result != DJReadResult::Success && c.count == 0 && c.bytes[0] == 0);
        a.reply(request); CHECK(c.calls == 1 && p.pendingCount() == 0);
    }
    Completion malformed; CHECK(read(p, malformed));
    DJReadReply wrong = {UINT64_MAX, 512, 0, 1, 0};
    p.reply(nullptr, sizeof(wrong), nullptr, 0);
    p.reply(&wrong, sizeof(wrong) - 1, nullptr, 0);
    p.reply(&wrong, sizeof(wrong) + 1, nullptr, 0);
    p.reply(&wrong, sizeof(wrong), nullptr, 0);
    CHECK(malformed.calls == 0);
    a.now = 1000; a.reply(a.sent[a.sends - 1]);
    CHECK(malformed.calls == 1 && malformed.result == DJReadResult::Timeout);
    a.now = 100;
    Completion sendFailure; a.sendOK = false; CHECK(read(p, sendFailure));
    CHECK(sendFailure.calls == 1 && sendFailure.result == DJReadResult::IOFailure);
    a.sendOK = true; a.timerOK = false;
    Completion timerFailure; unsigned before = a.sends; CHECK(read(p, timerFailure));
    CHECK(timerFailure.calls == 1 && timerFailure.result == DJReadResult::TimerFailure && a.sends == before);
    a.timerOK = true; CHECK(p.connect());
    Completion sync; a.synchronous = true; a.sendOK = false; CHECK(read(p, sync));
    CHECK(sync.calls == 1 && sync.result == DJReadResult::Success && p.pendingCount() == 0);
    a.synchronous = false; a.sendOK = true;
    Completion invalid;
    CHECK(!p.submit(geometry, 11, 0, 1049088, 1000, Completion::done, &invalid));
    CHECK(!p.submit(geometry, 11, 0, 512, 1000, nullptr, &invalid));
    CHECK(invalid.calls == 0);
    Completion destroyed;
    { Pending temporary(ids, a.hooks()); CHECK(temporary.connect()); CHECK(read(temporary, destroyed)); }
    CHECK(destroyed.calls == 1 && destroyed.result == DJReadResult::Disconnected);
    DJReadIdentities lastIDs(UINT64_MAX); Agent b; Pending last(lastIDs, b.hooks()); b.pending = &last;
    CHECK(last.connect()); Completion lastRead, never; CHECK(read(last, lastRead));
    CHECK(b.sent[0].requestID == UINT64_MAX); b.reply(b.sent[0]);
    CHECK(!read(last, never)); CHECK(never.calls == 0);
    // Reentrant completions can reuse a released slot without an old send
    // failure completing the replacement request.
    struct Reentrant {
        Pending *pending; Completion completed, replacement;
        static void done(void *context, DJReadResult result, const void *data, size_t count) {
            auto &r = *static_cast<Reentrant *>(context);
            Completion::done(&r.completed, result, data, count);
            CHECK(read(*r.pending, r.replacement));
        }
    };
    Agent c; Pending reentrant(ids, c.hooks()); c.pending = &reentrant;
    CHECK(reentrant.connect()); Reentrant reentry{&reentrant, {}, {}};
    CHECK(reentrant.submit(geometry, 11, 512, 512, 1000, Reentrant::done, &reentry));
    c.reply(c.sent[0]);
    CHECK(reentry.completed.calls == 1 && reentrant.pendingCount() == 1);
    c.reply(c.sent[0]); CHECK(reentry.replacement.calls == 0);
    c.reply(c.sent[1]); CHECK(reentry.replacement.calls == 1);
    // An early/stale timer cannot expire future work. A late timer retires
    // every elapsed request, even when the endpoint sends no reply.
    Completion early, later; CHECK(read(reentrant, early)); CHECK(read(reentrant, later, 2000));
    c.fire(c.timerContext); CHECK(early.calls == 0 && later.calls == 0 && c.deadline == 1000);
    c.advance(3000);
    CHECK(early.calls == 1 && later.calls == 1 && reentrant.pendingCount() == 0);
    c.now = 100; Completion timerA, timerB;
    CHECK(read(reentrant, timerA)); c.timerOK = false;
    CHECK(read(reentrant, timerB));
    CHECK(timerA.calls == 1 && timerB.calls == 1);
    CHECK(timerA.result == DJReadResult::TimerFailure && timerB.result == DJReadResult::TimerFailure);
    c.timerOK = true; CHECK(reentrant.connect());
    Completion unaligned; CHECK(read(reentrant, unaligned));
    DJReadReply aligned = {c.sent[c.sends - 1].requestID, 512, 0, 1, 0};
    unsigned char header[sizeof(aligned) + 1], payload[512] = {};
    memcpy(header + 1, &aligned, sizeof(aligned));
    reentrant.reply(header + 1, sizeof(aligned), payload, sizeof(payload));
    CHECK(unaligned.calls == 1 && unaligned.result == DJReadResult::Success);
    return fails != 0;
}
