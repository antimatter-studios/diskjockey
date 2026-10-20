#include "DJAgentMediaIdentity.hpp"
#include "DJAgentMediaMatch.hpp"
#include <cassert>
#include <cstring>

namespace {
// A fake registry object: a number or some other property type.
struct Value {
    bool number;
    uint64_t value;
    int references = 0;
};

// A fake registry entry: the property its ancestry carries, if any.
struct Media {
    Value *property;
};

struct Calls {
    unsigned searches = 0, numbers = 0, releases = 0;
    const char *plane = nullptr, *key = nullptr;
    uint32_t options = 0;
} calls;

const void *search(void *media, const char *plane, const char *key, uint32_t options) {
    ++calls.searches;
    calls.plane = plane;
    calls.key = key;
    calls.options = options;
    Value *property = static_cast<Media *>(media)->property;
    if (property) ++property->references; // The search returns a copy.
    return property;
}

bool number(const void *object, uint64_t *value) {
    ++calls.numbers;
    const auto *property = static_cast<const Value *>(object);
    assert(property->references > 0); // Read before release, never after.
    if (!property->number) return false;
    *value = property->value;
    return true;
}

void release(const void *object) {
    ++calls.releases;
    assert(object);
    auto *property = const_cast<Value *>(static_cast<const Value *>(object));
    assert(property->references > 0);
    --property->references;
}

const DJAgentRegistry registry{search, number, release};

bool found(Media &media, uint64_t &identity) {
    calls = Calls{};
    identity = 99;
    return DJAgentMediaIdentity(&registry, &media, &identity);
}

void expectNone(Media &media, unsigned releases) {
    uint64_t identity;
    assert(!found(media, identity));
    assert(identity == 99); // Untouched on refusal.
    assert(calls.releases == releases);
    if (media.property) assert(media.property->references == 0);
}

// DJAgentMediaEvent::identity carries no context, so the bridge binds one
// registry; the fake binds the test's.
bool ancestry(void *media, uint64_t *identity) {
    return DJAgentMediaIdentity(&registry, media, identity);
}
} // namespace

int main() {
    uint64_t identity;

    // A non-zero number on the ancestry is the identity, and its copy goes.
    Value owned{true, 7};
    Media media{&owned};
    assert(found(media, identity));
    assert(identity == 7);
    assert(calls.searches == 1 && calls.numbers == 1 && calls.releases == 1);
    assert(owned.references == 0);
    // The key the dext publishes, searched from the media through its parents.
    assert(calls.plane && std::strcmp(calls.plane, "IOService") == 0);
    assert(calls.key && std::strcmp(calls.key, kDJAttachmentIdentityKey) == 0);
    assert(calls.options == (DJAgentRegistryIterateRecursively | DJAgentRegistryIterateParents));
    assert(DJAgentRegistryIterateRecursively == 0x1 && DJAgentRegistryIterateParents == 0x2);

    // No property anywhere on the ancestry: nothing was copied, nothing goes.
    Media unrelated{nullptr};
    expectNone(unrelated, 0);
    assert(calls.searches == 1 && calls.numbers == 0);

    // A property of another type is not an identity, and is still released.
    Value text{false, 7};
    Media other{&text};
    expectNone(other, 1);

    // Zero is never an attachment identity, and is still released.
    Value zero{true, 0};
    Media unset{&zero};
    expectNone(unset, 1);

    // Null media is never searched.
    calls = Calls{};
    identity = 99;
    assert(!DJAgentMediaIdentity(&registry, nullptr, &identity));
    assert(identity == 99 && calls.searches == 0);

    // No registry, no output, or an incomplete registry searches nothing:
    // a registry that cannot release would leak what it copies.
    assert(!DJAgentMediaIdentity(nullptr, &media, &identity));
    assert(!DJAgentMediaIdentity(&registry, &media, nullptr));
    const DJAgentRegistry noRelease{search, number, nullptr};
    const DJAgentRegistry noNumber{search, nullptr, release};
    const DJAgentRegistry noSearch{nullptr, number, release};
    assert(!DJAgentMediaIdentity(&noRelease, &media, &identity));
    assert(!DJAgentMediaIdentity(&noNumber, &media, &identity));
    assert(!DJAgentMediaIdentity(&noSearch, &media, &identity));
    assert(calls.searches == 0 && owned.references == 0);

    // Through the matcher: the owned identity on the ancestry yields its
    // device, and another identity, another type or no property does not.
    char device[32];
    size_t size = 0;
    const DJAgentMediaEvent ours{"disk5", true, &media, ancestry};
    const DJAgentMediaEvent typed{"disk5", true, &other, ancestry};
    const DJAgentMediaEvent bare{"disk5", true, &unrelated, ancestry};
    assert(DJAgentOwnedMediaDevice(7, &ours, device, &size));
    assert(std::strcmp(device, "/dev/disk5") == 0 && size == sizeof("/dev/disk5"));
    assert(!DJAgentOwnedMediaDevice(8, &ours, device, &size));
    assert(!DJAgentOwnedMediaDevice(7, &typed, device, &size));
    assert(!DJAgentOwnedMediaDevice(7, &bare, device, &size));
    assert(owned.references == 0 && text.references == 0);
    return 0;
}
