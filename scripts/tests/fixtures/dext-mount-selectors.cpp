#include "DJVirtualDiskMountSelectors.h"
#include <cassert>
#include <cstring>

namespace {
constexpr uint64_t kVirtualSize = 1 << 20;

// A fake read backend and child publisher, recording every boundary call.
struct Fake {
    bool backend = true;
    bool publishOK = true;
    bool removeOK = true;
    unsigned sizes = 0, publishes = 0, removes = 0;
    uint64_t lastPublished = 0;
    DJMountGeometry lastGeometry{};
    DJMountTable *table = nullptr;
    uint64_t nested = 0; // Identity mounted from inside publish, when non-zero.
    DJMountResult nestedResult = DJMountResult::Success;
};

DJMountResult mount(DJMountTable &table, uint64_t identity, const DJMountRequest &request,
                    uint64_t *out = nullptr);

bool size(void *context, uint64_t, uint64_t *virtualSize) {
    auto &f = *static_cast<Fake *>(context);
    ++f.sizes;
    if (!f.backend) return false;
    *virtualSize = kVirtualSize;
    return true;
}

bool publish(void *context, uint64_t identity, const DJMountGeometry &geometry) {
    auto &f = *static_cast<Fake *>(context);
    ++f.publishes;
    f.lastPublished = identity;
    f.lastGeometry = geometry;
    if (f.nested) {
        DJMountRequest request{};
        std::strcpy(request.path, "/nested.qcow2");
        const uint64_t nested = f.nested;
        f.nested = 0;
        f.nestedResult = mount(*f.table, nested, request);
    }
    return f.publishOK;
}

bool remove(void *context, uint64_t) {
    auto &f = *static_cast<Fake *>(context);
    ++f.removes;
    return f.removeOK;
}

DJMountPlatform platform(Fake &f) { return {&f, size, publish, remove}; }

DJMountRequest request(const char *path, uint64_t offset = 0, uint64_t length = 0) {
    DJMountRequest r{};
    std::strcpy(r.path, path);
    r.partOffset = offset;
    r.partLength = length;
    return r;
}

DJMountResult mount(DJMountTable &table, uint64_t identity, const DJMountRequest &request,
                    uint64_t *out) {
    uint64_t scalar = identity, output = 0;
    DJMountArguments a{};
    a.scalarInput = &scalar;
    a.scalarInputCount = 1;
    a.structureInput = &request;
    a.structureInputSize = sizeof(request);
    a.scalarOutput = &output;
    a.scalarOutputCount = 1;
    const DJMountResult result = table.externalMethod(kDJSelectorMountImage, a);
    if (out) *out = output;
    return result;
}

DJMountResult unmount(DJMountTable &table, uint64_t identity) {
    uint64_t scalar = identity;
    DJMountArguments a{};
    a.scalarInput = &scalar;
    a.scalarInputCount = 1;
    return table.externalMethod(kDJSelectorUnmountImage, a);
}

size_t list(DJMountTable &table, DJMountInfo (&infos)[kDJMaxVirtualDisks]) {
    size_t written = 99;
    DJMountArguments a{};
    a.structureOutput = infos;
    a.structureOutputMaximumSize = sizeof(infos);
    a.structureOutputSize = &written;
    assert(table.externalMethod(kDJSelectorListMounts, a) == DJMountResult::Success);
    assert(written % sizeof(DJMountInfo) == 0);
    return written / sizeof(DJMountInfo);
}

void badArguments() {
    Fake f;
    DJMountTable table(platform(f));
    const DJMountRequest r = request("/image.qcow2");
    uint64_t scalars[2] = {7, 7}, output = 0;
    auto base = [&] {
        DJMountArguments a{};
        a.scalarInput = scalars;
        a.scalarInputCount = 1;
        a.structureInput = &r;
        a.structureInputSize = sizeof(r);
        a.scalarOutput = &output;
        a.scalarOutputCount = 1;
        return a;
    };
    DJMountArguments a = base();
    a.scalarInputCount = 0;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.scalarInputCount = 2;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.scalarInput = nullptr;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.structureInputSize = sizeof(r) - 1;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.structureInput = nullptr;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.scalarOutputCount = 0; // No room for the device ID.
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    a.scalarOutput = nullptr;
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    int completion;
    a.completion = &completion; // Mount is synchronous.
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    a = base();
    scalars[0] = 0; // Identity zero is never an attachment.
    assert(table.externalMethod(kDJSelectorMountImage, a) == DJMountResult::BadArgument);
    scalars[0] = 7;

    // Unmount takes exactly one scalar; list needs room for every slot.
    DJMountArguments u{};
    assert(table.externalMethod(kDJSelectorUnmountImage, u) == DJMountResult::BadArgument);
    DJMountInfo infos[kDJMaxVirtualDisks];
    size_t written = 99;
    DJMountArguments l{};
    l.structureOutput = infos;
    l.structureOutputMaximumSize = sizeof(infos) - 1;
    l.structureOutputSize = &written;
    assert(table.externalMethod(kDJSelectorListMounts, l) == DJMountResult::BadArgument);
    assert(written == 99);
    l.structureOutputMaximumSize = sizeof(infos);
    l.structureOutputSize = nullptr;
    assert(table.externalMethod(kDJSelectorListMounts, l) == DJMountResult::BadArgument);

    // The read transport's selectors and unknown ones are not this table's.
    assert(table.externalMethod(3, base()) == DJMountResult::Unsupported);
    assert(table.externalMethod(99, base()) == DJMountResult::Unsupported);

    // No refusal consulted the backend, published, or reserved a slot.
    assert(f.sizes == 0 && f.publishes == 0 && table.liveCount() == 0 && output == 0);
}

void missingBackend() {
    Fake f;
    DJMountTable noHook({&f, nullptr, publish, remove});
    uint64_t out = 0;
    assert(mount(noHook, 7, request("/image.qcow2"), &out) == DJMountResult::NotReady);
    assert(f.publishes == 0 && noHook.liveCount() == 0 && out == 0);

    f.backend = false; // The backend does not know this identity yet.
    DJMountTable table(platform(f));
    assert(mount(table, 7, request("/image.qcow2"), &out) == DJMountResult::NotReady);
    assert(f.sizes == 1 && f.publishes == 0 && table.liveCount() == 0 && out == 0);
}

void geometry() {
    Fake f;
    DJMountTable table(platform(f));
    // A partition past the decoded virtual size is refused before publication.
    assert(mount(table, 7, request("/image.qcow2", kVirtualSize, 512)) == DJMountResult::BadArgument);
    assert(mount(table, 7, request("relative.qcow2")) == DJMountResult::BadArgument);
    assert(f.publishes == 0 && table.liveCount() == 0);

    uint64_t out = 0;
    assert(mount(table, 7, request("/image.qcow2", 4096, 8192), &out) == DJMountResult::Success);
    assert(out == 7 && f.lastPublished == 7);
    assert(f.lastGeometry.byteOffset == 4096 && f.lastGeometry.byteLength == 8192 &&
           f.lastGeometry.blockSize == 512);
}

void capacity() {
    Fake f;
    DJMountTable table(platform(f));
    for (uint64_t id = 1; id <= kDJMaxVirtualDisks; ++id)
        assert(mount(table, id, request("/image.qcow2")) == DJMountResult::Success);
    assert(table.liveCount() == kDJMaxVirtualDisks);
    assert(mount(table, 100, request("/image.qcow2")) == DJMountResult::NoSpace);
    assert(f.publishes == kDJMaxVirtualDisks);

    // A live identity cannot be mounted twice, even after a slot frees.
    assert(unmount(table, 1) == DJMountResult::Success);
    assert(mount(table, 2, request("/image.qcow2")) == DJMountResult::Busy);
    assert(mount(table, 100, request("/image.qcow2")) == DJMountResult::Success);
    assert(table.liveCount() == kDJMaxVirtualDisks);
}

void reservation() {
    Fake f;
    DJMountTable table(platform(f));
    f.table = &table;
    for (uint64_t id = 1; id < kDJMaxVirtualDisks; ++id)
        assert(mount(table, id, request("/image.qcow2")) == DJMountResult::Success);
    // The last slot is reserved before publication, so a request arriving
    // while it publishes cannot take it, nor reuse the publishing identity.
    f.nested = 200;
    assert(mount(table, 100, request("/image.qcow2")) == DJMountResult::Success);
    assert(f.nestedResult == DJMountResult::NoSpace);
    assert(table.liveCount() == kDJMaxVirtualDisks);
}

void publicationFailure() {
    Fake f;
    DJMountTable table(platform(f));
    f.publishOK = false;
    uint64_t out = 0;
    assert(mount(table, 7, request("/image.qcow2"), &out) == DJMountResult::Failed);
    assert(out == 0 && table.liveCount() == 0);
    DJMountInfo infos[kDJMaxVirtualDisks];
    assert(list(table, infos) == 0);
    // The released slot and identity are usable again.
    f.publishOK = true;
    assert(mount(table, 7, request("/image.qcow2"), &out) == DJMountResult::Success && out == 7);
}

void unmountLifecycle() {
    Fake f;
    DJMountTable table(platform(f));
    assert(unmount(table, 7) == DJMountResult::NotFound);
    assert(unmount(table, 0) == DJMountResult::BadArgument);
    assert(mount(table, 7, request("/a.qcow2")) == DJMountResult::Success);
    assert(mount(table, 9, request("/b.vhdx")) == DJMountResult::Success);

    DJMountInfo infos[kDJMaxVirtualDisks];
    assert(list(table, infos) == 2);
    assert(infos[0].deviceID == 7 && std::strcmp(infos[0].path, "/a.qcow2") == 0);
    assert(infos[1].deviceID == 9 && std::strcmp(infos[1].path, "/b.vhdx") == 0);

    // A failed removal keeps the child published and its slot held.
    f.removeOK = false;
    assert(unmount(table, 7) == DJMountResult::Failed);
    assert(table.liveCount() == 2 && f.removes == 1);
    f.removeOK = true;
    assert(unmount(table, 7) == DJMountResult::Success);
    assert(table.liveCount() == 1 && f.removes == 2);
    assert(unmount(table, 7) == DJMountResult::NotFound && f.removes == 2);
    assert(list(table, infos) == 1 && infos[0].deviceID == 9);
}
} // namespace

int main() {
    badArguments();
    missingBackend();
    geometry();
    capacity();
    reservation();
    publicationFailure();
    unmountLifecycle();
    return 0;
}
