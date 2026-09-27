#include "paged.hpp"
#include "compression_progress.hpp"
#include "recovery_pool.hpp"
#include <algorithm>
#include <exception>
#include <mutex>
#include <sys/resource.h>
#include <thread>

namespace rz {
namespace {
size_t descriptor_budget() {
    struct rlimit limit{};
    uint64_t available = 256;
    if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY)
        available = limit.rlim_cur > 32 ? limit.rlim_cur - 32 : 1;
    return static_cast<size_t>(std::max<uint64_t>(1, std::min<uint64_t>(available, 200)));
}
class PayloadFiles {
public:
    PayloadFiles(const fs::path& directory, uint32_t k, uint32_t m)
        : directory_(directory), k_(k), capacity_(std::min<size_t>(k + m, descriptor_budget())), files_(k + m), ages_(k + m) {}
    void append(uint32_t column, const Bytes& block, const Digest& digest) {
        auto& file = get(column); file.append(block); file.append(digest.data(), digest.size());
    }
    void clear() { for (auto& file : files_) file.reset(); opened_ = 0; }
private:
    File& get(uint32_t column) {
        if (!files_[column]) {
            if (opened_ == capacity_) {
                size_t oldest = files_.size();
                for (size_t i = 0; i < files_.size(); ++i)
                    if (files_[i] && (oldest == files_.size() || ages_[i] < ages_[oldest])) oldest = i;
                files_[oldest].reset(); --opened_;
            }
            files_[column] = std::make_unique<File>(directory_ / configurable_volume_name(column >= k_, column >= k_ ? column - k_ : column), File::Mode::Append);
            ++opened_;
        }
        ages_[column] = ++age_; return *files_[column];
    }
    const fs::path directory_;
    const uint32_t k_;
    const size_t capacity_;
    size_t opened_ = 0;
    uint64_t age_ = 0;
    std::vector<std::unique_ptr<File>> files_;
    std::vector<uint64_t> ages_;
};
// Only one leaf page and the bounded root digest table reside in memory. The
// spool contains public block digests, never decrypted filenames or contents.
class HashPages {
public:
    explicit HashPages(const fs::path& path) : file_(path, File::Mode::New), page_(BlockSize) {}
    void append(const Digest& digest) {
        std::copy(digest.begin(), digest.end(), page_.begin() + static_cast<ptrdiff_t>(used_)); used_ += digest.size();
        if (used_ == page_.size()) flush();
    }
    void finish(PagedBootstrap& bootstrap) {
        if (used_) flush();
        auto root = serialize_page_root(bootstrap, hashes_);
        if (root.size() != bootstrap.layout.root_size) throw std::runtime_error("Profile 5 root size changed");
        bootstrap.root_hash = hash(root); file_.append(root);
    }
private:
    void flush() {
        check_cancel(); hashes_.push_back(hash(page_)); file_.append(page_);
        std::fill(page_.begin(), page_.end(), 0); used_ = 0;
    }
    File file_;
    Bytes page_;
    size_t used_ = 0;
    std::vector<Digest> hashes_;
};
size_t finalize_volumes(const fs::path& directory, const PagedBootstrap& bootstrap, const Bytes& encoded, uint32_t requested) {
    const auto k = bootstrap.manifest.options.data_volumes;
    const auto count = k + bootstrap.manifest.options.recovery_volumes;
    const auto payload_size = (bootstrap.layout.data_stripes + bootstrap.layout.index_stripes) * PagedRecordSize;
    const auto desired = requested ? requested : std::max(1U, std::thread::hardware_concurrency());
    const auto workers = std::min({uint64_t(count), uint64_t(desired), uint64_t(4), uint64_t(descriptor_budget()),
        (uint64_t(count) * payload_size + 1024 * 1024 - 1) / (1024 * 1024)});
    std::atomic<uint32_t> next{0}; std::atomic<bool> stopped{false};
    std::mutex mutex; std::exception_ptr error;
    auto run = [&] {
        try {
            while (!stopped.load(std::memory_order_relaxed)) {
                const auto column = next.fetch_add(1); if (column >= count) break;
                const bool parity = column >= k; const auto volume = parity ? column - k : column;
                File file(directory / configurable_volume_name(parity, volume), File::Mode::Update);
                const auto end = HeaderSize + encoded.size() + payload_size;
                if (file.size() != end) throw std::runtime_error("Profile 5 staged payload size changed");
                file.write(0, make_paged_header(bootstrap, parity, volume, false)); file.write(HeaderSize, encoded);
                file.write(end, encoded); file.write(end + encoded.size(), make_paged_header(bootstrap, parity, volume, true));
                file.sync();
            }
        } catch (...) {
            { std::lock_guard lock(mutex); if (!error) error = std::current_exception(); }
            stopped.store(true, std::memory_order_relaxed);
        }
    };
    std::vector<std::jthread> workers_started;
    try { for (size_t i = 1; i < workers; ++i) workers_started.emplace_back(run); }
    catch (...) { stopped.store(true, std::memory_order_relaxed); throw; }
    run(); workers_started.clear();
    if (error) std::rethrow_exception(error);
    return workers;
}
}
void create_paged_archive(const InputPlan& plan, const fs::path& output, const RecoveryOptions& options,
                          const SecurityOptions& security, bool report_progress, uint32_t threads) {
    validate_options(options);
    if (options.mode != RecoveryMode::Volumes) throw std::runtime_error("Profile 5 requires counted volumes");
    if (security.generate_key_file) {
        if (!security.encrypt || !security.password || !security.password->from_key_file) throw KeyFileError();
        if (fs::exists(fs::symlink_status(recovery_key_path(output)))) throw std::runtime_error("Recovery key file already exists");
    }
    Staging staging(output);
    const auto spool_path = staging.path / "compressed.tmp", index_path = staging.path / "index.tmp";
    CompressionProgress progress(plan.root, plan.paths, report_progress);
    CreationTiming timing; const auto started = TimingClock::now(); auto phase_start = started;
    PagedBootstrap bootstrap; auto& manifest = bootstrap.manifest; std::optional<ArchiveKeys> keys;
    {
        auto packed = pack_protected(plan, spool_path, security, &progress, threads, MaxPagedOutput);
        manifest.uuid = packed.packed.uuid; manifest.stream_size = packed.packed.stream_size;
        manifest.security = std::move(packed.security); keys = std::move(packed.keys);
    }
    manifest.options = options;
    const auto k = options.data_volumes, m = options.recovery_volumes;
    bootstrap.index_volume_hashes.resize(k + m);
    bootstrap.layout = paged_layout(manifest.stream_size, k, m); update_paged_summary(bootstrap);
    const auto reserved_bootstrap = serialize_bootstrap(bootstrap).size();
    timing.packing = elapsed_ns(phase_start); phase_start = TimingClock::now(); progress.phase("recovery");
    for (uint32_t column = 0; column < k + m; ++column) {
        File file(staging.path / configurable_volume_name(column >= k, column >= k ? column - k : column), File::Mode::New);
        file.resize(HeaderSize + reserved_bootstrap);
    }
    PayloadFiles payloads(staging.path, k, m);
    RecoveryLimits limits{}; size_t peak_jobs = 0;
    auto observe = [&](const RecoveryPool& pool) {
        limits.workers = std::max(limits.workers, pool.limits().workers);
        limits.slots = std::max(limits.slots, pool.limits().slots);
        limits.estimated_bytes = std::max(limits.estimated_bytes, pool.limits().estimated_bytes);
        peak_jobs = std::max(peak_jobs, pool.peak_jobs());
    };
    auto accumulate = [&](const RecoveryJob& job) {
        timing.work.read += job.timing.read; timing.work.encode += job.timing.encode; timing.work.hash += job.timing.hash;
    };
    {
        HashPages pages(index_path);
        {
            File source(spool_path);
            RecoveryPool pool(source, manifest.stream_size, manifest.uuid, k, m, threads);
            auto consume = [&] {
                auto job = pool.take(); accumulate(*job); const auto write_start = TimingClock::now();
                for (uint32_t column = 0; column < k + m; ++column) {
                    payloads.append(column, job->blocks[column], job->hashes[column]); pages.append(job->hashes[column]);
                }
                timing.payload_write += elapsed_ns(write_start);
            };
            for (uint64_t i = 0; i < bootstrap.layout.data_stripes; ++i) {
                if (pool.full()) consume();
                pool.submit_next();
            }
            while (!pool.empty()) consume();
            observe(pool);
        }
        timing.recovery = elapsed_ns(phase_start); phase_start = TimingClock::now();
        pages.finish(bootstrap);
    }
    fs::remove(spool_path);
    std::vector<blake3_hasher> index_hashers(k + m);
    for (auto& hasher : index_hashers) blake3_hasher_init(&hasher);
    {
        File source(index_path);
        const auto index_size = uint64_t(bootstrap.layout.hash_pages) * BlockSize + bootstrap.layout.root_size;
        if (source.size() != index_size) throw std::runtime_error("Profile 5 index spool size changed");
        RecoveryPool pool(source, index_size, manifest.uuid, k, m, threads);
        auto consume = [&] {
            auto job = pool.take(); accumulate(*job);
            for (uint32_t column = 0; column < k + m; ++column) {
                const auto hash_start = TimingClock::now();
                const auto digest = index_block_hash(manifest.uuid, job->index, column, job->blocks[column]);
                blake3_hasher_update(&index_hashers[column], job->blocks[column].data(), job->blocks[column].size());
                blake3_hasher_update(&index_hashers[column], digest.data(), digest.size());
                timing.work.hash += elapsed_ns(hash_start);
                const auto write_start = TimingClock::now(); payloads.append(column, job->blocks[column], digest);
                timing.payload_write += elapsed_ns(write_start);
            }
        };
        for (uint64_t i = 0; i < bootstrap.layout.index_stripes; ++i) {
            if (pool.full()) consume();
            pool.submit_next();
        }
        while (!pool.empty()) consume();
        observe(pool);
    }
    for (uint32_t column = 0; column < k + m; ++column)
        blake3_hasher_finalize(&index_hashers[column], bootstrap.index_volume_hashes[column].data(), bootstrap.index_volume_hashes[column].size());
    payloads.clear(); fs::remove(index_path);
    if (keys) {
        manifest.security.public_mac.fill(0);
        manifest.security.public_mac = keys->manifest_mac(serialize_bootstrap(bootstrap));
    }
    auto encoded = serialize_bootstrap(bootstrap);
    if (encoded.size() != reserved_bootstrap) throw std::runtime_error("Profile 5 bootstrap size changed");
    (void)parse_bootstrap(encoded);
    timing.index = elapsed_ns(phase_start); phase_start = TimingClock::now(); progress.phase("writing");
    timing.volume_workers = finalize_volumes(staging.path, bootstrap, encoded, threads);
    {
        File sidecar(staging.path / "manifest.rzm", File::Mode::New); auto digest = hash(encoded);
        sidecar.append(encoded); sidecar.append(digest.data(), digest.size()); sidecar.sync();
    }
    timing.volume_write = elapsed_ns(phase_start); phase_start = TimingClock::now(); progress.phase("verifying");
    verify_paged_created(staging.path, encoded, keys ? &*keys : nullptr, threads);
    timing.verify = elapsed_ns(phase_start); phase_start = TimingClock::now();
    if (security.generate_key_file) {
        const auto key_path = staging.path / ".recovery-key"; write_key_file(key_path, manifest.uuid, *security.password);
        staging.commit_with_key(key_path);
    } else staging.commit();
    progress.phase("completed"); timing.publish = elapsed_ns(phase_start);
    if (report_progress) timing.report(elapsed_ns(started), progress.compression_microseconds(), limits.workers, peak_jobs, limits.estimated_bytes);
}
}
