#include "DJAgentReadEndpoint.h"
#include "DJAgentReadLoop.hpp"
#include <IOKit/IOMessage.h>
#include <assert.h>
#include <new>
#include <pthread.h>
#include <time.h>

extern "C" bool DJAgentAuthorizeImage(const char *, int);
struct DJAgentReadEndpoint {
    io_service_t service;
    io_connect_t connection = IO_OBJECT_NULL;
    IONotificationPortRef notifications = nullptr;
    io_object_t interest = IO_OBJECT_NULL;
    DJAgentReadLoop loop;
    explicit DJAgentReadEndpoint(io_service_t s);
};
static uint64_t now(void *) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static DJAgentImageReader *openImage(void *, int fd, DJAgentImageGeometry *g) {
    return dj_agent_vhdx_open(fd, g);
}
static void received(void *p, IOReturn result, void **arguments, uint32_t count) {
    auto *endpoint = static_cast<DJAgentReadEndpoint *>(p);
    uint64_t words[5];
    if (result == kIOReturnSuccess && arguments && count == 5) {
        for (unsigned i = 0; i < 5; ++i) words[i] = reinterpret_cast<uintptr_t>(arguments[i]);
        endpoint->loop.receive(true, words, 5);
    } else endpoint->loop.receive(result == kIOReturnSuccess, nullptr, count);
}
static void terminated(void *p, io_service_t, uint32_t message, void *) {
    if (message == kIOMessageServiceIsTerminated)
        static_cast<DJAgentReadEndpoint *>(p)->loop.stop();
}
static bool connect(void *p, DJAgentReadLoop *, uint64_t version) {
    auto *e = static_cast<DJAgentReadEndpoint *>(p);
    if (IOServiceOpen(e->service, mach_task_self(), 0, &e->connection) != kIOReturnSuccess) return false;
    e->notifications = IONotificationPortCreate(kIOMainPortDefault);
    if (!e->notifications) return false;
    if (!IONotificationPortGetRunLoopSource(e->notifications)) return false;
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(e->notifications), kCFRunLoopCommonModes);
    if (IOServiceAddInterestNotification(e->notifications, e->service, kIOGeneralInterest,
        terminated, e, &e->interest) != kIOReturnSuccess) return false;
    io_async_ref64_t reference = {};
    reference[kIOAsyncCalloutFuncIndex] = reinterpret_cast<uintptr_t>(&received);
    reference[kIOAsyncCalloutRefconIndex] = reinterpret_cast<uintptr_t>(e);
    return IOConnectCallAsyncMethod(e->connection, kDJSelectorConnectReadEndpoint,
        IONotificationPortGetMachPort(e->notifications), reference, kIOAsyncCalloutCount,
        &version, 1, nullptr, 0, nullptr, nullptr, nullptr, nullptr) == kIOReturnSuccess;
}
static bool reply(void *p, const uint64_t *header, uint32_t count, const void *payload, size_t size) {
    auto *e = static_cast<DJAgentReadEndpoint *>(p);
    return IOConnectCallMethod(e->connection, kDJSelectorDeliverReadReply, header, count,
        payload, size, nullptr, nullptr, nullptr, nullptr) == kIOReturnSuccess;
}
static void disconnect(void *p) {
    auto *e = static_cast<DJAgentReadEndpoint *>(p);
    IOConnectCallMethod(e->connection, kDJSelectorDisconnectReadEndpoint,
        nullptr, 0, nullptr, 0, nullptr, nullptr, nullptr, nullptr);
}
DJAgentReadEndpoint::DJAgentReadEndpoint(io_service_t s) : service(s), loop({this,
    DJAgentAuthorizeImage, openImage, dj_agent_image_read, dj_agent_image_close,
    now, connect, reply, disconnect}) {}
DJAgentReadEndpoint *DJAgentReadEndpointOpen(io_service_t service,
    const DJMountRequest *mount, int proof, uint64_t deviceID) {
    if (!pthread_main_np() || !mount) return nullptr;
    auto *e = new (std::nothrow) DJAgentReadEndpoint(service);
    if (e && !e->loop.start(*mount, proof, deviceID)) { DJAgentReadEndpointClose(e); return nullptr; }
    return e;
}
void DJAgentReadEndpointClose(DJAgentReadEndpoint *e) {
    if (!e) return;
    assert(pthread_main_np());
    // All callbacks and open/close run on the main thread; removing the source
    // prevents callbacks with this refcon after the endpoint is freed.
    if (e->notifications) {
        if (auto source = IONotificationPortGetRunLoopSource(e->notifications))
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        if (e->interest) IOObjectRelease(e->interest);
        IONotificationPortDestroy(e->notifications);
    }
    e->loop.stop();
    if (e->connection) IOServiceClose(e->connection);
    delete e;
}
