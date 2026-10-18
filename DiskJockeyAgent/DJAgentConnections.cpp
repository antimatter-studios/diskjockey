#include "DJAgentConnections.hpp"
#include <pthread.h>
#include <time.h>

dispatch_queue_t DJAgentConnectionQueue() { return dispatch_get_main_queue(); }
static void checkQueue() { dispatch_assert_queue(DJAgentConnectionQueue()); }
DJAgentConnectionRegistry &DJAgentConnections() {
    checkQueue();
    // Keep retained cleanup alive for the service lifetime, even after XPC
    // releases the exported object. Never destroy live readers on disconnect.
    static auto *registry = new DJAgentConnectionRegistry(checkQueue);
    return *registry;
}
uint64_t DJAgentConnectionOpen() {
    if (pthread_main_np()) return DJAgentConnections().connect();
    __block uint64_t owner = 0;
    dispatch_sync(DJAgentConnectionQueue(), ^{ owner = DJAgentConnections().connect(); });
    return owner;
}
void DJAgentConnectionDisconnect(uint64_t owner) {
    dispatch_async(DJAgentConnectionQueue(), ^{
        DJAgentConnections().disconnect(owner);
        DJAgentConnections().collectClosed();
    });
}
uint64_t DJAgentConnectionTimer::now() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
bool DJAgentConnectionTimer::arm(uint64_t deadline, void (*callback)(void *), void *context) {
    checkQueue(); cancel();
    const auto time = now();
    if (!callback || (deadline > time && deadline - time > INT64_MAX)) return false;
    source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, DJAgentConnectionQueue());
    if (!source_) return false;
    dispatch_source_set_event_handler(source_, ^{
        checkQueue(); callback(context);
        // Timer callbacks have unwound before closed entries are collected.
        dispatch_async(DJAgentConnectionQueue(), ^{ DJAgentConnections().collectClosed(); });
    });
    dispatch_source_set_timer(source_, dispatch_time(DISPATCH_TIME_NOW, deadline > time ? deadline - time : 0),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(source_);
    return true;
}
void DJAgentConnectionTimer::cancel() {
    checkQueue();
    if (!source_) return;
    dispatch_source_cancel(source_);
    dispatch_release(source_);
    source_ = nullptr;
}
