#pragma once
#include "DJAgentConnections.h"
#include "DJAgentConnectionRegistry.hpp"

/* Queue-only API for the owned XPC methods and DiskArbitration callbacks. */
DJAgentConnectionRegistry &DJAgentConnections();

/* One active timer per attachment. Own it in the registry's keepAlive context.
 * arm/cancel/destruction and the callback all run on DJAgentConnectionQueue. */
class DJAgentConnectionTimer {
public:
    DJAgentConnectionTimer() = default;
    DJAgentConnectionTimer(const DJAgentConnectionTimer &) = delete;
    DJAgentConnectionTimer &operator=(const DJAgentConnectionTimer &) = delete;
    ~DJAgentConnectionTimer() { cancel(); }
    static uint64_t now();
    bool arm(uint64_t deadline, void (*callback)(void *), void *context);
    void cancel();
private:
    dispatch_source_t source_ = nullptr;
};
