#pragma once
#include <stdint.h>
#include <dispatch/dispatch.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Main is serial and also satisfies the existing read endpoint's main-thread
 * contract. Schedule DiskArbitration on this queue; never mutate off queue. */
dispatch_queue_t DJAgentConnectionQueue(void);
uint64_t DJAgentConnectionOpen(void);
/* Both XPC handlers hop asynchronously to the registry queue. */
void DJAgentConnectionDisconnect(uint64_t owner);
#ifdef __cplusplus
}
#endif
