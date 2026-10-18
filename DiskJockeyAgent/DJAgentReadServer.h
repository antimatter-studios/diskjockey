/* Host-only agent side of read protocol version 1. Never include in the dext.
 * One validated request becomes exactly one reply; the endpoint sends it. */
#pragma once
#include "DJAgentImageReader.h"
#include "DJVirtualDiskReadShared.h"
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* dj_agent_image_read's signature, so the real reader passes directly. */
typedef int (*DJAgentReadFunction)(const DJAgentImageReader *, uint64_t, void *, size_t);

/* geometry is the mount the agent authorized; reader is borrowed and already
 * authorized by AgentAuthority. requestBytes is untrusted: its length is
 * checked before an aligned copy. false means malformed, expired or outside
 * geometry: send no reply, the reader was not called, *reply is unchanged.
 * true means *reply is complete. Send exactly reply->byteCount payload bytes:
 * all of the request on success, none on kDJReadReplyIOError. The request's
 * imageOffset already carries the partition offset and is read as given. */
static inline bool DJAgentServeRead(
    const DJMountGeometry *geometry, const void *requestBytes, size_t requestSize,
    uint64_t nowNanoseconds, DJAgentReadFunction read, const DJAgentImageReader *reader,
    void *payload, size_t payloadCapacity, DJReadReply *reply)
{
    if (!geometry || !requestBytes || requestSize != sizeof(DJReadRequest) ||
        !read || !payload || !reply) return false;
    DJReadRequest request;
    memcpy(&request, requestBytes, sizeof(request));
    if (!DJReadRequestIsValid(&request, sizeof(request), geometry, nowNanoseconds)) return false;
    DJReadReply answer;
    answer.requestID = request.requestID;
    answer.byteCount = 0;
    answer.status = kDJReadReplyIOError;
    answer.version = kDJReadProtocolVersion;
    answer.reserved = 0;
    if (payloadCapacity >= request.byteCount) {
        if (read(reader, request.imageOffset, payload, request.byteCount) == 0) {
            answer.byteCount = request.byteCount;
            answer.status = kDJReadReplySuccess;
        } else {
            memset(payload, 0, request.byteCount); /* Never keep a partial read. */
        }
    }
    *reply = answer;
    return true;
}

#ifdef __cplusplus
}
#endif
