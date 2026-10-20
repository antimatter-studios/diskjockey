/* Host-only VHDX and qcow2 reader for the agent. Never include or link in the dext. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define DJ_AGENT_IMAGE_MAX_READ (1024u * 1024u)
typedef struct DJAgentImageReader DJAgentImageReader;
typedef struct DJAgentImageGeometry {
    uint64_t virtualSize;
    uint32_t logicalSectorSize;
    uint32_t reserved;
} DJAgentImageGeometry;
/* fd is borrowed, readable, regular and already authorized by AgentAuthority.
 * Duplicate it without reopening a path; caller retains ownership of fd.
 * NULL means invalid input, unsupported/corrupt image or an I/O error.
 * Failure leaves geometry unchanged. No file extension is trusted. */
DJAgentImageReader *dj_agent_vhdx_open(int fd, DJAgentImageGeometry *geometry);
/* As dj_agent_vhdx_open, with 512-byte sectors. An image naming a backing file
 * returns NULL: only fd was authorized, never a path inside the image. */
DJAgentImageReader *dj_agent_qcow2_open(int fd, DJAgentImageGeometry *geometry);
/* 0 means every requested byte was decoded. Any other status fails the whole
 * request: discard the output, which may contain a partial read. Offset is in
 * the virtual image; the transport must add its partition offset exactly once.
 * Callers provide len writable bytes and keep the handle alive until return. */
int dj_agent_image_read(const DJAgentImageReader *reader, uint64_t offset, void *buffer, size_t len);
/* NULL is allowed. Serialize close against reads; deadlines/cancellation belong
 * to the transport (#421). The handle cannot be used after close. */
void dj_agent_image_close(DJAgentImageReader *reader);
#ifdef __cplusplus
}
#endif
