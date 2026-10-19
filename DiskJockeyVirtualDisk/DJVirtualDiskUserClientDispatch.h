/* Portable dispatch core for the DJVirtualDisk user client's read transport.
 * The DriverKit IOUserClient maps IOUserClientMethodArguments onto
 * DJDispatchArguments (the reply payload is its one structure input, inline or
 * a mapped descriptor) and calls externalMethod on DJPendingReads' serial queue. Every
 * count and size is checked against the table before any copy, and a refused
 * call never touches the endpoint or any pending read. */
#pragma once
#include "DJVirtualDiskPendingReads.h"

enum class DJDispatchResult { Success, BadArgument, Unsupported, NotReady, Busy };

/* Untrusted caller arguments. payload is the call's one structure input,
 * inline or a mapped descriptor; no method takes any other structure, so the
 * table refuses a nonzero structureInputSize. completion is the async action. */
struct DJDispatchArguments {
    const uint64_t *scalarInput;
    uint32_t scalarInputCount;
    const void *structureInput;
    size_t structureInputSize;
    const void *payload;
    size_t payloadSize;
    uint32_t scalarOutputCount;
    size_t structureOutputMaximumSize;
    void *completion;
};

/* Exact scalar count and structure size, a payload ceiling, and whether an
 * async completion is required (true) or forbidden (false). No method has a
 * scalar or structure output. */
struct DJDispatchMethod {
    uint64_t selector;
    uint32_t scalarInputCount;
    size_t structureInputSize;
    size_t payloadMaximumSize;
    bool completion;
};

static constexpr DJDispatchMethod kDJReadDispatchMethods[] = {
    {kDJSelectorConnectReadEndpoint, kDJReadConnectScalarCount, 0, 0, true},
    {kDJSelectorDeliverReadReply, kDJReadReplyScalarCount, 0, kDJReadMaxBytes, false},
    {kDJSelectorDisconnectReadEndpoint, 0, 0, 0, false},
};

static inline bool DJDispatchArgumentsMatch(const DJDispatchMethod &method,
                                            const DJDispatchArguments &arguments) {
    if (arguments.scalarInputCount != method.scalarInputCount ||
        (method.scalarInputCount && !arguments.scalarInput)) return false;
    if (arguments.structureInputSize != method.structureInputSize ||
        (method.structureInputSize && !arguments.structureInput)) return false;
    if (arguments.payloadSize > method.payloadMaximumSize ||
        (arguments.payloadSize && !arguments.payload)) return false;
    return arguments.scalarOutputCount == 0 && arguments.structureOutputMaximumSize == 0 &&
        (arguments.completion != nullptr) == method.completion;
}

/* Request delivery is bounded to the pending slots: at most sixteen reads are
 * ever outstanding at the endpoint, each with a reply of at most 1 MiB. */
