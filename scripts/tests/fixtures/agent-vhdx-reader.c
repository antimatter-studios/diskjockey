#include "DJAgentImageReader.h"
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(DJAgentImageGeometry) == 16, "geometry ABI size");
_Static_assert(offsetof(DJAgentImageGeometry, logicalSectorSize) == 8, "sector ABI offset");

static unsigned descriptors(void) {
    unsigned n = 0;
    for (int fd = 0; fd < 256; ++fd) n += fcntl(fd, F_GETFD) >= 0;
    return n;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    int image = open(argv[1], O_RDONLY), raw = open(argv[2], O_RDONLY);
    assert(image >= 0 && raw >= 0);
    struct stat st;
    assert(fstat(raw, &st) == 0);
    unsigned before = descriptors();
    DJAgentImageGeometry geometry = {0};
    assert(lseek(image, 17, SEEK_SET) == 17);
    DJAgentImageReader *reader = dj_agent_vhdx_open(image, &geometry);
    assert(reader);
    assert(lseek(image, 0, SEEK_CUR) == 17);
    assert(geometry.virtualSize == (uint64_t)st.st_size);
    assert(geometry.logicalSectorSize == 512);
    assert(geometry.reserved == 0);
    assert(descriptors() == before + 1);
    assert(fcntl(image, F_GETFD) >= 0); /* Borrowed descriptor stays open. */
    assert(close(image) == 0);
    const uint64_t offsets[] = {0, 1048576, 1048576 + 4096, 16 * 1048576,
                                geometry.virtualSize - 4096};
    unsigned char actual[4096], expected[4096];
    for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        assert(pread(raw, expected, sizeof(expected), (off_t)offsets[i]) == sizeof(expected));
        assert(dj_agent_image_read(reader, offsets[i], actual, sizeof(actual)) == 0);
        assert(memcmp(actual, expected, sizeof(actual)) == 0);
    }
    assert(dj_agent_image_read(reader, geometry.virtualSize - 1, actual, 2) != 0);
    assert(dj_agent_image_read(reader, UINT64_MAX, actual, 1) != 0);
    unsigned char *large = malloc(DJ_AGENT_IMAGE_MAX_READ + 1);
    unsigned char *rawLarge = malloc(DJ_AGENT_IMAGE_MAX_READ);
    assert(large && rawLarge);
    assert(pread(raw, rawLarge, DJ_AGENT_IMAGE_MAX_READ, 0) == DJ_AGENT_IMAGE_MAX_READ);
    assert(dj_agent_image_read(reader, 0, large, DJ_AGENT_IMAGE_MAX_READ) == 0);
    assert(memcmp(large, rawLarge, DJ_AGENT_IMAGE_MAX_READ) == 0);
    assert(dj_agent_image_read(reader, 0, large, DJ_AGENT_IMAGE_MAX_READ + 1) != 0);
    free(large);
    free(rawLarge);
    assert(dj_agent_image_read(reader, 0, NULL, 1) != 0);
    assert(dj_agent_image_read(NULL, 0, actual, 1) != 0);
    dj_agent_image_close(reader);
    assert(descriptors() == before - 1);
    /* Raw content must not become a VHDX because of its pathname. */
    geometry.virtualSize = 123;
    assert(dj_agent_vhdx_open(raw, &geometry) == NULL);
    assert(geometry.virtualSize == 123);
    assert(descriptors() == before - 1);
    assert(dj_agent_vhdx_open(-1, &geometry) == NULL);
    assert(dj_agent_vhdx_open(raw, NULL) == NULL);
    /* Truncation after open must produce an error, never success with zeros. */
    image = open(argv[1], O_RDWR);
    assert(image >= 0);
    reader = dj_agent_vhdx_open(image, &geometry);
    assert(reader && ftruncate(image, 0) == 0);
    assert(dj_agent_image_read(reader, 1048576, actual, sizeof(actual)) != 0);
    dj_agent_image_close(reader);
    assert(close(image) == 0 && close(raw) == 0);
    dj_agent_image_close(NULL);
    puts("agent-vhdx-reader: all checks passed");
}
