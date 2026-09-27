#include "compression_pool.hpp"
#include "crypto.hpp"
#include "io.hpp"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <exception>
#include <mutex>
#include <thread>
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>

namespace rz {
CompressionLimits compression_limits(uint32_t requested_threads) {
    if (requested_threads > MaxCompressionThreads) throw std::runtime_error("Compression threads must be auto or 1..64");
    const size_t bound = ZSTD_compressBound(FrameSize);
    const size_t context = ZSTD_estimateCCtxSize(3);
    if (ZSTD_isError(context)) throw std::runtime_error(ZSTD_getErrorName(context));
    const size_t writer = 3 * (bound + 68); // Includes both layers of dual encryption.
    const size_t per_worker = context + 2 * (FrameSize + bound);
    const size_t available = (CompressionMemoryBudget - writer) / per_worker;
    if (!available) throw std::runtime_error("Compression memory budget is too small");
    const size_t requested = requested_threads ? requested_threads : std::max(1U, std::thread::hardware_concurrency());
    const size_t workers = std::min({requested, available, size_t(MaxCompressionThreads)});
    return {workers, workers * 2, writer + workers * per_worker};
}
CompressionJob::~CompressionJob() {
    if (sensitive) { wipe(plain); wipe(compressed); }
}
struct CompressionPool::Impl {
    explicit Impl(uint32_t requested) : limits(compression_limits(requested)) {}
    ~Impl() {
        {
            std::lock_guard lock(mutex);
            stopping = true;
        }
        changed.notify_all();
        for (auto& worker : workers) worker.join();
        // Jobs (including their plaintext) outlive every worker, even on error.
    }
    void run() noexcept {
        try {
            std::unique_ptr<ZSTD_CCtx, decltype(&ZSTD_freeCCtx)> context(ZSTD_createCCtx(), ZSTD_freeCCtx);
            if (!context) throw std::bad_alloc();
            for (;;) {
                CompressionJob* job;
                {
                    std::unique_lock lock(mutex);
                    changed.wait(lock, [&] { return stopping || !work.empty(); });
                    if (stopping) return;
                    job = work.front(); work.pop_front();
                }
                check_cancel();
                if (job->plain.empty() || job->plain.size() > FrameSize || job->plain.size() != job->plain_size)
                    throw std::runtime_error("Invalid compression frame");
                job->compressed.resize(ZSTD_compressBound(job->plain.size()));
                const auto size = ZSTD_compressCCtx(context.get(), job->compressed.data(), job->compressed.size(),
                                                   job->plain.data(), job->plain.size(), 3);
                if (ZSTD_isError(size)) throw std::runtime_error(ZSTD_getErrorName(size));
                job->compressed.resize(size);
                if (job->sensitive) wipe(job->plain);
                Bytes().swap(job->plain);
                check_cancel();
                {
                    std::lock_guard lock(mutex);
                    job->ready = true;
                }
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
    const CompressionLimits limits;
    std::mutex mutex;
    std::condition_variable changed;
    bool stopping = false;
    std::exception_ptr error;
    size_t pending_plain_bytes = 0;
    std::deque<std::unique_ptr<CompressionJob>> ordered;
    std::deque<CompressionJob*> work;
    std::vector<std::thread> workers;
};
CompressionPool::CompressionPool(uint32_t requested_threads) : impl_(std::make_unique<Impl>(requested_threads)) {}
CompressionPool::~CompressionPool() = default;
bool CompressionPool::empty() const { return impl_->ordered.empty(); }
bool CompressionPool::full() const { return impl_->ordered.size() == impl_->limits.slots; }
const CompressionLimits& CompressionPool::limits() const { return impl_->limits; }
void CompressionPool::submit(std::unique_ptr<CompressionJob> job) {
    check_cancel();
    auto& state = *impl_;
    std::lock_guard lock(state.mutex);
    if (state.error) std::rethrow_exception(state.error);
    if (!job || full()) throw std::runtime_error("Compression queue admission exceeded");
    state.ordered.push_back(std::move(job));
    state.work.push_back(state.ordered.back().get());
    state.pending_plain_bytes += state.ordered.back()->plain_size;
    // Scale with admitted bytes, not file count. Tiny files rarely have enough
    // compression work to repay additional thread startup and wakeups.
    const auto demand = std::max<size_t>(1, (state.pending_plain_bytes + FrameSize - 1) / FrameSize);
    if (state.workers.size() < std::min(state.limits.workers, demand))
        state.workers.emplace_back([&state] { state.run(); });
    state.changed.notify_all();
}
std::unique_ptr<CompressionJob> CompressionPool::take() {
    auto& state = *impl_;
    std::unique_lock lock(state.mutex);
    if (empty()) throw std::runtime_error("Compression queue is empty");
    for (;;) {
        check_cancel();
        if (state.error) std::rethrow_exception(state.error);
        if (state.ordered.front()->ready) break;
        // Signals cannot notify a condition variable. Bound cancellation latency.
        state.changed.wait_for(lock, std::chrono::milliseconds(50));
    }
    auto job = std::move(state.ordered.front()); state.ordered.pop_front();
    state.pending_plain_bytes -= job->plain_size;
    return job;
}
}
