#include "recovery_pool.hpp"
#include <algorithm>
#include <condition_variable>
#include <deque>
#include <exception>
#include <mutex>
#include <thread>

namespace rz {
struct RecoveryPool::Impl {
    Impl(const File& source, uint64_t size, const UUID& uuid, std::span<const CodingGroup> groups, uint32_t requested, bool striped)
        : source(source), stream_size(size), uuid(uuid), groups(groups) {
        if (requested > 64 || groups.empty() || size > MaxOutput + MaxOutput / 100)
            throw std::runtime_error("Invalid recovery pool configuration");
        uint64_t data_blocks = 0; size_t max_shards = 0;
        for (size_t i = 0; i < groups.size(); ++i) {
            const auto& g = groups[i];
            if (g.k < 1 || g.k > MaxDataShards || g.m < 1 || g.m > g.k ||
                (striped ? (g.k != groups.front().k || g.m != groups.front().m)
                         : (i + 1 < groups.size() && g.k != MaxDataShards)))
                throw std::runtime_error("Invalid recovery pool geometry");
            data_blocks += g.k; max_shards = std::max(max_shards, size_t(g.k + g.m));
        }
        const auto real_blocks = std::max<uint64_t>(1, size / BlockSize + (size % BlockSize != 0));
        const auto expected_blocks = striped ? ((real_blocks + groups.front().k - 1) / groups.front().k) * groups.front().k : real_blocks;
        if (data_blocks != expected_blocks)
            throw std::runtime_error("Recovery groups do not cover the stream");
        // Own/size one context before choosing the pool size. Initialize the rest
        // serially too: GF CPU detection and initialization use process globals.
        encoders.push_back(std::make_unique<RecoveryEncoder>());
        const auto context_bytes = encoders.front()->memory_usage();
        const size_t group_bytes = sizeof(RecoveryJob) + max_shards * (BlockSize + sizeof(Bytes) + sizeof(Digest)) + 1024;
        constexpr size_t overhead = 1024 * 1024;
        const auto available = (RecoveryMemoryBudget - overhead) / (context_bytes + 2 * group_bytes);
        if (!available) throw std::runtime_error("Recovery memory budget is too small");
        auto desired = requested ? requested : std::max(1U, std::thread::hardware_concurrency());
        // Narrow stripes use less memory, but tiny archives should not start a
        // worker for every stripe. Amortize automatic workers over 1 MiB of work.
        if (striped && !requested) {
            const auto work_bytes = uint64_t(groups.size()) * max_shards * BlockSize;
            desired = static_cast<uint32_t>(std::min<uint64_t>(desired, (work_bytes + 1024 * 1024 - 1) / (1024 * 1024)));
        }
        limits.workers = std::min({size_t(desired), size_t(64), available, groups.size()});
        limits.slots = std::min(groups.size(), limits.workers * 2);
        limits.estimated_bytes = overhead + context_bytes * limits.workers + group_bytes * limits.slots;
        while (encoders.size() < limits.workers) encoders.push_back(std::make_unique<RecoveryEncoder>());
        workers.reserve(limits.workers);
    }
    ~Impl() {
        { std::lock_guard lock(mutex); stopping = true; }
        cancellation.request_stop();
        changed.notify_all();
        for (auto& worker : workers) worker.join();
    }
    void run(size_t worker) noexcept {
        try {
            auto& encoder = *encoders[worker];
            for (;;) {
                RecoveryJob* job;
                {
                    std::unique_lock lock(mutex);
                    changed.wait(lock, [&] { return stopping || !work.empty(); });
                    if (stopping) return;
                    job = work.front(); work.pop_front();
                }
                check_cancel();
                auto start = TimingClock::now();
                job->blocks.resize(job->k + job->m);
                for (auto& block : job->blocks) block.resize(BlockSize);
                for (uint32_t s = 0; s < job->k; ++s) {
                    const auto offset = (job->data_start + s) * BlockSize;
                    const auto length = offset < stream_size ? std::min<uint64_t>(BlockSize, stream_size - offset) : 0;
                    if (length && !source.read(offset, job->blocks[s].data(), static_cast<size_t>(length)))
                        throw std::runtime_error("Compressed spool is truncated");
                }
                job->timing.read = elapsed_ns(start);
                start = TimingClock::now(); encoder.encode(job->k, job->m, job->blocks, cancellation.get_token());
                job->timing.encode = elapsed_ns(start);
                start = TimingClock::now(); job->hashes.reserve(job->blocks.size());
                for (uint32_t s = 0; s < job->blocks.size(); ++s) {
                    check_cancel();
                    job->hashes.push_back(block_hash_v2(uuid, job->index, s, job->blocks[s]));
                }
                job->timing.hash = elapsed_ns(start);
                { std::lock_guard lock(mutex); job->ready = true; }
                changed.notify_all();
            }
        } catch (...) {
            {
                std::lock_guard lock(mutex);
                if (!error) error = std::current_exception();
                stopping = true;
            }
            cancellation.request_stop();
            changed.notify_all();
        }
    }
    const File& source;
    const uint64_t stream_size;
    const UUID uuid;
    const std::span<const CodingGroup> groups;
    RecoveryLimits limits{};
    size_t submitted = 0, peak = 0;
    uint64_t data_start = 0, parity_start = 0;
    std::vector<std::unique_ptr<RecoveryEncoder>> encoders;
    std::mutex mutex;
    std::condition_variable changed;
    bool stopping = false;
    std::stop_source cancellation;
    std::exception_ptr error;
    std::deque<std::unique_ptr<RecoveryJob>> ordered;
    std::deque<RecoveryJob*> work;
    std::vector<std::thread> workers;
};
RecoveryPool::RecoveryPool(const File& source, uint64_t size, const UUID& uuid,
                           std::span<const CodingGroup> groups, uint32_t threads, bool striped)
    : impl_(std::make_unique<Impl>(source, size, uuid, groups, threads, striped)) {
    // If thread creation fails, impl_'s destructor joins every started worker.
    for (size_t i = 0; i < impl_->limits.workers; ++i)
        impl_->workers.emplace_back([state = impl_.get(), i] { state->run(i); });
}
RecoveryPool::~RecoveryPool() = default;
bool RecoveryPool::empty() const { return impl_->ordered.empty(); }
bool RecoveryPool::full() const { return impl_->ordered.size() == impl_->limits.slots; }
const RecoveryLimits& RecoveryPool::limits() const { return impl_->limits; }
size_t RecoveryPool::peak_jobs() const { return impl_->peak; }
void RecoveryPool::submit_next() {
    check_cancel(); auto& state = *impl_;
    std::lock_guard lock(state.mutex);
    if (state.error) std::rethrow_exception(state.error);
    if (full() || state.submitted == state.groups.size()) throw std::runtime_error("Recovery queue admission exceeded");
    const auto& g = state.groups[state.submitted];
    auto job = std::make_unique<RecoveryJob>();
    job->index = static_cast<uint32_t>(state.submitted); job->k = g.k; job->m = g.m;
    job->data_start = state.data_start; job->parity_start = state.parity_start;
    state.ordered.push_back(std::move(job)); state.work.push_back(state.ordered.back().get());
    ++state.submitted; state.data_start += g.k; state.parity_start += g.m;
    state.peak = std::max(state.peak, state.ordered.size());
    state.changed.notify_all();
}
std::unique_ptr<RecoveryJob> RecoveryPool::take() {
    auto& state = *impl_; std::unique_lock lock(state.mutex);
    if (empty()) throw std::runtime_error("Recovery queue is empty");
    for (;;) {
        check_cancel();
        if (state.error) std::rethrow_exception(state.error);
        if (state.ordered.front()->ready) break;
        state.changed.wait_for(lock, std::chrono::milliseconds(50));
    }
    auto job = std::move(state.ordered.front()); state.ordered.pop_front();
    return job;
}
}