template <size_t Capacity = 16> class DJUserClientDispatch {
    static_assert(Capacity > 0 && Capacity <= 16, "request delivery is bounded to 16 reads");
public:
    using Pending = DJPendingReads<Capacity>;
    struct Platform {
        void *context;
        uint64_t (*now)(void *);
        bool (*arm)(void *, uint64_t, void (*)(void *), void *);
        void (*cancel)(void *);
        /* Hand one request to the endpoint's completion; copy it before
         * returning. False fails that read at once. */
        bool (*deliver)(void *, void *, const DJReadRequest &);
        /* Drop the endpoint's completion, after its reads have failed. */
        void (*release)(void *, void *);
    };
    DJUserClientDispatch(DJReadIdentities &identities, Platform platform)
        : platform_(platform), pending_(identities, {this, now, send, arm, cancel}) {}
    DJUserClientDispatch(const DJUserClientDispatch &) = delete;
    DJUserClientDispatch &operator=(const DJUserClientDispatch &) = delete;
    ~DJUserClientDispatch() { stop(); }

    /* On Success from connect the core owns the completion and releases it
     * exactly once; on any refusal the caller still owns it. */
    DJDispatchResult externalMethod(uint64_t selector, const DJDispatchArguments &arguments) {
        const DJDispatchMethod *method = nullptr;
        for (const auto &entry : kDJReadDispatchMethods)
            if (entry.selector == selector) method = &entry;
        if (!method) return DJDispatchResult::Unsupported;
        if (!DJDispatchArgumentsMatch(*method, arguments)) return DJDispatchResult::BadArgument;
        switch (selector) {
        case kDJSelectorConnectReadEndpoint: return connect(arguments);
        case kDJSelectorDeliverReadReply: {
            DJReadReply header;
            if (!DJReadReplyFromScalars(arguments.scalarInput, arguments.scalarInputCount, &header))
                return DJDispatchResult::BadArgument;
            if (!endpoint_) return DJDispatchResult::NotReady;
            pending_.reply(&header, sizeof(header), arguments.payload, arguments.payloadSize);
            return DJDispatchResult::Success;
        }
        default:
            stop();
            return DJDispatchResult::Success;
        }
    }
    /* The block-storage side's read; see DJPendingReads::submit. */
    bool submit(const DJMountGeometry &geometry, uint64_t deviceID, uint64_t mediaOffset,
                uint64_t byteCount, uint64_t deadline,
                typename Pending::Completion completion, void *context) {
        return endpoint_ && pending_.submit(geometry, deviceID, mediaOffset, byteCount,
                                            deadline, completion, context);
    }
    /* Disconnect, client death and teardown: fail every read, then release. */
    void stop() {
        void *const endpoint = endpoint_;
        pending_.disconnect();
        endpoint_ = nullptr;
        identity_ = 0;
        virtualSize_ = 0;
        if (endpoint) platform_.release(platform_.context, endpoint);
    }
    bool connected() const { return endpoint_ != nullptr; }
    /* The mount table's virtual-size hook: the decoded capacity the connected
     * endpoint registered, for its identity only. */
    bool virtualSize(uint64_t identity, uint64_t *size) const {
        if (!endpoint_ || !size || !identity || identity != identity_) return false;
        *size = virtualSize_;
        return true;
    }
    size_t pendingCount() const { return pending_.pendingCount(); }

private:
    Platform platform_;
    Pending pending_;
    void *endpoint_ = nullptr;
    uint64_t identity_ = 0;
    uint64_t virtualSize_ = 0;

    DJDispatchResult connect(const DJDispatchArguments &arguments) {
        if (arguments.scalarInput[0] != kDJReadProtocolVersion || !arguments.scalarInput[1] ||
            !arguments.scalarInput[2]) return DJDispatchResult::BadArgument;
        if (endpoint_) return DJDispatchResult::Busy;
        if (!platform_.now || !platform_.arm || !platform_.cancel || !platform_.deliver ||
            !platform_.release) return DJDispatchResult::NotReady;
        endpoint_ = arguments.completion;
        if (pending_.connect()) {
            identity_ = arguments.scalarInput[1];
            virtualSize_ = arguments.scalarInput[2];
            return DJDispatchResult::Success;
        }
        endpoint_ = nullptr;
        return DJDispatchResult::NotReady;
    }
    static DJUserClientDispatch &self(void *context) {
        return *static_cast<DJUserClientDispatch *>(context);
    }
    static uint64_t now(void *context) {
        auto &d = self(context);
        return d.platform_.now(d.platform_.context);
    }
    static bool send(void *context, const DJReadRequest &request) {
        auto &d = self(context);
        return d.endpoint_ && d.platform_.deliver(d.platform_.context, d.endpoint_, request);
    }
    static bool arm(void *context, uint64_t deadline, void (*fire)(void *), void *argument) {
        auto &d = self(context);
        return d.platform_.arm(d.platform_.context, deadline, fire, argument);
    }
    static void cancel(void *context) {
        auto &d = self(context); // Teardown can run before any valid connect.
        if (d.platform_.cancel) d.platform_.cancel(d.platform_.context);
    }
};
