#pragma once
#include "configurable.hpp"
#include "creation_timing.hpp"
#include <memory>

namespace rz {
constexpr size_t RecoveryMemoryBudget = 256ULL * 1024 * 1024;
struct RecoveryLimits { size_t workers, slots, estimated_bytes; };
struct RecoveryJob {
    uint32_t index = 0, k = 0, m = 0;
    uint64_t data_start = 0, parity_start = 0;
    std::vector<Bytes> blocks;
    std::vector<Digest> hashes;
    RecoveryWorkTiming timing;
private:
    bool ready = false;
    friend class RecoveryPool;
};

// Single coordinator, independent worker contexts, ordered results. Every queued,
// running or completed group holds a slot until take(); commit before submitting
// another group. The source and geometry must outlive the pool.
class RecoveryPool {
public:
    RecoveryPool(const File& source, uint64_t stream_size, const UUID& uuid,
                 std::span<const CodingGroup> groups, uint32_t threads = 0, bool striped = false);
    // Uniform profile 5 geometry is generated on demand, never an archive-sized array.
    RecoveryPool(const File& source, uint64_t stream_size, const UUID& uuid,
                 uint32_t k, uint32_t m, uint32_t threads = 0);
    ~RecoveryPool();
    RecoveryPool(const RecoveryPool&) = delete;
    RecoveryPool& operator=(const RecoveryPool&) = delete;
    bool empty() const;
    bool full() const;
    const RecoveryLimits& limits() const;
    size_t peak_jobs() const;
    void submit_next();
    std::unique_ptr<RecoveryJob> take();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
