#include "DJAgentMediaMatch.hpp"
#include <cassert>
#include <cstring>

namespace {
// A fake registry entry: the identity its ancestry carries, if any.
struct Media {
    bool hasIdentity;
    uint64_t identity;
    unsigned searches = 0;
};

bool ancestry(void *media, uint64_t *identity) {
    auto &m = *static_cast<Media *>(media);
    ++m.searches;
    if (!m.hasIdentity) return false;
    *identity = m.identity;
    return true;
}

DJAgentMediaEvent event(const char *bsdName, bool whole, Media &media) {
    return {bsdName, whole, &media, ancestry};
}

bool matches(uint64_t owned, const DJAgentMediaEvent &e, char (&device)[32], size_t &size) {
    std::memset(device, 'x', sizeof(device));
    size = 99;
    return DJAgentOwnedMediaDevice(owned, &e, device, &size);
}

void expectNone(uint64_t owned, const DJAgentMediaEvent &e) {
    char device[32];
    size_t size;
    assert(!matches(owned, e, device, size));
    assert(size == 99 && device[0] == 'x'); // Untouched on refusal.
}
} // namespace

int main() {
    char device[32];
    size_t size;

    // The owned identity on whole media yields exactly its /dev/diskN.
    Media owned{true, 7};
    assert(matches(7, event("disk42", true, owned), device, size));
    assert(std::strcmp(device, "/dev/disk42") == 0 && size == sizeof("/dev/disk42"));
    assert(owned.searches == 1);
    Media single{true, 7};
    assert(matches(7, event("disk0", true, single), device, size));
    assert(std::strcmp(device, "/dev/disk0") == 0 && size == sizeof("/dev/disk0"));

    // The same disk number, reused by media with another identity, is not ours.
    Media reused{true, 8};
    expectNone(7, event("disk42", true, reused));

    // No identity on the ancestry: an unrelated disk, whatever its name.
    Media unrelated{false, 0};
    expectNone(7, event("disk42", true, unrelated));

    // Identity zero is never an attachment, even when both sides say zero.
    Media zero{true, 0};
    expectNone(0, event("disk42", true, zero));
    expectNone(7, event("disk42", true, zero));

    // Partitions of the owned disk are not the attachment's device.
    Media partition{true, 7};
    expectNone(7, event("disk42s1", false, partition));
    expectNone(7, event("disk42", false, partition));
    assert(partition.searches == 0); // Rejected before the registry is read.

    // Malformed BSD names never reach the lifecycle, whatever the ancestry says.
    const char *malformed[] = {"", "disk", "disk42s1", "rdisk42", "disk-1", "disk4 2",
        "disk042", "../disk42", "/dev/disk42", "disk12345678901234567890123"};
    for (const char *name : malformed) {
        Media m{true, 7};
        expectNone(7, event(name, true, m));
    }
    Media nameless{true, 7};
    expectNone(7, event(nullptr, true, nameless));

    // A missing ancestry search cannot be skipped to trust the name.
    DJAgentMediaEvent blind{"disk42", true, &owned, nullptr};
    expectNone(7, blind);
    expectNone(7, DJAgentMediaEvent{"disk42", true, nullptr, ancestry});

    // Null event or outputs are refused.
    assert(!DJAgentOwnedMediaDevice(7, nullptr, device, &size));
    DJAgentMediaEvent ok = event("disk42", true, owned);
    assert(!DJAgentOwnedMediaDevice(7, &ok, nullptr, &size));
    assert(!DJAgentOwnedMediaDevice(7, &ok, device, nullptr));
    return 0;
}
