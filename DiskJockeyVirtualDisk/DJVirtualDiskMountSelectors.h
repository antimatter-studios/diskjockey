/* Portable core of the DJVirtualDisk user client's mount, unmount and list
 * selectors. It owns the bounded table of kDJMaxVirtualDisks live media; the
 * read backend and the block-device child stay behind injected hooks. Every
 * count and size is checked against one table before any byte is copied, and
 * a refused call never consults the backend or touches a slot. All calls and
 * hooks run on one serial queue. */
#pragma once
#include "DJVirtualDiskShared.h"

enum class DJMountResult { Success, BadArgument, Unsupported, NotReady, Busy, NoSpace, NotFound, Failed };

/* Untrusted caller arguments. scalarOutputCount and structureOutputMaximumSize
 * are the caller's capacities; list writes the bytes it used to
 * structureOutputSize. completion is the async action; no method takes one. */
struct DJMountArguments {
    const uint64_t *scalarInput;
    uint32_t scalarInputCount;
    const void *structureInput;
    size_t structureInputSize;
    uint64_t *scalarOutput;
    uint32_t scalarOutputCount;
    void *structureOutput;
    size_t structureOutputMaximumSize;
    size_t *structureOutputSize;
    void *completion;
};

/* Exact scalar counts and structure input size, and the least structure
 * output capacity (zero: no structure output). */
struct DJMountMethod {
    uint64_t selector;
    uint32_t scalarInputCount;
    size_t structureInputSize;
    uint32_t scalarOutputCount;
    size_t structureOutputMinimumSize;
};

static constexpr DJMountMethod kDJMountMethods[] = {
    /* The attachment identity and one request in; the identity out as the device ID. */
    {kDJSelectorMountImage, 1, sizeof(DJMountRequest), 1, 0},
    /* The identity in; no output. */
    {kDJSelectorUnmountImage, 1, 0, 0, 0},
    /* Room for every slot's DJMountInfo out; the used size is reported. */
    {kDJSelectorListMounts, 0, 0, 0, sizeof(DJMountInfo) * kDJMaxVirtualDisks},
};

static inline bool DJMountArgumentsMatch(const DJMountMethod &method,
                                         const DJMountArguments &arguments) {
    if (arguments.scalarInputCount != method.scalarInputCount ||
        (method.scalarInputCount && !arguments.scalarInput)) return false;
    if (arguments.structureInputSize != method.structureInputSize ||
        (method.structureInputSize && !arguments.structureInput)) return false;
    if (arguments.scalarOutputCount != method.scalarOutputCount ||
        (method.scalarOutputCount && !arguments.scalarOutput)) return false;
    if (method.structureOutputMinimumSize
            ? arguments.structureOutputMaximumSize < method.structureOutputMinimumSize ||
                  !arguments.structureOutput || !arguments.structureOutputSize
            : arguments.structureOutputMaximumSize != 0) return false;
    return arguments.completion == nullptr;
}

struct DJMountPlatform {
    void *context;
    /* The decoded virtual size the read backend serves for an identity; never
     * a container's file length. A null hook (no backend installed yet) or
     * false (the backend does not serve the identity) refuses every mount. */
    bool (*virtualSize)(void *, uint64_t identity, uint64_t *size);
    /* Create and register the read-only child for a reserved slot. False
     * means nothing is published. */
    bool (*publish)(void *, uint64_t identity, const DJMountGeometry &);
    /* Terminate the identity's child. False means it is still published. */
    bool (*remove)(void *, uint64_t identity);
};

class DJMountTable {
public:
    explicit DJMountTable(DJMountPlatform platform) : platform_(platform) {}
    DJMountTable(const DJMountTable &) = delete;
    DJMountTable &operator=(const DJMountTable &) = delete;

    DJMountResult externalMethod(uint64_t selector, const DJMountArguments &arguments) {
        const DJMountMethod *method = nullptr;
        for (const auto &entry : kDJMountMethods)
            if (entry.selector == selector) method = &entry;
        if (!method) return DJMountResult::Unsupported;
        if (!DJMountArgumentsMatch(*method, arguments)) return DJMountResult::BadArgument;
        switch (selector) {
        case kDJSelectorMountImage: return mount(arguments);
        case kDJSelectorUnmountImage: return unmount(arguments.scalarInput[0]);
        default: return list(arguments);
        }
    }
    size_t liveCount() const {
        size_t count = 0;
        for (const auto &slot : slots_) count += slot.state == State::Live;
        return count;
    }

private:
    /* A slot is held from reservation, before publication, until removal
     * succeeds, so a request arriving meanwhile can neither take it nor reuse
     * its identity. */
    enum class State { Free, Publishing, Live, Removing };
    struct Slot {
        State state = State::Free;
        uint64_t identity = 0;
        DJMountGeometry geometry{};
        char path[sizeof(DJMountRequest::path)] = {};
    };
    DJMountPlatform platform_;
    Slot slots_[kDJMaxVirtualDisks];

    Slot *find(uint64_t identity) {
        for (auto &slot : slots_)
            if (slot.state != State::Free && slot.identity == identity) return &slot;
        return nullptr;
    }

    DJMountResult mount(const DJMountArguments &arguments) {
        const uint64_t identity = arguments.scalarInput[0];
        if (!identity) return DJMountResult::BadArgument;
        if (!platform_.virtualSize || !platform_.publish || !platform_.remove)
            return DJMountResult::NotReady;
        uint64_t virtualSize = 0;
        if (!platform_.virtualSize(platform_.context, identity, &virtualSize))
            return DJMountResult::NotReady;
        const auto *request = static_cast<const DJMountRequest *>(arguments.structureInput);
        DJMountGeometry geometry;
        if (!DJMountRequestGetGeometry(request, arguments.structureInputSize, virtualSize, &geometry))
            return DJMountResult::BadArgument;
        if (find(identity)) return DJMountResult::Busy;
        Slot *slot = nullptr;
        for (auto &candidate : slots_)
            if (candidate.state == State::Free) { slot = &candidate; break; }
        if (!slot) return DJMountResult::NoSpace;

        slot->state = State::Publishing;
        slot->identity = identity;
        slot->geometry = geometry;
        memcpy(slot->path, request->path, sizeof(slot->path));
        if (!platform_.publish(platform_.context, identity, geometry)) {
            *slot = Slot();
            return DJMountResult::Failed;
        }
        slot->state = State::Live;
        arguments.scalarOutput[0] = identity;
        return DJMountResult::Success;
    }

    DJMountResult unmount(uint64_t identity) {
        if (!identity) return DJMountResult::BadArgument;
        Slot *slot = find(identity);
        if (!slot) return DJMountResult::NotFound;
        if (slot->state != State::Live) return DJMountResult::Busy;
        slot->state = State::Removing;
        if (!platform_.remove(platform_.context, identity)) {
            slot->state = State::Live;
            return DJMountResult::Failed;
        }
        *slot = Slot();
        return DJMountResult::Success;
    }

    DJMountResult list(const DJMountArguments &arguments) {
        auto *infos = static_cast<DJMountInfo *>(arguments.structureOutput);
        size_t count = 0;
        for (const auto &slot : slots_) {
            if (slot.state != State::Live) continue;
            DJMountInfo &info = infos[count++];
            memset(&info, 0, sizeof(info));
            info.deviceID = slot.identity;
            memcpy(info.path, slot.path, sizeof(info.path));
        }
        *arguments.structureOutputSize = count * sizeof(DJMountInfo);
        return DJMountResult::Success;
    }
};
