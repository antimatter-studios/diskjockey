/* Host-only registry search behind DJAgentMediaEvent::identity (#506, part
 * of #457). Never include in the dext. The dext child publishes
 * kDJAttachmentIdentityKey as a 64-bit number; DiskArbitration reports the
 * IOMedia below it, so the search starts at the media and walks its parents.
 *
 * The registry stays injected so the guard runs without IOKit; #507 binds it
 * to IORegistryEntrySearchCFProperty, CFNumberGetValue and CFRelease.
 */
#pragma once
#include <stddef.h>
#include <stdint.h>

/* kDJAttachmentIdentityKey, shared with the dext child that publishes it. */
#include "../DiskJockeyVirtualDisk/DJVirtualDiskShared.h"

/* kIORegistryIterateRecursively and kIORegistryIterateParents, spelled out
 * so this header needs no IOKit; the binding checks they agree. */
static const uint32_t DJAgentRegistryIterateRecursively = 0x1;
static const uint32_t DJAgentRegistryIterateParents = 0x2;

struct DJAgentRegistry {
    /* IORegistryEntrySearchCFProperty(media, plane, key, kCFAllocatorDefault,
     * options): a copied object the caller releases, or null. */
    const void *(*search)(void *media, const char *plane, const char *key, uint32_t options);
    /* The value of a 64-bit number; false for any other type. Copies nothing. */
    bool (*number)(const void *object, uint64_t *value);
    void (*release)(const void *object);
};

/* True only when the media or one of its service-plane parents carries a
 * non-zero 64-bit identity; then *identity holds it. False leaves *identity
 * unchanged. Whatever the search copies is released exactly once, before
 * returning, on every path. An incomplete registry searches nothing, since
 * it could not release what it copied. */
static inline bool DJAgentMediaIdentity(
    const DJAgentRegistry *registry, void *media, uint64_t *identity)
{
    if (!registry || !registry->search || !registry->number || !registry->release ||
        !media || !identity) return false;
    const void *object = registry->search(
        media, "IOService", kDJAttachmentIdentityKey,
        DJAgentRegistryIterateRecursively | DJAgentRegistryIterateParents);
    if (!object) return false;
    uint64_t value = 0;
    const bool found = registry->number(object, &value) && value;
    registry->release(object);
    if (found) *identity = value;
    return found;
}
