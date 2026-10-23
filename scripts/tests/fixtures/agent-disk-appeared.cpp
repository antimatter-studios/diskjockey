// The agent's disk-appeared handling over a fake DiskArbitration and IOKit
// registry (#507): a disk reaches an attachment's appeared only through
// DJAgentOwnedMediaDevice, by the identity its media's ancestry carries and
// never by its BSD name alone, and every object the callback or the
// registry search copies is released exactly once.
#include "DJAgentConnectionRegistry.hpp"
#include "DJAgentDiskAppeared.hpp"
#include "DJAgentMediaIdentity.hpp"
#include <cassert>
#include <cstring>
#include <string>

static bool onQueue = false;
static void checkQueue() { assert(onQueue); }

// One attachment, as agent-connection-owners.cpp drives it.
struct World {
    uint64_t identity = 0;
    unsigned replies = 0;
    std::string device;
    DJAttachmentResult result = DJAttachmentResult::Detached;
    DJAgentBridgePlatform platform() {
        return {this,
            [](void *, const char *, int) { checkQueue(); return true; },
            [](void *) -> uint32_t { checkQueue(); return 1; },
            [](void *, uint32_t) { checkQueue(); },
            [](void *p, uint32_t, const DJMountRequest *, int, uint64_t id) -> void * {
                checkQueue(); static_cast<World *>(p)->identity = id; return p;
            },
            [](void *, void *) { checkQueue(); },
            [](void *p, void *, uint64_t selector, const uint64_t *input, uint32_t,
               const void *, size_t, uint64_t *output, uint32_t *) -> int32_t {
                checkQueue(); assert(input[0] == static_cast<World *>(p)->identity);
                if (selector == kDJSelectorMountImage) output[0] = input[0];
                return 0;
            }};
    }
    DJAgentAttachment::Hooks hooks() {
        return {this,
            [](void *) -> uint64_t { checkQueue(); return 100; },
            [](void *, uint64_t, void (*)(void *), void *) { checkQueue(); return true; },
            [](void *) { checkQueue(); }, nullptr,
            [](void *, uint64_t, uint64_t, const char *) { checkQueue(); return true; },
            nullptr, nullptr};
    }
    static void completed(void *p, DJAttachmentResult result, const char *device) {
        checkQueue(); auto &w = *static_cast<World *>(p);
        ++w.replies; w.result = result; w.device = device ? device : "";
    }
};

// The IOMedia a disk reports, and what its service-plane ancestry carries.
struct Media {
    uint64_t identity = 0;   // 0: no ancestor carries kDJAttachmentIdentityKey.
    unsigned searches = 0, copies = 0, releases = 0;
};
// The copied property a search returns: a number holding the identity.
struct Property { Media *media; };

static const void *search(void *media, const char *plane, const char *key, uint32_t options) {
    auto *m = static_cast<Media *>(media);
    assert(std::strcmp(plane, "IOService") == 0);
    assert(std::strcmp(key, kDJAttachmentIdentityKey) == 0);
    assert(options == (DJAgentRegistryIterateRecursively | DJAgentRegistryIterateParents));
    ++m->searches;
    if (!m->identity) return nullptr;
    ++m->copies;
    return new Property{m};
}
static bool number(const void *object, uint64_t *value) {
    *value = static_cast<const Property *>(object)->media->identity;
    return true;
}
static void release(const void *object) {
    auto *p = static_cast<const Property *>(object);
    ++p->media->releases;
    delete p;
}
static const DJAgentRegistry registry{search, number, release};
static bool identity(void *media, uint64_t *value) {
    return DJAgentMediaIdentity(&registry, media, value);
}

