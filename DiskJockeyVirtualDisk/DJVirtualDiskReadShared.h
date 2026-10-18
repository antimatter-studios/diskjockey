/* Same-machine host/DriverKit read protocol, version 1. No pointers, paths or
 * runtime dependencies. Native-endian fixed-width fields; headers and payload
 * are separate user-client buffers. This header does not enable transport. */
#pragma once
#include "DJVirtualDiskShared.h"

#ifdef __cplusplus
extern "C" {
#endif

#define kDJReadProtocolVersion 1u
#define kDJReadMaxBytes 1048576u
#define kDJReadMaxTimeoutNanoseconds UINT64_C(30000000000)
enum { kDJReadReplySuccess = 0, kDJReadReplyIOError = 1 };

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
