#pragma once
#include "crypto.hpp"
#include <memory>

namespace rz {
constexpr uint32_t MaxDecompressionThreads = 64;
// Includes admitted records/results, worker contexts and both decrypt layers.
// Filesystem buffers, archive indexes and thread stacks are separate.
constexpr size_t DecompressionMemoryBudget = 256ULL * 1024 * 1024;
struct DecompressionLimits {
    size_t workers, slots, estimated_bytes;
};
DecompressionLimits decompression_limits(uint32_t requested_threads);

struct DecompressionJob {
    explicit DecompressionJob(bool sensitive) : sensitive(sensitive) {}
    ~DecompressionJob();
    DecompressionJob(const DecompressionJob&) = delete;
    DecompressionJob& operator=(const DecompressionJob&) = delete;
    size_t entry = 0;
    uint64_t offset = 0;
    uint32_t plain_size = 0;
    RecordKind kind = RecordKind::Content;
    Bytes record, plain;
    const bool sensitive;
private:
    bool ready = false;
    friend class DecompressionPool;
};

// One coordinator reads/checks records and submits/takes jobs. Workers only
// decrypt and decompress; keys must outlive the pool and must not be mutated.
// Queued, running and completed jobs all occupy admission slots. Consume and
// release each taken job before allocating/submitting its replacement.
class DecompressionPool {
public:
    explicit DecompressionPool(const UUID& uuid, const ArchiveKeys* keys = nullptr, uint32_t requested_threads = 0);
    ~DecompressionPool();
    DecompressionPool(const DecompressionPool&) = delete;
    DecompressionPool& operator=(const DecompressionPool&) = delete;
    bool empty() const;
    bool full() const;
    const DecompressionLimits& limits() const;
    void submit(std::unique_ptr<DecompressionJob> job);
    std::unique_ptr<DecompressionJob> take();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
