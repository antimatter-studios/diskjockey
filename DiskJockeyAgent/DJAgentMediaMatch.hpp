/* Host-only DiskArbitration correlation for one owned attachment (#451).
 * Never include in the dext. The bridge (#452) reads the BSD name and the
 * whole-media flag from the DiskArbitration description and borrows the
 * media's registry entry; the matcher alone decides whether that media is
 * the owned attachment's device, before DJAgentAttachment::appeared.
 *
 * Ownership comes only from the per-attachment identity on the IOMedia
 * ancestry. A BSD name, a path or a disk number is never proof: disk numbers
 * are reused as soon as a disk goes away.
 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* The registry property the child publication (#394) sets on the owned
 * IOMedia ancestry. The bridge searches the media and its parents for it. */
#define kDJAttachmentIdentityKey "DJAttachmentIdentity"

struct DJAgentMediaEvent {
    const char *bsdName; /* kDADiskDescriptionMediaBSDNameKey, e.g. "disk7". */
    bool whole;          /* kDADiskDescriptionMediaWholeKey. */
    void *media;         /* Borrowed registry entry, for the ancestry search. */
    /* Search media and its registry parents for kDJAttachmentIdentityKey.
     * False means no identity: the media is not an attachment. */
    bool (*identity)(void *media, uint64_t *identity);
};

/* True only when whole media named diskN carries the non-zero owned identity
 * on its ancestry. Then device holds "/dev/diskN" and *size counts exactly
 * one terminal NUL, as DJAgentAttachment::appeared expects. False leaves
 * device and *size unchanged. The name is checked before the registry is
 * read, so partitions and malformed names never cost a search. */
static inline bool DJAgentOwnedMediaDevice(
    uint64_t owned, const DJAgentMediaEvent *event, char device[32], size_t *size)
{
    static const char prefix[] = "/dev/";
    if (!owned || !event || !device || !size || !event->whole || !event->bsdName ||
        !event->media || !event->identity) return false;
    const char *name = event->bsdName;
    if (strncmp(name, "disk", 4) != 0) return false;
    const size_t length = strnlen(name, 32);
    const size_t digits = length - 4;
    /* "/dev/" + name + NUL must fit the lifecycle's 32-byte device. */
    if (digits == 0 || sizeof(prefix) + length > 32) return false;
    if (digits > 1 && name[4] == '0') return false; /* One spelling per disk. */
    for (size_t i = 4; i < length; ++i)
        if (name[i] < '0' || name[i] > '9') return false;
    uint64_t identity = 0;
    if (!event->identity(event->media, &identity) || identity != owned) return false;
    memcpy(device, prefix, sizeof(prefix) - 1);
    memcpy(device + sizeof(prefix) - 1, name, length + 1);
    *size = sizeof(prefix) + length;
    return true;
}
