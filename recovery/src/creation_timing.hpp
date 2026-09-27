#pragma once
#include <chrono>
#include <cstdint>
#include <iostream>

namespace rz {
using TimingClock = std::chrono::steady_clock;
inline uint64_t elapsed_ns(TimingClock::time_point start) {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(TimingClock::now() - start).count());
}
struct RecoveryWorkTiming { uint64_t read = 0, encode = 0, hash = 0; };
struct CreationTiming {
    uint64_t packing = 0, recovery = 0, payload_write = 0, index = 0, volume_write = 0, verify = 0, publish = 0;
    RecoveryWorkTiming work;
    size_t volume_workers = 1;
    void report(uint64_t total, uint64_t compression_us, size_t workers, size_t peak_jobs, size_t estimated_bytes) const {
        // Work durations sum across workers, and can exceed recovery wall time.
        // RZPROGRESS1 is unchanged; older clients ignore this additional record.
        std::cerr << "RZTIMING1\t{\"version\":1,\"total_us\":" << total / 1000
            << ",\"packing_us\":" << packing / 1000 << ",\"compression_us\":" << compression_us
            << ",\"recovery_wall_us\":" << recovery / 1000 << ",\"read_work_us\":" << work.read / 1000
            << ",\"rs_work_us\":" << work.encode / 1000 << ",\"hash_work_us\":" << work.hash / 1000
            << ",\"payload_write_us\":" << payload_write / 1000 << ",\"index_us\":" << index / 1000
            << ",\"volume_write_us\":" << volume_write / 1000 << ",\"verify_us\":" << verify / 1000
            << ",\"publish_us\":" << publish / 1000 << ",\"recovery_workers\":" << workers
            << ",\"recovery_peak_jobs\":" << peak_jobs << ",\"recovery_estimated_bytes\":" << estimated_bytes
            << ",\"volume_write_workers\":" << volume_workers
            << "}\n" << std::flush;
    }
};
}
