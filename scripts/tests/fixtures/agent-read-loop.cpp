#include "DJAgentReadLoop.hpp"
#include <assert.h>
#include <string.h>

struct Fake {
    bool connected = true, readFails = false, replyFails = false;
    unsigned opens = 0, closes = 0, connects = 0, disconnects = 0, reads = 0, replies = 0;
    uint64_t now = 10, offset = 0;
    DJAgentReadLoop *loop = nullptr;
    DJReadReply last = {};
    unsigned char bytes[8192] = {};
    static bool authorize(const char *path, int proof) { return strcmp(path, "/allowed") == 0 && proof == 7; }
    static DJAgentImageReader *open(void *p, int, DJAgentImageGeometry *g) {
        auto &f = *static_cast<Fake *>(p); ++f.opens;
        *g = {65536, 512, 0}; return reinterpret_cast<DJAgentImageReader *>(&f);
    }
    static int read(const DJAgentImageReader *r, uint64_t offset, void *out, size_t size) {
        auto &f = *reinterpret_cast<Fake *>(const_cast<DJAgentImageReader *>(r));
        ++f.reads; f.offset = offset; memset(out, f.readFails ? 0xff : 0x5a, size);
        return f.readFails ? -1 : 0;
    }
    static void close(DJAgentImageReader *r) { ++reinterpret_cast<Fake *>(r)->closes; }
    static uint64_t clock(void *p) { return static_cast<Fake *>(p)->now; }
    static bool connect(void *p, DJAgentReadLoop *loop, uint64_t version, uint64_t identity,
                        uint64_t virtualSize) {
        auto &f = *static_cast<Fake *>(p); ++f.connects; f.loop = loop;
        assert(version == kDJReadProtocolVersion && identity == 9 && virtualSize == 65536);
        return f.connected;
    }
    static bool reply(void *p, const uint64_t *scalars, uint32_t count, const void *bytes, size_t size) {
        auto &f = *static_cast<Fake *>(p); ++f.replies;
        assert(DJReadReplyFromScalars(scalars, count, &f.last));
        assert(size == f.last.byteCount && size <= sizeof(f.bytes));
        assert(size || !bytes);
        if (size) memcpy(f.bytes, bytes, size);
        return !f.replyFails;
    }
    static void disconnect(void *p) { ++static_cast<Fake *>(p)->disconnects; }
    DJAgentReadHooks hooks() { return {this, authorize, open, read, close, clock, connect, reply, disconnect}; }
    void deliver(DJReadRequest request, unsigned count = 5) {
        uint64_t words[5]; memcpy(words, &request, sizeof(request)); loop->receive(true, words, count);
    }
};
int main() {
    DJMountRequest mount = {}; strcpy(mount.path, "/allowed");
    mount.partOffset = 4096; mount.partLength = 32768; mount.blockSize = 512;
    DJReadRequest request = {1, 9, 4608, 100, 8192, kDJReadProtocolVersion};
    Fake f;
    DJAgentReadLoop loop(f.hooks());
    assert(loop.start(mount, 7, 9));
    f.deliver(request);
    assert(f.reads == 1 && f.replies == 1 && f.offset == 4608);
    assert(f.last.status == kDJReadReplySuccess && f.last.byteCount == 8192);
    for (unsigned char b : f.bytes) assert(b == 0x5a);
    f.readFails = true; f.deliver(request);
    assert(f.replies == 2 && f.last.status == kDJReadReplyIOError && f.last.byteCount == 0);
    f.deliver(request, 4); f.deliver(request, 6);
    loop.receive(true, nullptr, 5);
    auto bad = request; bad.version = 2; f.deliver(bad);
    bad = request; bad.deviceID = 10; f.deliver(bad);
    bad = request; bad.imageOffset = 0; f.deliver(bad);
    bad = request; bad.byteCount = kDJReadMaxBytes + 1; f.deliver(bad);
    bad = request; bad.deadlineNanoseconds = f.now; f.deliver(bad);
    assert(f.reads == 2 && f.replies == 2);
    loop.stop(); loop.stop(); f.deliver(request);
    assert(f.closes == 1 && f.disconnects == 1 && f.replies == 2);
    Fake denied; DJAgentReadLoop deniedLoop(denied.hooks());
    assert(!deniedLoop.start(mount, -1, 9));
    strcpy(mount.path, "/denied"); assert(!deniedLoop.start(mount, 7, 9));
    assert(denied.opens == 0 && denied.connects == 0);
    strcpy(mount.path, "/allowed");
    Fake refused; refused.connected = false; DJAgentReadLoop refusedLoop(refused.hooks());
    assert(!refusedLoop.start(mount, 7, 9) && refused.closes == 1);
    Fake lost; DJAgentReadLoop lostLoop(lost.hooks()); assert(lostLoop.start(mount, 7, 9));
    lostLoop.receive(false, nullptr, 0); assert(lost.closes == 1 && lost.disconnects == 1);
    Fake failedReply; failedReply.replyFails = true; DJAgentReadLoop failedLoop(failedReply.hooks());
    assert(failedLoop.start(mount, 7, 9)); failedReply.deliver(request);
    assert(failedReply.closes == 1 && failedReply.disconnects == 1);
    Fake geometry; DJAgentReadLoop geometryLoop(geometry.hooks()); mount.partLength = 65536;
    assert(!geometryLoop.start(mount, 7, 9) && geometry.closes == 1 && geometry.connects == 0);
}
