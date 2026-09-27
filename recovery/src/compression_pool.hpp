#pragma once
#include "codec.hpp"
#include <memory>

namespace rz {
constexpr uint32_t MaxCompressionThreads = 64;
// Budget for frame buffers, Zstd contexts and the ordered encryption writer.
// The archive index, filesystem metadata and thread stacks are separate.
constexpr size_t CompressionMemoryBudget = 256ULL * 1024 * 1024;
struct CompressionLimits {
    size_t workers, slots, estimated_bytes;
};
CompressionLimits compression_limits(uint32_t requested_threads);

struct CompressionJob {
    explicit CompressionJob(bool sensitive) : sensitive(sensitive) {}
    ~CompressionJob();
    CompressionJob(const CompressionJob&) = delete;
    CompressionJob& operator=(const CompressionJob&) = delete;
    size_t entry = 0;
    uint32_t plain_size = 0;
    bool last_in_file = false;
    Bytes plain, compressed;
    const bool sensitive;
private:
    bool ready = false;
    friend class CompressionPool;
};

// One coordinator submits and takes jobs; workers only own frame compression.
// Admission includes queued, running AND completed jobs awaiting ordered take().
// The coordinator must commit a taken job before allocating/submitting another.
class CompressionPool {
public:
    explicit CompressionPool(uint32_t requested_threads = 0);
    ~CompressionPool();
    CompressionPool(const CompressionPool&) = delete;
    CompressionPool& operator=(const CompressionPool&) = delete;
    bool empty() const;
    bool full() const;
    const CompressionLimits& limits() const;
    void submit(std::unique_ptr<CompressionJob> job);
    std::unique_ptr<CompressionJob> take();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
