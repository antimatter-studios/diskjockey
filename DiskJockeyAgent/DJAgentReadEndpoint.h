/* Main-thread-only agent endpoint. The service is borrowed; open creates and
 * owns its user-client connection. Close drains callback delivery first. */
#pragma once
#include <IOKit/IOKitLib.h>
#include "../DiskJockeyVirtualDisk/DJVirtualDiskReadShared.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct DJAgentReadEndpoint DJAgentReadEndpoint;
DJAgentReadEndpoint *DJAgentReadEndpointOpen(io_service_t service,
    const DJMountRequest *mount, int proof, uint64_t deviceID);
void DJAgentReadEndpointClose(DJAgentReadEndpoint *endpoint);
int32_t DJAgentReadEndpointCall(DJAgentReadEndpoint *endpoint, uint64_t selector,
    const uint64_t *input, uint32_t inputCount, const void *structure, size_t structureSize,
    uint64_t *output, uint32_t *outputCount);
#ifdef __cplusplus
}
#endif
