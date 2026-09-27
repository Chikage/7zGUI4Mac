#include "decompression_pool.hpp"
#include "io.hpp"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <exception>
#include <mutex>
#include <thread>
#include <zstd.h>

namespace rz {
DecompressionLimits decompression_limits(uint32_t requested_threads) {
    if (requested_threads > MaxDecompressionThreads) throw std::runtime_error("Decompression threads must be auto or 1..64");
    const size_t record = ZSTD_compressBound(FrameSize) + RecordOverhead + 28;
    // Two admitted records/results per worker, plus two temporary decrypt
    // buffers at the peak of dual-layer authentication.
    const size_t per_worker = FrameDecoder::memory_usage() + 2 * (record + FrameSize) + 2 * record;
    const size_t available = DecompressionMemoryBudget / per_worker;
    if (!available) throw std::runtime_error("Decompression memory budget is too small");
    const size_t requested = requested_threads ? requested_threads : std::max(1U, std::thread::hardware_concurrency());
    const size_t workers = std::min({requested, available, size_t(MaxDecompressionThreads)});
    return {workers, workers * 2, workers * per_worker};
}
DecompressionJob::~DecompressionJob() {
    if (sensitive) { wipe(record); wipe(plain); }
}
struct DecompressionPool::Impl {
    Impl(const UUID& uuid, const ArchiveKeys* keys, uint32_t requested)
        : uuid(uuid), keys(keys), limits(decompression_limits(requested)) {}
    ~Impl() {
        { std::lock_guard lock(mutex); stopping = true; }
        changed.notify_all();
        for (auto& worker : workers) worker.join();
        // Jobs and their plaintext outlive every worker on all exit paths.
    }
    void run() noexcept {
        try {
            FrameDecoder decoder;
            for (;;) {
                DecompressionJob* job;
                {
                    std::unique_lock lock(mutex);
                    changed.wait(lock, [&] { return stopping || !work.empty(); });
                    if (stopping) return;
                    job = work.front(); work.pop_front();
                }
                check_cancel();
                {
                    auto compressed = keys ? keys->open(uuid, job->kind, job->offset, job->plain_size, job->record)
                                           : std::move(job->record);
                    WipeOnExit wipe_compressed(compressed, job->sensitive);
                    job->plain = decoder.decode(compressed, job->plain_size);
                }
                if (job->sensitive) wipe(job->record);
                Bytes().swap(job->record);
                check_cancel();
                { std::lock_guard lock(mutex); job->ready = true; }
                changed.notify_all();
            }
        } catch (...) {
            {
                std::lock_guard lock(mutex);
                if (!error) error = std::current_exception();
                stopping = true;
            }
            changed.notify_all();
        }
    }
    const UUID uuid;
    const ArchiveKeys* const keys;
    const DecompressionLimits limits;
    std::mutex mutex;
    std::condition_variable changed;
    bool stopping = false;
    std::exception_ptr error;
    size_t pending_plain_bytes = 0;
    std::deque<std::unique_ptr<DecompressionJob>> ordered;
    std::deque<DecompressionJob*> work;
    std::vector<std::thread> workers;
};
DecompressionPool::DecompressionPool(const UUID& uuid, const ArchiveKeys* keys, uint32_t requested_threads)
    : impl_(std::make_unique<Impl>(uuid, keys, requested_threads)) {}
DecompressionPool::~DecompressionPool() = default;
bool DecompressionPool::empty() const { return impl_->ordered.empty(); }
bool DecompressionPool::full() const { return impl_->ordered.size() >= impl_->limits.slots; }
const DecompressionLimits& DecompressionPool::limits() const { return impl_->limits; }
void DecompressionPool::submit(std::unique_ptr<DecompressionJob> job) {
    check_cancel();
    auto& state = *impl_;
    std::lock_guard lock(state.mutex);
    if (state.error) std::rethrow_exception(state.error);
    if (!job || full()) throw std::runtime_error("Decompression queue admission exceeded");
    if (state.keys && !job->sensitive) throw std::runtime_error("Encrypted decoding requires sensitive job buffers");
    if (!job->plain.empty() || job->plain_size == 0 || job->plain_size > FrameSize ||
        job->record.empty() || job->record.size() > ZSTD_compressBound(FrameSize) + RecordOverhead + 28)
        throw std::runtime_error("Invalid decompression frame");
    state.ordered.push_back(std::move(job));
    state.work.push_back(state.ordered.back().get());
    state.pending_plain_bytes += state.ordered.back()->plain_size;
    const auto demand = std::max<size_t>(1, (state.pending_plain_bytes + FrameSize - 1) / FrameSize);
    if (state.workers.size() < std::min(state.limits.workers, demand))
        state.workers.emplace_back([&state] { state.run(); });
    state.changed.notify_all();
}
std::unique_ptr<DecompressionJob> DecompressionPool::take() {
    auto& state = *impl_;
    std::unique_lock lock(state.mutex);
    if (empty()) throw std::runtime_error("Decompression queue is empty");
    for (;;) {
        check_cancel();
        if (state.error) std::rethrow_exception(state.error);
        if (state.ordered.front()->ready) break;
        state.changed.wait_for(lock, std::chrono::milliseconds(50));
    }
    auto job = std::move(state.ordered.front()); state.ordered.pop_front();
    state.pending_plain_bytes -= job->plain_size;
    return job;
}
}
