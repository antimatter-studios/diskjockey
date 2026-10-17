#include "DJVirtualDiskShared.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
#define ABI_ASSERT static_assert
#else
#define ABI_ASSERT _Static_assert
#endif

/* These offsets are the saved prototype's wire layout, not sizeof-derived
 * expectations that would silently follow an accidental ABI change. */
ABI_ASSERT(kDJSelectorMountImage == 0, "mount selector");
ABI_ASSERT(kDJSelectorUnmountImage == 1, "unmount selector");
ABI_ASSERT(kDJSelectorListMounts == 2, "list selector");
ABI_ASSERT(kDJMaxVirtualDisks == 16, "mount capacity");
ABI_ASSERT(sizeof(DJMountRequest) == 1048, "request size");
ABI_ASSERT(offsetof(DJMountRequest, path) == 0, "path offset");
ABI_ASSERT(offsetof(DJMountRequest, partOffset) == 1024, "partition offset");
ABI_ASSERT(offsetof(DJMountRequest, partLength) == 1032, "length offset");
ABI_ASSERT(offsetof(DJMountRequest, blockSize) == 1040, "block size offset");
ABI_ASSERT(offsetof(DJMountRequest, _pad) == 1044, "reserved offset");
ABI_ASSERT(sizeof(DJMountInfo) == 1064, "mount info size");
ABI_ASSERT(offsetof(DJMountInfo, deviceID) == 0, "device ID offset");
ABI_ASSERT(offsetof(DJMountInfo, bsdName) == 8, "BSD name offset");
ABI_ASSERT(offsetof(DJMountInfo, path) == 40, "mount info path offset");

static int fails;
#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL  line %d: %s\n", __LINE__, #condition); \
        fails++; \
    } \
} while (0)

static DJMountRequest whole_image(void)
{
    DJMountRequest request;
    memset(&request, 0, sizeof(request));
    strcpy(request.path, "/tmp/disk.qcow2");
    return request;
}

static void rejected(DJMountRequest request, size_t size, uint64_t virtualSize)
{
    DJMountGeometry geometry;
    DJMountGeometry before;
    memset(&geometry, 0xa5, sizeof(geometry));
    memcpy(&before, &geometry, sizeof(before));
    CHECK(!DJMountRequestGetGeometry(&request, size, virtualSize, &geometry));
    CHECK(memcmp(&geometry, &before, sizeof(geometry)) == 0);
}

int main(void)
{
    DJMountRequest request = whole_image();
    DJMountGeometry geometry;
    memset(&geometry, 0, sizeof(geometry));
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 8192, &geometry));
    CHECK(geometry.byteOffset == 0);
    CHECK(geometry.byteLength == 8192);
    CHECK(geometry.blockSize == 512);

    request.blockSize = 512;
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 8192, &geometry));
    CHECK(geometry.blockSize == 512);
    request.blockSize = 4096;
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 8192, &geometry));
    CHECK(geometry.blockSize == 4096);

    request.partOffset = 4096;
    request.partLength = 4096;
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 16384, &geometry));
    CHECK(geometry.byteOffset == 4096);
    CHECK(geometry.byteLength == 4096);
    request.partOffset = 8192;
    request.partLength = 8192;
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 16384, &geometry));
    CHECK(geometry.byteOffset == 8192);
    CHECK(geometry.byteLength == 8192);

    request = whole_image();
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), UINT64_MAX - 511, &geometry));
    CHECK(geometry.byteLength == UINT64_MAX - 511);
    CHECK(!DJMountRequestGetGeometry(NULL, sizeof(request), 8192, &geometry));
    CHECK(!DJMountRequestGetGeometry(&request, sizeof(request), 8192, NULL));
    rejected(request, 0, 8192);
    rejected(request, sizeof(request) - 1, 8192);
    rejected(request, sizeof(request) + 1, 8192);
    rejected(request, SIZE_MAX, 8192);
    rejected(request, sizeof(request), 0);
    rejected(request, sizeof(request), 511);
    rejected(request, sizeof(request), 8193);

    request.path[0] = '\0';
    rejected(request, sizeof(request), 8192);
    strcpy(request.path, "relative.qcow2");
    rejected(request, sizeof(request), 8192);
    memset(request.path, 'x', sizeof(request.path));
    request.path[0] = '/';
    rejected(request, sizeof(request), 8192);
    request.path[sizeof(request.path) - 1] = '\0';
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 8192, &geometry));

    request = whole_image();
    request._pad = 1;
    rejected(request, sizeof(request), 8192);
    request = whole_image();
    const uint32_t invalidBlockSizes[] = { 1, 256, 1024, 8192, UINT32_MAX };
    for (size_t i = 0; i < sizeof(invalidBlockSizes) / sizeof(invalidBlockSizes[0]); i++) {
        request.blockSize = invalidBlockSizes[i];
        rejected(request, sizeof(request), 8192);
    }

    request = whole_image();
    request.partOffset = 512;
    rejected(request, sizeof(request), 8192); /* Offset without an explicit length. */
    request.partLength = 8192;
    rejected(request, sizeof(request), 8192); /* End beyond virtual capacity. */
    request.partOffset = 8192;
    request.partLength = 512;
    rejected(request, sizeof(request), 8192); /* Start exactly at EOF. */
    request.partOffset = 8704;
    rejected(request, sizeof(request), 8192); /* Start beyond EOF. */
    request.partOffset = UINT64_MAX - 511;
    request.partLength = 1024;
    rejected(request, sizeof(request), UINT64_MAX); /* Wrapped addition must not pass. */
    request.partOffset = 512;
    request.partLength = UINT64_MAX - 511;
    rejected(request, sizeof(request), UINT64_MAX); /* Oversized length must not wrap. */
    request.partOffset = 1;
    request.partLength = 512;
    rejected(request, sizeof(request), 8192);
    request.partOffset = 0;
    request.partLength = 513;
    rejected(request, sizeof(request), 8192);
    request.blockSize = 4096;
    request.partOffset = 512;
    request.partLength = 4096;
    rejected(request, sizeof(request), 8192);
    request.partOffset = 0;
    request.partLength = 512;
    rejected(request, sizeof(request), 8192);

    request = whole_image();
    request.partLength = 8192;
    CHECK(DJMountRequestGetGeometry(&request, sizeof(request), 8192, &geometry));
    return fails != 0;
}
