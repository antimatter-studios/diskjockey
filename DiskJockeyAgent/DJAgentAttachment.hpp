/* One authorized attachment, owned by one trusted XPC connection. Identity
 * allocation, file authorization and platform APIs belong to the bridge.
 * Never reuse an attachment identity within a service lifetime.
 *
 * All methods, disk events, unmount replies and active timer callbacks share
 * one serial queue. Only publish -> appeared and unmount -> unmounted may
 * reenter synchronously. Completions may call detach/disconnect, but must not
 * destroy this object until the calling stack unwinds. Keep this object and
 * its hooks alive until closed(); cancel must drain timer callbacks before
 * destruction. Failed cleanup retains ownership for a trusted retry.
 */
#pragma once
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum class DJAttachmentResult {
    Attached, Detached, PublicationFailure, AppearanceTimeout, TimerFailure,
    UnmountFailure, RemovalFailure, Disconnected,
};

class DJAgentAttachment {
public:
    static constexpr uint64_t maxWaitNanoseconds = 30ULL * 1000000000ULL;
    using Completion = void (*)(void *, DJAttachmentResult, const char *);
    struct Hooks {
        void *context;
        uint64_t (*now)(void *);
        // Replace an active monotonic timer; never invoke its callback inline.
        bool (*arm)(void *, uint64_t, void (*)(void *), void *);
        void (*cancel)(void *);
        bool (*publish)(void *, uint64_t attachmentID);
        /* A null BSD name requires resolving the OWNED attachment identity,
         * not choosing another disk. Success starts an asynchronous unmount;
         * reply with both IDs, including when the owned child never appeared. */
        bool (*unmount)(void *, uint64_t attachmentID, uint64_t attempt, const char *);
        // Idempotently remove only this owned child, after successful unmount.
        bool (*remove)(void *, uint64_t attachmentID);
        // Close the reader/connection only after removal (or before publication).
        void (*close)(void *);
    };
    DJAgentAttachment(uint64_t owner, uint64_t identity, Hooks hooks)
        : owner_(owner), identity_(identity), hooks_(hooks) {}
    DJAgentAttachment(const DJAgentAttachment &) = delete;
    DJAgentAttachment &operator=(const DJAgentAttachment &) = delete;
    ~DJAgentAttachment() { assert(state_ == State::Fresh || state_ == State::Closed); }
    bool closed() const { return state_ == State::Closed; }

    /* False rejects ownership and never calls completion. True takes exactly
     * one attach completion and ownership of the prepared reader/connection. */
    bool start(uint64_t waitNanoseconds, Completion completion, void *context) {
        if (state_ != State::Fresh || disconnected_ || !owner_ || !identity_ || !completion ||
            !hooks_.now || !hooks_.arm || !hooks_.cancel || !hooks_.publish ||
            !hooks_.unmount || !hooks_.remove || !hooks_.close || !waitNanoseconds ||
            waitNanoseconds > maxWaitNanoseconds) return false;
        const uint64_t now = hooks_.now(hooks_.context);
        if (waitNanoseconds > UINT64_MAX - now) return false;
        deadline_ = now + waitNanoseconds;
        completion_ = completion; context_ = context; state_ = State::Waiting;
        if (!arm()) {
            state_ = State::Closed; hooks_.cancel(hooks_.context);
            hooks_.close(hooks_.context); notify(DJAttachmentResult::TimerFailure);
            return true;
        }
        publishing_ = true;
        const bool published = hooks_.publish(hooks_.context, identity_);
        publishing_ = false;
        if (!published) failAttach(DJAttachmentResult::PublicationFailure);
        else if (hooks_.now(hooks_.context) >= deadline_) failAttach(DJAttachmentResult::AppearanceTimeout);
        else if (device_[0]) finishAttach();
        return true;
    }
    /* The bridge derives identity from the owned IOMedia ancestry. A path or
     * BSD number alone is not proof. size includes exactly one terminal NUL. */
    void appeared(uint64_t identity, const char *device, size_t size) {
        if (state_ != State::Waiting || identity != identity_ || device_[0] ||
            !validDevice(device, size)) return;
        if (hooks_.now(hooks_.context) >= deadline_) {
            if (!publishing_) failAttach(DJAttachmentResult::AppearanceTimeout);
            return;
        }
        memcpy(device_, device, size);
        if (!publishing_) finishAttach();
    }
    bool detach(uint64_t owner, uint64_t identity, Completion completion, void *context) {
        if (owner != owner_ || identity != identity_ || !completion || disconnected_ ||
            (state_ != State::Attached && state_ != State::Retained)) return false;
        completion_ = completion; context_ = context;
        cleanup();
        return true;
    }
    void unmounted(uint64_t identity, uint64_t attempt, bool success) {
        if (state_ != State::Unmounting || identity != identity_ || attempt != attempt_) return;
        if (!success || hooks_.now(hooks_.context) >= deadline_) {
            retain(DJAttachmentResult::UnmountFailure); return;
        }
        hooks_.cancel(hooks_.context);
        if (!hooks_.remove(hooks_.context, identity_)) {
            state_ = State::Retained; notify(DJAttachmentResult::RemovalFailure); return;
        }
        state_ = State::Closed;
        hooks_.close(hooks_.context);
        notify(DJAttachmentResult::Detached);
    }
    // Trusted connection invalidation, also usable to retry failed cleanup.
    void disconnect() {
        disconnected_ = true;
        if (state_ == State::Waiting) failAttach(DJAttachmentResult::Disconnected);
        else if (state_ == State::Attached || state_ == State::Retained) cleanup();
    }
private:
    enum class State { Fresh, Waiting, Attached, Unmounting, Retained, Closed };
    const uint64_t owner_, identity_;
    Hooks hooks_;
    State state_ = State::Fresh;
    Completion completion_ = nullptr;
    void *context_ = nullptr;
    char device_[32] = {};
    uint64_t deadline_ = 0, attempt_ = 0;
    bool publishing_ = false, disconnected_ = false;

