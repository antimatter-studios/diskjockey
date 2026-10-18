/* Same-machine host/DriverKit read protocol, version 1. No pointers, paths or
 * runtime dependencies. Native-endian fixed-width fields. A request arrives in
 * the async completion's arguments; a reply's header travels as scalars and
 * its payload as the call's one structure input. This header does not enable
 * transport. */
#pragma once
#include "DJVirtualDiskShared.h"

#ifdef __cplusplus
extern "C" {
#endif

#define kDJReadProtocolVersion 1u
#define kDJReadMaxBytes 1048576u
#define kDJReadMaxTimeoutNanoseconds UINT64_C(30000000000)
enum { kDJReadReplySuccess = 0, kDJReadReplyIOError = 1 };
/* Connect's scalars: version, the nonzero attachment identity, and the
 * reader's nonzero decoded virtual size (never the container's length). */
#define kDJReadConnectScalarCount 3u

/* Read transport selectors, after the mount selectors. None has a scalar or
 * structure output; DJVirtualDiskUserClientDispatch.h holds the exact table. */
enum {
    kDJSelectorConnectReadEndpoint = 3,    /* Version, identity, virtual size; async completion. */
    kDJSelectorDeliverReadReply = 4,       /* DJReadReply scalars; 0..kDJReadMaxBytes payload. */
    kDJSelectorDisconnectReadEndpoint = 5, /* No arguments. */
};

typedef struct DJReadRequest {
    uint64_t requestID;           /* Nonzero; never reuse across connections. */
    uint64_t deviceID;            /* Nonzero live mount identity. */
    uint64_t imageOffset;         /* Decoded image offset, partition added once. */
    uint64_t deadlineNanoseconds; /* Absolute shared monotonic time, not ticks. */
    uint32_t byteCount;           /* 1..1 MiB, bounded by the original read. */
    uint32_t version;
} DJReadRequest;

typedef struct DJReadReply {
    uint64_t requestID;
    uint32_t byteCount; /* Actual payload length, never allocation capacity. */
    uint32_t status;
    uint32_t version;
    uint32_t reserved;  /* Must be zero. */
} DJReadReply;

/* An external method call carries one structure input, and above 4096 bytes
 * IOKit passes it only as a memory descriptor. So a reply's header is its five
 * fields as scalars, in this order, and the payload is the structure input,
 * inline or a descriptor, whichever IOKit chose. */
#define kDJReadReplyScalarCount 5u

static inline void DJReadReplyToScalars(const DJReadReply *reply,
                                        uint64_t scalars[kDJReadReplyScalarCount])
{
    scalars[0] = reply->requestID;
    scalars[1] = reply->byteCount;
    scalars[2] = reply->status;
    scalars[3] = reply->version;
    scalars[4] = reply->reserved;
}

/* scalars is untrusted. A 32-bit field whose scalar does not fit is refused,
 * never truncated. Failure leaves *reply unchanged. */
static inline bool DJReadReplyFromScalars(const uint64_t *scalars, uint32_t scalarCount,
                                          DJReadReply *reply)
{
    if (!scalars || scalarCount != kDJReadReplyScalarCount || !reply) return false;
    for (uint32_t i = 1; i < kDJReadReplyScalarCount; ++i)
        if (scalars[i] > UINT32_MAX) return false;
    reply->requestID = scalars[0];
    reply->byteCount = (uint32_t)scalars[1];
    reply->status = (uint32_t)scalars[2];
    reply->version = (uint32_t)scalars[3];
    reply->reserved = (uint32_t)scalars[4];
    return true;
}

/* Callers check incoming buffer lengths BEFORE copying into aligned local
 * headers. These helpers take aligned, complete local copies only. geometry
 * comes from DJMountRequestGetGeometry, with the decoded virtual capacity.
 * Both peers use the same monotonic nanosecond clock and conversion. */
static inline bool DJReadRequestIsValid(
    const DJReadRequest *request, size_t requestSize,
    const DJMountGeometry *geometry, uint64_t nowNanoseconds)
{
    if (!request || requestSize != sizeof(*request) || !geometry) return false;
    if (request->version != kDJReadProtocolVersion || request->requestID == 0 ||
        request->deviceID == 0 || request->byteCount == 0 ||
        request->byteCount > kDJReadMaxBytes) return false;
    if (geometry->blockSize != 512 && geometry->blockSize != 4096) return false;
    if (geometry->byteLength == 0 ||
        geometry->byteLength > UINT64_MAX - geometry->byteOffset ||
        geometry->byteOffset % geometry->blockSize != 0 ||
        geometry->byteLength % geometry->blockSize != 0) return false;
    if (request->imageOffset < geometry->byteOffset) return false;
    const uint64_t relativeOffset = request->imageOffset - geometry->byteOffset;
    if (relativeOffset > geometry->byteLength ||
        request->byteCount > geometry->byteLength - relativeOffset ||
        relativeOffset % geometry->blockSize != 0 ||
        request->byteCount % geometry->blockSize != 0) return false;
    return request->deadlineNanoseconds > nowNanoseconds &&
        request->deadlineNanoseconds - nowNanoseconds <= kDJReadMaxTimeoutNanoseconds;
}

/* mediaOffset and byteCount describe the ORIGINAL block read, in bytes.
 * Never increase count or pass an already translated image offset here.
 * The transport fails oversized reads or splits them with separate identities;
 * it must never silently clamp them. Failure leaves output unchanged. */
static inline bool DJReadRequestCreate(
    const DJMountGeometry *geometry, uint64_t requestID, uint64_t deviceID,
    uint64_t mediaOffset, uint64_t byteCount, uint64_t deadlineNanoseconds,
    uint64_t nowNanoseconds, DJReadRequest *output)
{
    if (!geometry || !output || byteCount > kDJReadMaxBytes ||
        mediaOffset > UINT64_MAX - geometry->byteOffset) return false;
    DJReadRequest request;
    request.requestID = requestID;
    request.deviceID = deviceID;
    request.imageOffset = geometry->byteOffset + mediaOffset;
    request.deadlineNanoseconds = deadlineNanoseconds;
    request.byteCount = (uint32_t)byteCount;
    request.version = kDJReadProtocolVersion;
    if (!DJReadRequestIsValid(&request, sizeof(request), geometry, nowNanoseconds)) return false;
    *output = request;
    return true;
}

/* request is the retained, immutable accepted request. payloadSize excludes
 * this reply header. Only true permits copying exactly request->byteCount
 * payload bytes to a block completion. On false, fail the whole read without
 * copying any bytes. Identity matching alone does not retire pending state:
 * the lifecycle must enforce once-only completion and reject late replies.
 * A timer and disconnect handler must fail pending reads without any reply. */
static inline bool DJReadReplyIsComplete(
    const DJReadRequest *request, const DJReadReply *reply, size_t replySize,
    size_t payloadSize, uint64_t nowNanoseconds)
{
    if (!request || !reply || replySize != sizeof(*reply)) return false;
    if (request->version != kDJReadProtocolVersion || request->requestID == 0 ||
        request->deviceID == 0 || request->byteCount == 0 ||
        request->byteCount > kDJReadMaxBytes ||
        request->deadlineNanoseconds <= nowNanoseconds ||
        request->deadlineNanoseconds - nowNanoseconds > kDJReadMaxTimeoutNanoseconds) return false;
    return reply->version == kDJReadProtocolVersion && reply->reserved == 0 &&
        reply->requestID == request->requestID && reply->status == kDJReadReplySuccess &&
        reply->byteCount == request->byteCount && payloadSize == request->byteCount;
}

#ifdef __cplusplus
}
#endif
