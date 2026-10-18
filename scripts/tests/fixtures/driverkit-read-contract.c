#include "DJVirtualDiskReadShared.h"
#include "DJAgentImageReader.h"
#include <stdio.h>
#include <string.h>
#ifdef __cplusplus
#define ABI_ASSERT static_assert
#else
#define ABI_ASSERT _Static_assert
#endif
ABI_ASSERT(kDJReadProtocolVersion == 1, "version");
ABI_ASSERT(kDJReadMaxBytes == 1048576, "wire read ceiling");
ABI_ASSERT(kDJReadMaxBytes == DJ_AGENT_IMAGE_MAX_READ, "host adapter ceiling");
ABI_ASSERT(kDJReadMaxTimeoutNanoseconds == UINT64_C(30000000000), "deadline ceiling");
ABI_ASSERT(kDJReadReplySuccess == 0 && kDJReadReplyIOError == 1, "status values");
ABI_ASSERT(sizeof(DJReadRequest) == 40, "request size");
ABI_ASSERT(offsetof(DJReadRequest, requestID) == 0, "request ID");
ABI_ASSERT(offsetof(DJReadRequest, deviceID) == 8, "device ID");
ABI_ASSERT(offsetof(DJReadRequest, imageOffset) == 16, "decoded image offset");
ABI_ASSERT(offsetof(DJReadRequest, deadlineNanoseconds) == 24, "deadline");
ABI_ASSERT(offsetof(DJReadRequest, byteCount) == 32, "request count");
ABI_ASSERT(offsetof(DJReadRequest, version) == 36, "request version");
ABI_ASSERT(sizeof(DJReadReply) == 24, "reply header size");
ABI_ASSERT(offsetof(DJReadReply, requestID) == 0, "reply ID");
ABI_ASSERT(offsetof(DJReadReply, byteCount) == 8, "reply count");
ABI_ASSERT(offsetof(DJReadReply, status) == 12, "reply status");
ABI_ASSERT(offsetof(DJReadReply, version) == 16, "reply version");
ABI_ASSERT(offsetof(DJReadReply, reserved) == 20, "reply reserved");
static int fails;
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL  line %d: %s\n", __LINE__, #condition); fails++; \
} } while (0)
static const uint64_t now = 100;
static DJMountGeometry partition(void)
{
    DJMountGeometry geometry = { 4096, 2 * 1048576, 512 };
    return geometry;
}
static DJReadRequest request(void)
{
    DJMountGeometry geometry = partition();
    DJReadRequest value;
    memset(&value, 0, sizeof(value));
    CHECK(DJReadRequestCreate(&geometry, 7, 11, 512, 512, 1000, now, &value));
    return value;
}
static DJReadReply reply(void)
{
    DJReadReply value = { 7, 512, kDJReadReplySuccess, kDJReadProtocolVersion, 0 };
    return value;
}
static void rejected_create(DJMountGeometry geometry, uint64_t offset,
                            uint64_t count, uint64_t deadline)
{
    DJReadRequest value, before;
    memset(&value, 0xa5, sizeof(value));
    memcpy(&before, &value, sizeof(before));
    CHECK(!DJReadRequestCreate(&geometry, 7, 11, offset, count, deadline, now, &value));
    CHECK(memcmp(&value, &before, sizeof(value)) == 0);
}
int main(void)
{
    DJMountGeometry geometry = partition();
    DJReadRequest value = request();
    CHECK(value.requestID == 7 && value.deviceID == 11);
    CHECK(value.imageOffset == 4608 && value.byteCount == 512);
    CHECK(value.deadlineNanoseconds == 1000 && value.version == 1);
    CHECK(DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    CHECK(DJReadRequestCreate(&geometry, 7, 11, 1048576, 1048576,
                              now + kDJReadMaxTimeoutNanoseconds, now, &value));
    CHECK(value.imageOffset == 1052672 && value.byteCount == 1048576);
    CHECK(DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    geometry.byteOffset = 0;
    geometry.blockSize = 4096;
    CHECK(DJReadRequestCreate(&geometry, 7, 11, 4096, 4096, 1000, now, &value));
    CHECK(value.imageOffset == 4096);
    geometry = partition();
    CHECK(!DJReadRequestCreate(NULL, 7, 11, 0, 512, 1000, now, &value));
    CHECK(!DJReadRequestCreate(&geometry, 7, 11, 0, 512, 1000, now, NULL));
    CHECK(!DJReadRequestCreate(&geometry, 0, 11, 0, 512, 1000, now, &value));
    CHECK(!DJReadRequestCreate(&geometry, 7, 0, 0, 512, 1000, now, &value));
    rejected_create(geometry, 0, 0, 1000);
    rejected_create(geometry, 1, 512, 1000);
    rejected_create(geometry, 0, 513, 1000);
    rejected_create(geometry, 0, 1048577, 1000);
    rejected_create(geometry, 0, 1049088, 1000);
    rejected_create(geometry, 0, UINT64_MAX, 1000);
    rejected_create(geometry, geometry.byteLength, 512, 1000);
    rejected_create(geometry, geometry.byteLength - 512, 1024, 1000);
    rejected_create(geometry, UINT64_MAX - 511, 512, 1000);
    rejected_create(geometry, 0, 512, now);
    rejected_create(geometry, 0, 512, 0);
    rejected_create(geometry, 0, 512, now + kDJReadMaxTimeoutNanoseconds + 1);
    geometry.byteOffset = UINT64_MAX - 511;
    rejected_create(geometry, 512, 512, 1000);
    rejected_create(geometry, 0, 512, 1000); /* Whole geometry overflows. */
    geometry = partition(); geometry.byteLength = 0;
    rejected_create(geometry, 0, 512, 1000);
    geometry = partition(); geometry.byteLength++;
    rejected_create(geometry, 0, 512, 1000);
    geometry = partition(); geometry.byteOffset++;
    rejected_create(geometry, 0, 512, 1000);
    geometry = partition(); geometry.blockSize = 1024;
    rejected_create(geometry, 0, 512, 1000);
    geometry = partition(); geometry.blockSize = 4096;
    rejected_create(geometry, 512, 4096, 1000);
    rejected_create(geometry, 0, 512, 1000);
    geometry = partition();
    value = request();
    CHECK(!DJReadRequestIsValid(NULL, sizeof(value), &geometry, now));
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), NULL, now));
    CHECK(!DJReadRequestIsValid(&value, sizeof(value) - 1, &geometry, now));
    CHECK(!DJReadRequestIsValid(&value, sizeof(value) + 1, &geometry, now));
    CHECK(!DJReadRequestIsValid(&value, SIZE_MAX, &geometry, now));
    value.version++;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.requestID = 0;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.deviceID = 0;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.byteCount = 0;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.byteCount = 1049088;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.imageOffset++;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.byteCount++;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.imageOffset = 512; /* Before partition. */
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request(); value.imageOffset = geometry.byteOffset + geometry.byteLength;
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, now));
    value = request();
    CHECK(!DJReadRequestIsValid(&value, sizeof(value), &geometry, 1000));
    /* UINT64_MAX deadlines remain valid near clock wrap without addition. */
    CHECK(DJReadRequestCreate(&geometry, 7, 11, 0, 512,
                              UINT64_MAX, UINT64_MAX - 1, &value));
    value = request();
    DJReadReply answer = reply();
    CHECK(DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    CHECK(!DJReadReplyIsComplete(NULL, &answer, sizeof(answer), 512, now));
    CHECK(!DJReadReplyIsComplete(&value, NULL, sizeof(answer), 512, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer) - 1, 512, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer) + 1, 512, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, SIZE_MAX, 512, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 511, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 513, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), SIZE_MAX, now));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, 1000));
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, 1001));
    answer.requestID++;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer = reply(); answer.status = kDJReadReplyIOError;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer.status = UINT32_MAX;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer = reply(); answer.byteCount--;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 511, now));
    answer = reply(); answer.byteCount++;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 513, now));
    answer = reply(); answer.version++;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer = reply(); answer.reserved = 1;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer = reply(); value.byteCount = 0; answer.byteCount = 0;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 0, now));
    answer = reply();
    value = request(); value.version++;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    value = request(); value.requestID = 0; answer.requestID = 0;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    answer = reply();
    value = request(); value.deviceID = 0;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    value = request(); value.byteCount = 1049088; answer.byteCount = 1049088;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 1049088, now));
    answer = reply();
    value = request(); value.deadlineNanoseconds = now + kDJReadMaxTimeoutNanoseconds + 1;
    CHECK(!DJReadReplyIsComplete(&value, &answer, sizeof(answer), 512, now));
    CHECK(DJReadRequestCreate(&geometry, 7, 11, 1048576, 1048576, 1000, now, &value));
    answer = reply(); answer.byteCount = 1048576;
    CHECK(DJReadReplyIsComplete(&value, &answer, sizeof(answer), 1048576, now));
    return fails != 0;
}
