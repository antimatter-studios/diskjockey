/* Bounded, allocation-free lifecycle. All calls, timer callbacks and endpoint
 * replies run on one serial queue. The endpoint may reply synchronously.
 * Completion contexts stay caller-owned and alive until completion; payloads
 * are borrowed only during a successful callback and must be consumed there.
 * No output buffer is exposed on failure. */
#pragma once
#include "DJVirtualDiskReadShared.h"

enum class DJReadResult { Success, IOFailure, Timeout, Disconnected, InvalidReply, TimerFailure };

/* One sequence per service lifetime, shared by every device and connection.
 * Do not reconstruct/reset it on reconnect. Exhaustion refuses further work. */
class DJReadIdentities {
public:
    explicit DJReadIdentities(uint64_t first = 1) : next_(first) {}
    DJReadIdentities(const DJReadIdentities &) = delete;
    DJReadIdentities &operator=(const DJReadIdentities &) = delete;
    uint64_t take() {
        const uint64_t value = next_;
        if (next_) next_ = next_ == UINT64_MAX ? 0 : next_ + 1;
        return value;
    }
private:
    uint64_t next_;
};

template <size_t Capacity = 16> class DJPendingReads {
    static_assert(Capacity > 0 && Capacity <= 64, "pending slots must be finite");
public:
    using Completion = void (*)(void *, DJReadResult, const void *, size_t);
    struct Hooks {
        void *context;
        uint64_t (*now)(void *);
        // Copy the borrowed request before returning if delivery is deferred.
        bool (*send)(void *, const DJReadRequest &);
        /* Replace the one-shot timer at an absolute monotonic deadline.
         * Never invoke inline. Enqueue its callback even without any reply.
         * Return false if no timer can be guaranteed. */
        bool (*arm)(void *, uint64_t, void (*)(void *), void *);
        /* Cancel and drain callbacks before this object's destruction. */
        void (*cancel)(void *);
    };
    DJPendingReads(DJReadIdentities &identities, Hooks hooks)
        : identities_(identities), hooks_(hooks) {}
    DJPendingReads(const DJPendingReads &) = delete;
    DJPendingReads &operator=(const DJPendingReads &) = delete;
    ~DJPendingReads() { closing_ = true; disconnect(); }

    bool connect() {
        if (closing_ || draining_ || !hooks_.now || !hooks_.send ||
            !hooks_.arm || !hooks_.cancel) return false;
        connected_ = true;
        return true;
    }
    size_t pendingCount() const {
        size_t count = 0;
        for (const auto &slot : slots_) if (slot.active) ++count;
        return count;
    }
    /* False rejects ownership: no callback. True transfers exactly one
     * completion to this lifecycle, including synchronous terminal failures. */
    bool submit(const DJMountGeometry &geometry, uint64_t deviceID,
                uint64_t mediaOffset, uint64_t byteCount, uint64_t deadline,
                Completion completion, void *context) {
        if (!connected_ || !completion) return false;
        size_t index = 0;
        while (index < Capacity && slots_[index].active) ++index;
        if (index == Capacity) return false;
        const uint64_t id = identities_.take();
        DJReadRequest request;
        if (!DJReadRequestCreate(&geometry, id, deviceID, mediaOffset, byteCount,
                                  deadline, hooks_.now(hooks_.context), &request)) return false;
        slots_[index] = {request, completion, context, true};
        updateTimer();
        // Timer failure can retire this read before it reaches the endpoint.
        if (find(id) == Capacity) return true;
        const bool sent = hooks_.send(hooks_.context, request);
        // A synchronous reply/disconnect may already have released this slot.
        index = find(id);
        if (!sent && index != Capacity) finish(index, DJReadResult::IOFailure);
        updateTimer();
        return true;
    }
    /* Untrusted header bytes are checked before copying into aligned storage.
     * Unknown identities cannot retire any slot. A malformed known reply
     * fails its whole request without exposing any supplied payload bytes. */
    void reply(const void *header, size_t headerSize, const void *payload, size_t payloadSize) {
        if (draining_ || !header || headerSize != sizeof(DJReadReply)) return;
        DJReadReply answer;
        memcpy(&answer, header, sizeof(answer));
        const size_t index = find(answer.requestID);
        if (index == Capacity) return;
        const uint64_t now = hooks_.now(hooks_.context);
        const auto &request = slots_[index].request;
        if (now >= request.deadlineNanoseconds) finish(index, DJReadResult::Timeout);
        else if (!payload || !DJReadReplyIsComplete(&request, &answer, sizeof(answer), payloadSize, now))
            finish(index, DJReadResult::InvalidReply);
        else finish(index, DJReadResult::Success, payload, payloadSize);
        updateTimer();
    }
    void disconnect() { failAll(DJReadResult::Disconnected); }

private:
    struct Slot {
        DJReadRequest request;
        Completion completion;
        void *context;
        bool active;
    };
    Slot slots_[Capacity] = {};
    DJReadIdentities &identities_;
    Hooks hooks_;
    bool connected_ = false, draining_ = false, closing_ = false;

    size_t find(uint64_t id) const {
        for (size_t i = 0; i < Capacity; ++i)
            if (slots_[i].active && slots_[i].request.requestID == id) return i;
        return Capacity;
    }
    void finish(size_t index, DJReadResult result, const void *payload = nullptr, size_t count = 0) {
        const Slot slot = slots_[index];
        slots_[index].active = false; // Release before calling potentially reentrant code.
        slot.completion(slot.context, result, payload, count);
    }
    void failAll(DJReadResult result) {
        if (draining_) return;
        connected_ = false;
        draining_ = true;
        if (hooks_.cancel) hooks_.cancel(hooks_.context);
        for (size_t i = 0; i < Capacity; ++i)
            if (slots_[i].active) finish(i, result);
        draining_ = false;
    }
    static void timerFired(void *context) { static_cast<DJPendingReads *>(context)->expire(); }
    void expire() {
        if (draining_) return;
        const uint64_t now = hooks_.now(hooks_.context);
        for (size_t i = 0; i < Capacity; ++i)
            if (slots_[i].active && slots_[i].request.deadlineNanoseconds <= now)
                finish(i, DJReadResult::Timeout);
        updateTimer();
    }
    void updateTimer() {
        if (draining_ || !hooks_.cancel) return;
        uint64_t earliest = 0;
        for (const auto &slot : slots_)
            if (slot.active && (!earliest || slot.request.deadlineNanoseconds < earliest))
                earliest = slot.request.deadlineNanoseconds;
        if (!earliest) hooks_.cancel(hooks_.context);
        else if (!hooks_.arm(hooks_.context, earliest, timerFired, this))
            failAll(DJReadResult::TimerFailure);
    }
};