// What DiskArbitration reports for one disk, and what the callback copied.
struct Disk {
    const char *bsdName;
    bool whole;
    Media *media;          // Null: DADiskCopyIOMedia returns nothing.
    bool hasDescription;
    unsigned descriptionCopies = 0, descriptionReleases = 0;
    unsigned mediaCopies = 0, mediaReleases = 0;
};
// The disk being delivered, so a released IOMedia is counted against it.
static Disk *current = nullptr;
static const DJAgentDiskArbitration diskArbitration{
    [](void *disk) -> const void * {
        auto *d = static_cast<Disk *>(disk);
        if (!d->hasDescription) return nullptr;
        ++d->descriptionCopies;
        return d;
    },
    [](void *disk) -> void * {
        auto *d = static_cast<Disk *>(disk);
        if (!d->media) return nullptr;
        ++d->mediaCopies;
        return d->media;
    },
    [](void *disk) { return static_cast<Disk *>(disk)->bsdName; },
    [](const void *description) { return static_cast<const Disk *>(description)->whole; },
    [](const void *description) {
        ++const_cast<Disk *>(static_cast<const Disk *>(description))->descriptionReleases;
    },
    [](void *media) {
        assert(current && media == current->media);
        ++current->mediaReleases;
    }};

static void appear(DJAgentConnectionRegistry &connections, Disk &disk) {
    current = &disk;
    DJAgentDiskAppeared(diskArbitration, &disk, identity,
        [&](const DJAgentMediaEvent &event) { connections.appeared(event); });
    current = nullptr;
    // Whatever the callback or a search copied is released once, and only that.
    assert(disk.descriptionReleases == disk.descriptionCopies);
    assert(disk.mediaReleases == disk.mediaCopies);
    if (disk.media) assert(disk.media->releases == disk.media->copies);
}

int main() {
    onQueue = true;
    DJAgentConnectionRegistry connections(checkQueue);
    const uint64_t owner = connections.connect();
    DJMountRequest mount = {}; std::strcpy(mount.path, "/image.vhdx");
    World first, second;
    const uint64_t one = connections.attach(
        owner, mount, 11, 1000, first.platform(), first.hooks(), World::completed, &first);
    const uint64_t two = connections.attach(
        owner, mount, 11, 1000, second.platform(), second.hooks(), World::completed, &second);
    assert(one && two && one != two);
    assert(first.identity && second.identity && first.identity != second.identity);

    // Whole media whose ancestry carries the first attachment's identity:
    // that attachment, and no other, sees /dev/disk7 appear. Each live
    // attachment asks the matcher, so the ancestry is searched once for each.
    Media owned{first.identity};
    Disk disk7{"disk7", true, &owned, true};
    appear(connections, disk7);
    assert(first.replies == 1 && first.result == DJAttachmentResult::Attached);
    assert(first.device == "/dev/disk7");
    assert(second.replies == 0);
    assert(disk7.descriptionCopies == 1 && disk7.mediaCopies == 1);
    assert(owned.searches == 2 && owned.copies == 2);

    // The same BSD name with no identity on its ancestry is nobody's disk.
    Media stranger{0};
    Disk again{"disk7", true, &stranger, true};
    appear(connections, again);
    assert(second.replies == 0 && stranger.searches == 2 && stranger.copies == 0);

    // A partition of the second attachment's disk is not the attachment, and
    // costs no registry search.
    Media partition{second.identity};
    Disk slice{"disk8s1", false, &partition, true};
    appear(connections, slice);
    assert(second.replies == 0 && partition.searches == 0);

    // A disk whose IOMedia or description cannot be copied is delivered
    // nowhere, and what was copied is still released.
    Media unreported{second.identity};
    Disk noMedia{"disk8", true, nullptr, true};
    appear(connections, noMedia);
    assert(noMedia.descriptionCopies == 1 && noMedia.mediaCopies == 0);
    Disk noDescription{"disk8", true, &unreported, false};
    appear(connections, noDescription);
    assert(noDescription.descriptionCopies == 0 && noDescription.mediaCopies == 1);
    assert(unreported.searches == 0 && second.replies == 0);

    // The second attachment's own whole disk reaches it.
    Media secondMedia{second.identity};
    Disk disk8{"disk8", true, &secondMedia, true};
    appear(connections, disk8);
    assert(second.replies == 1 && second.device == "/dev/disk8");
    assert(first.replies == 1);
    return 0;
}
