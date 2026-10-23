/* Host-only DiskArbitration disk-appeared handling (#507, part of #457).
 * Never include in the dext. DJAgentOwnedImages.mm binds the boundary to
 * DADiskCopyDescription, DADiskCopyIOMedia, DADiskGetBSDName, CFRelease and
 * IOObjectRelease; the guard binds it to a fake, so the copy, match and
 * release order is proved without a Mac.
 *
 * The event carries the BSD name, the whole-media flag and the media's
 * registry entry; whoever it is delivered to (the connection registry)
 * decides ownership through DJAgentOwnedMediaDevice alone.
 */
#pragma once
#include "DJAgentMediaMatch.hpp"

struct DJAgentDiskArbitration {
    /* DADiskCopyDescription: a copied dictionary, or null. */
    const void *(*copyDescription)(void *disk);
    /* DADiskCopyIOMedia: a copied registry entry, or null. */
    void *(*copyMedia)(void *disk);
    /* DADiskGetBSDName: borrowed from the disk; null when it has none. */
    const char *(*bsdName)(void *disk);
    /* Whether the description's kDADiskDescriptionMediaWholeKey is true. */
    bool (*whole)(const void *description);
    void (*releaseDescription)(const void *description); /* CFRelease */
    void (*releaseMedia)(void *media);                    /* IOObjectRelease */
};

/* One disk-appeared callback: the event is built from the disk's
 * description and IOMedia and handed to deliver only when both were copied.
 * Whatever was copied is released exactly once, after delivery, on every
 * path, so the registry entry lives exactly as long as the matcher reads
 * it. */
template <class Deliver>
inline void DJAgentDiskAppeared(const DJAgentDiskArbitration &da, void *disk,
    bool (*identity)(void *media, uint64_t *identity), Deliver &&deliver)
{
    const void *description = da.copyDescription(disk);
    void *media = da.copyMedia(disk);
    if (description && media) {
        const DJAgentMediaEvent event{da.bsdName(disk), da.whole(description), media, identity};
        deliver(event);
    }
    if (media) da.releaseMedia(media);
    if (description) da.releaseDescription(description);
}
