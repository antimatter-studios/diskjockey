#include "DJVirtualDiskBlockIO.h"
#include <cassert>
#include <cstring>
#include <vector>

namespace {
constexpr uint64_t kMiB = 1 << 20;

// A fake read backend recording every image read it is asked to start.
struct Backend {
    bool accept = true;
    unsigned reads = 0;
    uint64_t token = 0, offset = 0;
    uint32_t bytes = 0;
};

bool read(void *context, uint64_t token, uint64_t offset, uint32_t bytes) {
    auto &b = *static_cast<Backend *>(context);
    ++b.reads;
    b.token = token;
    b.offset = offset;
    b.bytes = bytes;
    return b.accept;
}

// Every completion the block-storage side would see.
struct Done {
    unsigned calls = 0;
    DJBlockIOResult result = DJBlockIOResult::Success;
    const void *data = nullptr;
    size_t length = 0;
    std::vector<unsigned char> copy;
};

void done(void *context, DJBlockIOResult result, const void *data, size_t length) {
    auto &d = *static_cast<Done *>(context);
    ++d.calls;
    d.result = result;
    d.data = data;
    d.length = length;
    d.copy.assign(static_cast<const unsigned char *>(data),
                  static_cast<const unsigned char *>(data) + (data ? length : 0));
}

using IO = DJBlockIO<4>;
DJBlockReadBackend backend(Backend &b) { return {&b, read}; }
DJMountGeometry geometry(uint64_t offset, uint64_t length, uint32_t block = 512) {
    return {offset, length, block};
}

void partitionOffsetIsAppliedOnce() {
    Backend b;
    IO io(geometry(kMiB, 8 * kMiB), backend(b));
    assert(io.blockCount() == 8 * kMiB / 512);
    Done d;
    assert(io.submit(DJBlockIOKind::Read, 3, 2, done, &d) == DJBlockIOResult::Success);
    assert(b.reads == 1 && b.offset == kMiB + 3 * 512 && b.bytes == 1024);
    assert(d.calls == 0 && io.pendingCount() == 1);
    std::vector<unsigned char> payload(1024, 0xA5);
    assert(io.complete(b.token, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(d.calls == 1 && d.result == DJBlockIOResult::Success && d.length == 1024);
    assert(d.copy == payload && io.pendingCount() == 0);

    Backend big;
    IO wide(geometry(4 * kMiB, 64 * kMiB, 4096), backend(big));
    Done w;
    assert(wide.submit(DJBlockIOKind::Read, 5, 3, done, &w) == DJBlockIOResult::Success);
    assert(big.offset == 4 * kMiB + 5 * 4096 && big.bytes == 3 * 4096);

    // A partition at the top of the 64-bit space still maps exactly.
    const uint64_t top = UINT64_C(1) << 63;
    Backend high;
    IO edge(geometry(top, UINT64_C(1) << 62), backend(high));
    const uint64_t last = edge.blockCount() - 1;
    Done e;
    assert(edge.submit(DJBlockIOKind::Read, last, 1, done, &e) == DJBlockIOResult::Success);
    assert(high.offset == top + (UINT64_C(1) << 62) - 512 && high.bytes == 512);
}

void outOfRangeAndOverflowingReadsAreRefused() {
    Backend b;
    IO io(geometry(kMiB, 8 * kMiB), backend(b));
    const uint64_t blocks = io.blockCount();
    Done d;
    const struct { uint64_t lba, count; } refused[] = {
        {blocks, 1}, {blocks - 1, 2}, {0, blocks + 1}, {UINT64_MAX, 1}, {1, UINT64_MAX},
        {UINT64_MAX / 512 + 1, 1}, {UINT64_MAX - 1, 2}, {blocks, UINT64_MAX - blocks + 1},
    };
    for (const auto &r : refused)
        assert(io.submit(DJBlockIOKind::Read, r.lba, r.count, done, &d) == DJBlockIOResult::OutOfRange);
    assert(b.reads == 0 && d.calls == 0 && io.pendingCount() == 0);

    // One read larger than the transport carries is refused, never clamped.
    assert(io.submit(DJBlockIOKind::Read, 0, kDJReadMaxBytes / 512 + 1, done, &d) ==
           DJBlockIOResult::BadArgument);
    assert(b.reads == 0);
    assert(io.submit(DJBlockIOKind::Read, blocks - 1, 1, done, &d) == DJBlockIOResult::Success);
    assert(b.offset == kMiB + 8 * kMiB - 512);

    // A geometry the mount path could never have produced serves nothing.
    const DJMountGeometry bad[] = {
        geometry(UINT64_MAX - 511, 1024), geometry(0, 0), geometry(0, 1000),
        geometry(100, 512), geometry(0, 4096, 1024),
    };
    for (const auto &g : bad) {
        Backend never;
        IO broken(g, backend(never));
        Done n;
        assert(broken.submit(DJBlockIOKind::Read, 0, 1, done, &n) == DJBlockIOResult::NotReady);
        assert(never.reads == 0 && n.calls == 0);
    }
    Done n;
    IO unbacked(geometry(0, kMiB), {nullptr, nullptr});
    assert(unbacked.submit(DJBlockIOKind::Read, 0, 1, done, &n) == DJBlockIOResult::NotReady);
    assert(io.submit(DJBlockIOKind::Read, 0, 1, nullptr, &n) == DJBlockIOResult::BadArgument);
}

void writesUnmapAndEmptyRequestsNeverReachTheBackend() {
    Backend b;
    IO io(geometry(0, 8 * kMiB), backend(b));
    Done d;
    assert(io.submit(DJBlockIOKind::Write, 0, 1, done, &d) == DJBlockIOResult::ReadOnly);
    assert(io.submit(DJBlockIOKind::Unmap, 0, 1, done, &d) == DJBlockIOResult::ReadOnly);
    assert(io.submit(DJBlockIOKind::Write, 0, 0, done, &d) == DJBlockIOResult::ReadOnly);
    assert(io.submit(DJBlockIOKind::Read, 0, 0, done, &d) == DJBlockIOResult::BadArgument);
    assert(io.submit(static_cast<DJBlockIOKind>(7), 0, 1, done, &d) == DJBlockIOResult::ReadOnly);
    assert(b.reads == 0 && d.calls == 0 && io.pendingCount() == 0);
}

void failedShortAndTimedOutReadsCarryNoBytes() {
    Backend b;
    IO io(geometry(0, 8 * kMiB), backend(b));
    std::vector<unsigned char> payload(1024, 0x5A);

    Done failed;
    assert(io.submit(DJBlockIOKind::Read, 0, 2, done, &failed) == DJBlockIOResult::Success);
    assert(io.complete(b.token, DJBlockIOResult::IOFailure, payload.data(), payload.size()));
    assert(failed.calls == 1 && failed.result == DJBlockIOResult::IOFailure);
    assert(!failed.data && failed.length == 0);

    Done shortRead;
    assert(io.submit(DJBlockIOKind::Read, 0, 2, done, &shortRead) == DJBlockIOResult::Success);
    assert(io.complete(b.token, DJBlockIOResult::Success, payload.data(), 512));
    assert(shortRead.calls == 1 && shortRead.result == DJBlockIOResult::ShortRead);
    assert(!shortRead.data && shortRead.length == 0);

    Done longRead;
    assert(io.submit(DJBlockIOKind::Read, 0, 1, done, &longRead) == DJBlockIOResult::Success);
    assert(io.complete(b.token, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(longRead.calls == 1 && longRead.result == DJBlockIOResult::IOFailure && !longRead.data);

    Done missing;
    assert(io.submit(DJBlockIOKind::Read, 0, 2, done, &missing) == DJBlockIOResult::Success);
    assert(io.complete(b.token, DJBlockIOResult::Success, nullptr, 1024));
    assert(missing.calls == 1 && missing.result == DJBlockIOResult::IOFailure && !missing.data);

    Done late;
    assert(io.submit(DJBlockIOKind::Read, 0, 2, done, &late) == DJBlockIOResult::Success);
    assert(io.complete(b.token, DJBlockIOResult::Timeout, payload.data(), payload.size()));
    assert(late.calls == 1 && late.result == DJBlockIOResult::Timeout && !late.data);

    // A backend that will not start the read still completes it, once.
    b.accept = false;
    Done refused;
    assert(io.submit(DJBlockIOKind::Read, 0, 2, done, &refused) == DJBlockIOResult::Success);
    assert(refused.calls == 1 && refused.result == DJBlockIOResult::IOFailure && !refused.data);
    assert(!io.complete(b.token, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(refused.calls == 1 && io.pendingCount() == 0);
}

// Completing again from inside the completion must not reach it twice.
struct Reentry {
    IO *io = nullptr;
    uint64_t token = 0;
    unsigned calls = 0;
    bool again = true;
};

void reenter(void *context, DJBlockIOResult, const void *data, size_t length) {
    auto &r = *static_cast<Reentry *>(context);
    ++r.calls;
    r.again = r.io->complete(r.token, DJBlockIOResult::Success, data, length);
}

// The backend completes synchronously, before submit returns.
struct Inline {
    IO *io = nullptr;
    unsigned reads = 0;
    std::vector<unsigned char> bytes = std::vector<unsigned char>(512, 0x11);
};

bool inlineRead(void *context, uint64_t token, uint64_t, uint32_t count) {
    auto &i = *static_cast<Inline *>(context);
    ++i.reads;
    i.io->complete(token, DJBlockIOResult::Success, i.bytes.data(), count);
    return true;
}

void everyAcceptedReadCompletesExactlyOnce() {
    Backend b;
    IO io(geometry(0, 8 * kMiB), backend(b));
    std::vector<unsigned char> payload(512, 0x33);

    Done d;
    assert(io.submit(DJBlockIOKind::Read, 1, 1, done, &d) == DJBlockIOResult::Success);
    const uint64_t first = b.token;
    assert(first != 0);
    assert(io.complete(first, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(!io.complete(first, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(!io.complete(first, DJBlockIOResult::IOFailure, nullptr, 0));
    assert(!io.complete(0, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(!io.complete(first + 1000, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(d.calls == 1);

    Reentry r;
    r.io = &io;
    assert(io.submit(DJBlockIOKind::Read, 0, 1, reenter, &r) == DJBlockIOResult::Success);
    r.token = b.token;
    assert(b.token != first);
    assert(io.complete(r.token, DJBlockIOResult::Success, payload.data(), payload.size()));
    assert(r.calls == 1 && !r.again);

    Inline i;
    IO synchronous(geometry(0, kMiB), {&i, inlineRead});
    i.io = &synchronous;
    Done s;
    assert(synchronous.submit(DJBlockIOKind::Read, 0, 1, done, &s) == DJBlockIOResult::Success);
    assert(i.reads == 1 && s.calls == 1 && s.result == DJBlockIOResult::Success);
    assert(s.copy == i.bytes && synchronous.pendingCount() == 0);

    // A full table refuses before the backend; teardown fails each read once.
    Done held[5];
    const unsigned before = b.reads;
    for (int n = 0; n < 4; ++n)
        assert(io.submit(DJBlockIOKind::Read, n, 1, done, &held[n]) == DJBlockIOResult::Success);
    const uint64_t lastToken = b.token;
    assert(io.submit(DJBlockIOKind::Read, 0, 1, done, &held[4]) == DJBlockIOResult::Busy);
    assert(b.reads == before + 4 && io.pendingCount() == 4);
    io.failAll(DJBlockIOResult::Success);
    io.failAll(DJBlockIOResult::Timeout);
    for (int n = 0; n < 4; ++n)
        assert(held[n].calls == 1 && held[n].result == DJBlockIOResult::IOFailure && !held[n].data);
    assert(held[4].calls == 0 && io.pendingCount() == 0);
    assert(!io.complete(lastToken, DJBlockIOResult::Success, payload.data(), payload.size()));

    Done shut;
    {
        Backend gone;
        IO dying(geometry(0, kMiB), backend(gone));
        assert(dying.submit(DJBlockIOKind::Read, 0, 1, done, &shut) == DJBlockIOResult::Success);
    }
    assert(shut.calls == 1 && shut.result == DJBlockIOResult::IOFailure);
}
} // namespace

int main() {
    partitionOffsetIsAppliedOnce();
    outOfRangeAndOverflowingReadsAreRefused();
    writesUnmapAndEmptyRequestsNeverReachTheBackend();
    failedShortAndTimedOutReadsCarryNoBytes();
    everyAcceptedReadCompletesExactlyOnce();
    return 0;
}
