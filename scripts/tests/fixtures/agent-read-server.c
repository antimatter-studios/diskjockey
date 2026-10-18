#include "DJAgentReadServer.h"
#include <stdio.h>
#include <string.h>
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL  line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
/* The fake reader stands in for the authorized qcow2/VHDX handle. */
struct DJAgentImageReader { unsigned calls; uint64_t offset; size_t len; int status; };
static unsigned char pattern(uint64_t offset) { return (unsigned char)(offset * 131u + 7u); }
static int fake_read(const DJAgentImageReader *reader, uint64_t offset, void *buffer, size_t len) {
    DJAgentImageReader *self = (DJAgentImageReader *)reader;
    self->calls++; self->offset = offset; self->len = len;
    for (size_t i = 0; i < len; ++i) ((unsigned char *)buffer)[i] = pattern(offset + i);
    return self->status;
}
static const DJMountGeometry geometry = { 1048576, 64u * 1048576u, 512 };
static const uint64_t now = 1000;
static unsigned char payload[kDJReadMaxBytes];
static DJReadRequest make(uint64_t mediaOffset, uint64_t count) {
    DJReadRequest request;
    memset(&request, 0, sizeof(request));
    CHECK(DJReadRequestCreate(&geometry, 9, 3, mediaOffset, count, now + 500, now, &request));
    return request;
}
static void refused(DJReadRequest request, size_t size, const char *why) {
    DJAgentImageReader reader = { 0, 0, 0, 0 };
    DJReadReply reply; memset(&reply, 0xA5, sizeof(reply));
    DJReadReply untouched = reply;
    if (DJAgentServeRead(&geometry, &request, size, now, fake_read, &reader,
                         payload, sizeof(payload), &reply)) {
        fprintf(stderr, "FAIL  %s produced a reply\n", why); ++fails;
    }
    CHECK(reader.calls == 0);
    CHECK(memcmp(&reply, &untouched, sizeof(reply)) == 0);
}
int main(void) {
    /* Success: exact offset (partition added once, by request construction). */
    DJReadRequest request = make(4096, 1024);
    unsigned char unaligned[sizeof(request) + 1];
    memcpy(unaligned + 1, &request, sizeof(request));
    DJAgentImageReader reader = { 0, 0, 0, 0 };
    DJReadReply reply;
    CHECK(DJAgentServeRead(&geometry, unaligned + 1, sizeof(request), now, fake_read, &reader,
                           payload, sizeof(payload), &reply));
    CHECK(reader.calls == 1 && reader.offset == 1048576u + 4096u && reader.len == 1024);
    CHECK(reply.requestID == 9 && reply.byteCount == 1024 && reply.reserved == 0);
    CHECK(reply.status == kDJReadReplySuccess && reply.version == kDJReadProtocolVersion);
    CHECK(DJReadReplyIsComplete(&request, &reply, sizeof(reply), reply.byteCount, now));
    for (size_t i = 0; i < 1024; ++i) CHECK(payload[i] == pattern(1048576u + 4096u + i));

    /* Reader failure: an I/O-error reply, no payload, partial bytes scrubbed. */
    DJAgentImageReader failing = { 0, 0, 0, -1 };
    CHECK(DJAgentServeRead(&geometry, &request, sizeof(request), now, fake_read, &failing,
                           payload, sizeof(payload), &reply));
    CHECK(failing.calls == 1 && reply.requestID == 9 && reply.byteCount == 0);
    CHECK(reply.status == kDJReadReplyIOError && reply.reserved == 0);
    CHECK(!DJReadReplyIsComplete(&request, &reply, sizeof(reply), reply.byteCount, now));
    for (size_t i = 0; i < 1024; ++i) CHECK(payload[i] == 0);

    /* A buffer smaller than the request fails it without reading anything. */
    DJAgentImageReader small = { 0, 0, 0, 0 };
    CHECK(DJAgentServeRead(&geometry, &request, sizeof(request), now, fake_read, &small,
                           payload, 512, &reply));
    CHECK(small.calls == 0 && reply.status == kDJReadReplyIOError && reply.byteCount == 0);

    /* Malformed requests get no reply and never reach the reader. */
    refused(request, sizeof(request) - 1, "short request header");
    refused(request, sizeof(request) + 1, "long request header");
    DJReadRequest bad = request; bad.version = 2; refused(bad, sizeof(bad), "wrong version");
    bad = request; bad.requestID = 0; refused(bad, sizeof(bad), "zero identity");
    bad = request; bad.deviceID = 0; refused(bad, sizeof(bad), "zero device");
    bad = request; bad.byteCount = 0; refused(bad, sizeof(bad), "empty read");
    bad = request; bad.byteCount = kDJReadMaxBytes + 512; refused(bad, sizeof(bad), "oversized read");
    bad = request; bad.byteCount = 1000; refused(bad, sizeof(bad), "unaligned length");
    bad = request; bad.imageOffset = 4096; refused(bad, sizeof(bad), "offset before partition");
    bad = request; bad.imageOffset += 1; refused(bad, sizeof(bad), "unaligned offset");
    bad = request; bad.imageOffset = geometry.byteOffset + geometry.byteLength;
    refused(bad, sizeof(bad), "offset past the volume");
    bad = request; bad.deadlineNanoseconds = now; refused(bad, sizeof(bad), "expired deadline");
    bad = request; bad.deadlineNanoseconds = now + kDJReadMaxTimeoutNanoseconds + 1;
    refused(bad, sizeof(bad), "deadline beyond the ceiling");
    DJAgentImageReader none = { 0, 0, 0, 0 };
    CHECK(!DJAgentServeRead(&geometry, NULL, sizeof(request), now, fake_read, &none, payload, sizeof(payload), &reply));
    CHECK(!DJAgentServeRead(&geometry, &request, sizeof(request), now, NULL, &none, payload, sizeof(payload), &reply));
    CHECK(!DJAgentServeRead(&geometry, &request, sizeof(request), now, fake_read, &none, NULL, sizeof(payload), &reply));
    CHECK(none.calls == 0);
    return fails ? 1 : 0;
}
