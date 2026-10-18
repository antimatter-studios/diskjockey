/* Portable core of one published medium's block I/O. The DriverKit child only
 * translates IOUserBlockStorageDevice reads, writes and unmaps into submit,
 * and the injected read backend's results into complete. A refused request
 * never reaches the backend; an accepted one completes exactly once, with
 * bytes only on success. Bounded and allocation-free; all calls, backend
 * completions and teardown run on one serial queue. */
#pragma once
#include "DJVirtualDiskReadShared.h"

enum class DJBlockIOResult {
    Success, BadArgument, OutOfRange, ReadOnly, Busy, NotReady, IOFailure, ShortRead, Timeout
};
enum class DJBlockIOKind { Read, Write, Unmap };

/* bytes is borrowed for the call and non-null only on Success, when length is
 * exactly the requested byte count. */
using DJBlockIOCompletion = void (*)(void *, DJBlockIOResult, const void *bytes, size_t length);

struct DJBlockReadBackend {
    void *context;
    /* Start one decoded-image read and report it through DJBlockIO::complete
     * with token, possibly before returning. False: not started, and the
     * backend must never complete the token. */
    bool (*read)(void *, uint64_t token, uint64_t imageOffset, uint32_t byteCount);
};

template <size_t Capacity = 16> class DJBlockIO {
    static_assert(Capacity > 0 && Capacity <= 64, "in-flight reads must be finite");
public:
    /* geometry is the mount's, from DJMountRequestGetGeometry. One the mount
     * path could not have produced serves nothing. */
    DJBlockIO(const DJMountGeometry &geometry, DJBlockReadBackend backend)
        : geometry_(geometry), backend_(backend) {
        const uint32_t block = geometry.blockSize;
        valid_ = (block == 512 || block == 4096) && geometry.byteLength != 0 &&
            geometry.byteOffset % block == 0 && geometry.byteLength % block == 0 &&
            geometry.byteLength <= UINT64_MAX - geometry.byteOffset;
    }
    DJBlockIO(const DJBlockIO &) = delete;
    DJBlockIO &operator=(const DJBlockIO &) = delete;
    ~DJBlockIO() { failAll(DJBlockIOResult::IOFailure); }

    uint64_t blockCount() const { return valid_ ? geometry_.byteLength / geometry_.blockSize : 0; }
    size_t pendingCount() const {
        size_t count = 0;
        for (const auto &slot : slots_) count += slot.token != 0;
        return count;
    }

    /* Anything but Success refuses the request: no backend call, no
     * completion. Success transfers it: exactly one completion follows, which
     * may run before submit returns. */
    DJBlockIOResult submit(DJBlockIOKind kind, uint64_t lba, uint64_t count,
                           DJBlockIOCompletion completion, void *context) {
        if (kind != DJBlockIOKind::Read) return DJBlockIOResult::ReadOnly;
        if (!valid_ || !backend_.read) return DJBlockIOResult::NotReady;
        if (count == 0 || !completion) return DJBlockIOResult::BadArgument;
        uint64_t end = 0, relative = 0, byteCount = 0, imageOffset = 0;
        if (__builtin_add_overflow(lba, count, &end) || end > blockCount() ||
            __builtin_mul_overflow(lba, uint64_t(geometry_.blockSize), &relative) ||
            __builtin_mul_overflow(count, uint64_t(geometry_.blockSize), &byteCount) ||
            __builtin_add_overflow(geometry_.byteOffset, relative, &imageOffset) ||
            relative > geometry_.byteLength || byteCount > geometry_.byteLength - relative)
            return DJBlockIOResult::OutOfRange;
        /* The transport never clamps; the child advertises this maximum. */
        if (byteCount > kDJReadMaxBytes) return DJBlockIOResult::BadArgument;
        Slot *slot = nullptr;
        for (auto &candidate : slots_)
            if (!candidate.token) { slot = &candidate; break; }
        if (!slot) return DJBlockIOResult::Busy;
        if (!nextToken_) return DJBlockIOResult::NotReady;

        const uint64_t token = nextToken_;
        nextToken_ = nextToken_ == UINT64_MAX ? 0 : nextToken_ + 1;
        *slot = {token, uint32_t(byteCount), completion, context};
        if (!backend_.read(backend_.context, token, imageOffset, uint32_t(byteCount)))
            finish(token, DJBlockIOResult::IOFailure, nullptr, 0);
        return DJBlockIOResult::Success;
    }

    /* The backend's one report for token. False: unknown, already completed
     * or late, and nothing reaches the block-storage side. A success whose
     * length or bytes do not match the request completes it with an error. */
    bool complete(uint64_t token, DJBlockIOResult result, const void *bytes, size_t length) {
        return finish(token, result, bytes, length);
    }

    /* Teardown or disconnect: every in-flight read fails, once. */
    void failAll(DJBlockIOResult result) {
        if (result == DJBlockIOResult::Success) result = DJBlockIOResult::IOFailure;
        for (auto &slot : slots_)
            if (slot.token) finish(slot.token, result, nullptr, 0);
    }

private:
    struct Slot {
        uint64_t token;
        uint32_t byteCount;
        DJBlockIOCompletion completion;
        void *context;
    };
    DJMountGeometry geometry_;
    DJBlockReadBackend backend_;
    bool valid_ = false;
    uint64_t nextToken_ = 1;
    Slot slots_[Capacity] = {};

    bool finish(uint64_t token, DJBlockIOResult result, const void *bytes, size_t length) {
        if (!token) return false;
        for (auto &slot : slots_) {
            if (slot.token != token) continue;
            const Slot done = slot;
            slot = Slot{};
            if (result == DJBlockIOResult::Success) {
                if (length < done.byteCount) result = DJBlockIOResult::ShortRead;
                else if (length != done.byteCount || !bytes) result = DJBlockIOResult::IOFailure;
            } else if (result != DJBlockIOResult::Timeout) {
                result = DJBlockIOResult::IOFailure;
            }
            /* Retired before the callback, so a re-entrant report is late. */
            if (result == DJBlockIOResult::Success) done.completion(done.context, result, bytes, length);
            else done.completion(done.context, result, nullptr, 0);
            return true;
        }
        return false;
    }
};