    static bool validDevice(const char *device, size_t size) {
        if (!device || size < 11 || size > 32 ||
            memcmp(device, "/dev/disk", 9) != 0 || device[size - 1] != '\0') return false;
        for (size_t i = 9; i < size - 1; ++i)
            if (device[i] < '0' || device[i] > '9') return false;
        return true;
    }
    bool arm() { return hooks_.arm(hooks_.context, deadline_, timer, this); }
    static void timer(void *context) { static_cast<DJAgentAttachment *>(context)->expired(); }
    void expired() {
        if (state_ != State::Waiting && state_ != State::Unmounting) return;
        if (hooks_.now(hooks_.context) < deadline_) {
            if (!arm()) {
                if (state_ == State::Waiting) failAttach(DJAttachmentResult::TimerFailure);
                else retain(DJAttachmentResult::TimerFailure);
            }
        } else if (state_ == State::Waiting) failAttach(DJAttachmentResult::AppearanceTimeout);
        else retain(DJAttachmentResult::UnmountFailure);
    }
    void notify(DJAttachmentResult result) {
        const auto completion = completion_;
        void *const context = context_;
        completion_ = nullptr; context_ = nullptr;
        // Borrowed for this callback only, even if it reenters detach.
        char device[sizeof(device_)]; memcpy(device, device_, sizeof(device));
        if (completion) completion(context, result, result == DJAttachmentResult::Attached ? device : nullptr);
    }
    void finishAttach() {
        state_ = State::Attached; hooks_.cancel(hooks_.context);
        notify(DJAttachmentResult::Attached);
    }
    void failAttach(DJAttachmentResult result) {
        const auto completion = completion_; void *const context = context_;
        completion_ = nullptr; context_ = nullptr;
        cleanup();
        if (completion) completion(context, result, nullptr);
    }
    void retain(DJAttachmentResult result) {
        state_ = State::Retained; hooks_.cancel(hooks_.context); notify(result);
    }
    void cleanup() {
        hooks_.cancel(hooks_.context);
        state_ = State::Unmounting;
        const uint64_t now = hooks_.now(hooks_.context);
        if (maxWaitNanoseconds > UINT64_MAX - now || attempt_ == UINT64_MAX) {
            retain(DJAttachmentResult::TimerFailure); return;
        }
        deadline_ = now + maxWaitNanoseconds;
        const uint64_t attempt = ++attempt_;
        if (!arm()) { retain(DJAttachmentResult::TimerFailure); return; }
        const bool started = hooks_.unmount(hooks_.context, identity_, attempt, device_[0] ? device_ : nullptr);
        // A synchronous reply may already have completed, or started a retry.
        if (!started && state_ == State::Unmounting && attempt == attempt_)
            retain(DJAttachmentResult::UnmountFailure);
    }
};
