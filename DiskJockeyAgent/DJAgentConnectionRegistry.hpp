/* Process-lifetime DriverKit ownership. Every entry point, media callback and
 * lifecycle timer runs on the agent's one serial queue. The platform keeps
 * hook contexts alive until collectClosed removes the closed bridge. */
#pragma once
#include "DJAgentBridge.hpp"
#include "DJAgentMediaMatch.hpp"
#include <map>
#include <memory>
#include <set>
#include <vector>

class DJAgentConnectionRegistry {
public:
    explicit DJAgentConnectionRegistry(void (*checkQueue)()) : checkQueue_(checkQueue) {
        assert(checkQueue_);
    }
    uint64_t connect() {
        checkQueue_();
        if (lastOwner_ == UINT64_MAX) return 0; // Exhaustion never wraps to a reused owner.
        const auto owner = ++lastOwner_; owners_.insert(owner); return owner;
    }
    /* The registry constructs the bridge with its owner and a never-reused
     * identity. A rejected request owns nothing and takes no completion.
     * keepAlive may own the platform context (including its timer). */
    uint64_t attach(uint64_t owner, const DJMountRequest &mount, int proof, uint64_t wait,
                    DJAgentBridgePlatform platform, DJAgentAttachment::Hooks hooks,
                    DJAgentAttachment::Completion completion, void *context,
                    std::shared_ptr<void> keepAlive = {}) {
        checkQueue_();
        if (!owners_.count(owner) || lastAttachment_ == UINT64_MAX) return 0;
        const auto identity = ++lastAttachment_;
        auto entry = std::make_shared<Entry>(owner, identity, platform, hooks, std::move(keepAlive));
        entries_.emplace(identity, entry);
        if (!entry->bridge.attach(mount, proof, wait, completion, context)) {
            entries_.erase(identity); return 0;
        }
        return identity;
    }
    bool detach(uint64_t owner, uint64_t identity,
                DJAgentAttachment::Completion completion, void *context) {
        checkQueue_();
        const auto entry = find(identity);
        return owners_.count(owner) && entry && entry->owner == owner &&
            entry->bridge.lifecycle().detach(owner, identity, completion, context);
    }
    void disconnect(uint64_t owner) {
        checkQueue_(); owners_.erase(owner);
        // A snapshot survives completion reentry, including collectClosed().
        // Repeated interruption/invalidation retries any retained cleanup.
        std::vector<std::shared_ptr<Entry>> owned;
        for (const auto &item : entries_)
            if (item.second->owner == owner) owned.push_back(item.second);
        for (const auto &entry : owned) entry->bridge.lifecycle().disconnect();
    }
    void appeared(const DJAgentMediaEvent &event) {
        checkQueue_();
        std::vector<std::shared_ptr<Entry>> snapshot;
        for (const auto &item : entries_) snapshot.push_back(item.second);
        for (const auto &entry : snapshot) {
            char device[32]; size_t size = 0;
            if (DJAgentOwnedMediaDevice(entry->identity, &event, device, &size))
                entry->bridge.lifecycle().appeared(entry->identity, device, size);
        }
    }
    void unmounted(uint64_t identity, uint64_t attempt, bool success) {
        checkQueue_();
        const auto entry = find(identity);
        if (entry) entry->bridge.lifecycle().unmounted(identity, attempt, success);
    }
    /* Call after callback delivery unwinds. Failed unmount/removal keeps its
     * bridge and hook context alive; disconnect(owner) can retry it. */
    void collectClosed() {
        checkQueue_();
        for (auto i = entries_.begin(); i != entries_.end(); ) {
            if (i->second->bridge.lifecycle().closed()) i = entries_.erase(i);
            else ++i;
        }
    }
private:
    struct Entry {
        uint64_t owner, identity;
        std::shared_ptr<void> keepAlive; // Destroy the bridge before its hook context.
        DJAgentBridge bridge;
        Entry(uint64_t o, uint64_t id, DJAgentBridgePlatform p,
              DJAgentAttachment::Hooks h, std::shared_ptr<void> lifetime)
            : owner(o), identity(id), keepAlive(std::move(lifetime)), bridge(o, id, p, h) {}
    };
    void (*checkQueue_)();
    uint64_t lastOwner_ = 0, lastAttachment_ = 0;
    std::set<uint64_t> owners_;
    std::map<uint64_t, std::shared_ptr<Entry>> entries_;
    std::shared_ptr<Entry> find(uint64_t identity) {
        const auto i = entries_.find(identity);
        return i == entries_.end() ? nullptr : i->second;
    }
};
