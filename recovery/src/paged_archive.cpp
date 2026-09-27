#include "paged.hpp"
#include "decompression_pool.hpp"
#include "read_progress.hpp"
#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <sys/resource.h>
#include <thread>

namespace rz {
namespace {
struct Archive5 {
    fs::path directory;
    PagedBootstrap bootstrap;
    Bytes encoded;
    uint64_t metadata_issues = 0;
};
bool magic(const Bytes& b, const char* value) { return b.size() >= 8 && std::memcmp(b.data(), value, 8) == 0; }
bool valid_legacy_header(const Bytes& bytes, bool footer) {
    try {
        if (magic(bytes, footer ? "RZEND001" : "RZVOL001")) { (void)parse_header(bytes, footer); return true; }
        if (magic(bytes, footer ? "RZEND002" : "RZVOL002") || magic(bytes, footer ? "RZEND003" : "RZVOL003") ||
            magic(bytes, footer ? "RZEND004" : "RZVOL004")) { (void)parse_configurable_header(bytes, footer); return true; }
    } catch (const std::runtime_error&) { return false; }
    return false;
}
std::optional<Bytes> read_bytes(const File& file, uint64_t offset, size_t size) {
    Bytes bytes(size); if (!file.read(offset, bytes.data(), size)) return std::nullopt; return bytes;
}
std::optional<ConfigurableHeader> header(const File& file, bool footer) {
    if (!file.exists() || file.size() < HeaderSize) return std::nullopt;
    auto bytes = read_bytes(file, footer ? file.size() - HeaderSize : 0, HeaderSize);
    if (!bytes) return std::nullopt;
    try { return parse_paged_header(*bytes, footer); } catch (const std::runtime_error&) { return std::nullopt; }
}
uint64_t payload_size(const PagedBootstrap& b) { return (b.layout.data_stripes + b.layout.index_stripes) * PagedRecordSize; }
bool metadata_ok(const File& file, const Archive5& a, bool parity, uint32_t volume) {
    if (!file.exists() || file.size() != 2 * HeaderSize + 2 * a.encoded.size() + payload_size(a.bootstrap)) return false;
    for (bool footer : {false, true}) {
        auto bytes = read_bytes(file, footer ? file.size() - HeaderSize : 0, HeaderSize);
        if (!bytes || *bytes != make_paged_header(a.bootstrap, parity, volume, footer)) return false;
        bytes = read_bytes(file, footer ? file.size() - HeaderSize - a.encoded.size() : HeaderSize, a.encoded.size());
        if (!bytes || *bytes != a.encoded) return false;
    }
    return true;
}
Archive5 load(const fs::path& directory) {
    require_directory(directory); Archive5 a; a.directory = fs::canonical(directory);
    bool found = false;
    auto consider = [&](const Bytes& bytes) {
        bool legacy = false;
        try {
            if (magic(bytes, "RZIDX001")) { (void)parse_manifest(bytes); legacy = true; }
            else if (magic(bytes, "RZIDX002") || magic(bytes, "RZIDX003") || magic(bytes, "RZIDX004")) {
                (void)parse_configurable_manifest(bytes); legacy = true;
            }
        } catch (const std::runtime_error&) {}
        if (legacy) throw std::runtime_error("Mixed archive IDs or profiles");
        std::optional<PagedBootstrap> parsed;
        try { parsed = parse_bootstrap(bytes); } catch (const std::runtime_error&) { return; }
        if (found && bytes != a.encoded) throw std::runtime_error("Conflicting profile 5 bootstraps");
        if (!found) { a.bootstrap = std::move(*parsed); a.encoded = bytes; found = true; }
    };
    File sidecar(a.directory / "manifest.rzm", File::Mode::Read, true);
    if (sidecar.exists() && sidecar.size() >= 32 && sidecar.size() <= MaxManifest + 32) {
        auto bytes = read_bytes(sidecar, 0, static_cast<size_t>(sidecar.size()));
        if (bytes) {
            Digest digest{}; std::copy(bytes->end()-32, bytes->end(), digest.begin()); bytes->resize(bytes->size()-32);
            if (hash(*bytes) == digest) consider(*bytes);
        }
    }
    std::vector<fs::path> candidates;
    std::vector<std::pair<fs::path, ConfigurableHeader>> hints;
    for (const auto& entry : fs::directory_iterator(a.directory)) {
        if (entry.path().extension() != ".rzv" && entry.path().extension() != ".rzr") continue;
        if (candidates.size() == 200) throw std::runtime_error("Too many profile 5 volumes");
        candidates.push_back(entry.path()); File file(entry.path());
        for (bool footer : {false, true}) {
            if (file.size() >= HeaderSize) {
                auto envelope = read_bytes(file, footer ? file.size()-HeaderSize : 0, HeaderSize);
                if (envelope && valid_legacy_header(*envelope, footer)) throw std::runtime_error("Mixed archive IDs or profiles");
            }
            auto h = header(file, footer); if (!h) continue;
            hints.emplace_back(entry.path(), *h);
            if (!found) for (auto offset : {uint64_t(HeaderSize), HeaderSize + h->manifest_size + h->payload_size}) {
                auto bytes = read_bytes(file, offset, static_cast<size_t>(h->manifest_size));
                if (bytes && hash(*bytes) == h->manifest_hash) consider(*bytes);
            }
        }
    }
    if (!found) throw std::runtime_error("No valid profile 5 bootstrap remains");
    const auto& m = a.bootstrap.manifest; std::set<std::string> names;
    for (bool parity : {false, true}) for (uint32_t v = 0; v < m.volume_count(parity); ++v) names.insert(configurable_volume_name(parity, v));
    for (const auto& p : candidates) if (!names.contains(p.filename().string())) throw std::runtime_error("Unexpected profile 5 volume filename");
    for (const auto& [p, h] : hints) {
        if (h.uuid != m.uuid || h.manifest_hash != hash(a.encoded) || h.manifest_size != a.encoded.size() ||
            h.payload_size != payload_size(a.bootstrap) || h.volume >= m.volume_count(h.parity) || p.filename() != configurable_volume_name(h.parity, h.volume))
            throw std::runtime_error("Mixed archive IDs or conflicting profile 5 volumes");
    }
    auto expected = a.encoded; auto digest = hash(a.encoded); expected.insert(expected.end(), digest.begin(), digest.end());
    auto actual = sidecar.exists() && sidecar.size() == expected.size() ? read_bytes(sidecar, 0, expected.size()) : std::nullopt;
    if (!actual || *actual != expected) ++a.metadata_issues;
    for (bool parity : {false, true}) for (uint32_t v = 0; v < m.volume_count(parity); ++v) {
        File file(a.directory / configurable_volume_name(parity, v), File::Mode::Read, true);
        if (!metadata_ok(file, a, parity, v)) ++a.metadata_issues;
    }
    return a;
}
class VolumeCache {
public:
    VolumeCache(const Archive5& a, File::Mode mode, size_t consumers = 1) : a_(a), mode_(mode) {
        struct rlimit limit{}; uint64_t budget = 256;
        if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY) budget = limit.rlim_cur > 32 ? limit.rlim_cur - 32 : 1;
        capacity_ = std::max<uint64_t>(1, std::min<uint64_t>(200, budget / consumers));
    }
    File& get(uint32_t column) {
        auto it = files_.find(column);
        if (it == files_.end()) {
            if (files_.size() == capacity_) {
                auto oldest = std::min_element(files_.begin(), files_.end(), [](const auto& x, const auto& y) { return x.second.age < y.second.age; });
                files_.erase(oldest);
            }
            const auto k = a_.bootstrap.manifest.options.data_volumes;
            auto path = a_.directory / configurable_volume_name(column >= k, column >= k ? column-k : column);
            it = files_.emplace(column, Cached{std::make_unique<File>(path, mode_, mode_ == File::Mode::Read), 0}).first;
        }
        it->second.age = ++age_; return *it->second.file;
    }
    void clear() { files_.clear(); }
private:
    struct Cached { std::unique_ptr<File> file; uint64_t age; };
    const Archive5& a_; File::Mode mode_; size_t capacity_; uint64_t age_ = 0; std::map<uint32_t, Cached> files_;
};
uint64_t record_offset(const Archive5& a, bool index, uint64_t stripe) {
    return HeaderSize + a.encoded.size() + ((index ? a.bootstrap.layout.data_stripes : 0) + stripe) * PagedRecordSize;
}
bool read_record_block(const Archive5& a, VolumeCache& files, bool index, uint32_t stripe, uint32_t column, Bytes& block, Digest& local) {
    block.resize(PagedRecordSize); auto& file = files.get(column); const auto offset = record_offset(a, index, stripe);
    const bool ok = file.read(offset, block.data(), block.size());
    if (ok) std::copy_n(block.data()+BlockSize, local.size(), local.data());
    block.resize(BlockSize); return ok;
}
Digest local_hash(const Archive5& a, bool index, uint32_t stripe, uint32_t column, const Bytes& block) {
    return index ? index_block_hash(a.bootstrap.manifest.uuid, stripe, column, block)
                 : block_hash_v2(a.bootstrap.manifest.uuid, stripe, column, block);
}
class IndexReader {
public:
    IndexReader(const Archive5& a, VolumeCache& files, const std::vector<bool>* forced = nullptr) : a_(a), files_(files), forced_(forced) {}
    Bytes read(uint64_t offset, size_t size) {
        const auto& l = a_.bootstrap.layout; const auto k = a_.bootstrap.manifest.options.data_volumes;
        const auto logical_size = uint64_t(l.hash_pages) * BlockSize + l.root_size;
        if (offset > logical_size || size > logical_size-offset) throw std::runtime_error("Index read outside protected region");
        Bytes out(size); size_t done = 0;
        while (done < size) {
            const auto logical = offset / BlockSize; const auto stripe = static_cast<uint32_t>(logical/k), column = static_cast<uint32_t>(logical%k);
            const auto local = offset % BlockSize; const auto n = std::min<uint64_t>(size-done, BlockSize-local);
            if (cached_stripe_ != stripe || cached_column_ != column) {
                Digest digest{};
                if ((forced_ && forced_->at(column)) || !read_record_block(a_, files_, true, stripe, column, cache_, digest) || local_hash(a_, true, stripe, column, cache_) != digest) {
                    auto blocks = recover(stripe); cache_ = std::move(blocks[column]);
                }
                cached_stripe_ = stripe; cached_column_ = column;
            }
            std::copy_n(cache_.data()+local, n, out.data()+done); offset += n; done += n;
        }
        return out;
    }
    std::vector<Bytes> recover(uint32_t stripe) {
        const auto k = a_.bootstrap.manifest.options.data_volumes, m = a_.bootstrap.manifest.options.recovery_volumes;
        std::vector<Bytes> blocks(k+m); std::vector<int> missing;
        for (uint32_t s = 0; s < k+m; ++s) {
            Digest digest{};
            if ((forced_ && forced_->at(s)) || !read_record_block(a_, files_, true, stripe, s, blocks[s], digest) || local_hash(a_, true, stripe, s, blocks[s]) != digest) {
                missing.push_back(static_cast<int>(s)); blocks[s].assign(BlockSize, 0);
            }
        }
        if (missing.size() > m) throw std::runtime_error("Unrecoverable profile 5 index stripe");
        // Jerasure owns process-global field state. Index reads normally avoid
        // decoding, but concurrent verification may encounter a late IO failure.
        static std::mutex decode_mutex;
        { std::lock_guard lock(decode_mutex); ReedSolomon(k, m, 2).decode(blocks, missing); }
        return blocks;
    }
private:
    const Archive5& a_; VolumeCache& files_; const std::vector<bool>* forced_; Bytes cache_;
    uint32_t cached_stripe_ = UINT32_MAX, cached_column_ = UINT32_MAX;
};
class Digests {
public:
    Digests(const Archive5& a, IndexReader& reader) : a_(a), reader_(reader) {
        roots_ = parse_page_root(a.bootstrap, reader.read(uint64_t(a.bootstrap.layout.hash_pages)*BlockSize, static_cast<size_t>(a.bootstrap.layout.root_size)));
    }
    const Bytes& page(uint32_t index) {
        if (index >= roots_.size()) throw std::runtime_error("Invalid hash page number");
        auto it = pages_.find(index);
        if (it == pages_.end()) {
            if (pages_.size() == 16) pages_.erase(pages_.begin());
            auto bytes = reader_.read(uint64_t(index)*BlockSize, BlockSize);
            if (hash(bytes) != roots_[index]) throw std::runtime_error("Profile 5 hash page failed authentication; run repair first");
            it = pages_.emplace(index, std::move(bytes)).first;
        }
        return it->second;
    }
    Digest get(uint32_t stripe, uint32_t column) {
        const auto width = a_.bootstrap.manifest.options.data_volumes+a_.bootstrap.manifest.options.recovery_volumes;
        const auto offset = (uint64_t(stripe)*width+column)*32; auto& bytes = page(static_cast<uint32_t>(offset/BlockSize));
        Digest out{}; std::copy_n(bytes.data()+offset%BlockSize, 32, out.data()); return out;
    }
    void verify_pages() {
        for (uint32_t i = 0; i < roots_.size(); ++i) { check_cancel(); (void)page(i); }
        const auto digest_bytes = a_.bootstrap.layout.data_stripes *
            (a_.bootstrap.manifest.options.data_volumes+a_.bootstrap.manifest.options.recovery_volumes)*32;
        const auto remainder = digest_bytes%BlockSize;
        if (remainder) {
            const auto& last = page(static_cast<uint32_t>(roots_.size()-1));
            if (std::any_of(last.begin()+static_cast<ptrdiff_t>(remainder), last.end(), [](uint8_t v) { return v != 0; }))
                throw std::runtime_error("Invalid hash page padding");
        }
    }
private:
    const Archive5& a_; IndexReader& reader_; std::vector<Digest> roots_; std::map<uint32_t, Bytes> pages_;
};
class StreamReader {
public:
    StreamReader(const Archive5& a, VolumeCache& files, Digests& digests) : a_(a), files_(files), digests_(digests) {}
    Bytes read(uint64_t offset, uint32_t size) {
        if (offset > a_.bootstrap.manifest.stream_size || size > a_.bootstrap.manifest.stream_size-offset)
            throw std::runtime_error("Frame outside profile 5 stream");
        Bytes out(size); size_t done = 0; const auto k = a_.bootstrap.manifest.options.data_volumes;
        while (done < size) {
            const auto logical = offset/BlockSize, local = offset%BlockSize;
            const auto n = std::min<uint64_t>(size-done, BlockSize-local);
            if (cached_ != logical) {
                const auto stripe = static_cast<uint32_t>(logical/k), column = static_cast<uint32_t>(logical%k); Digest ignored{};
                if (!read_record_block(a_, files_, false, stripe, column, block_, ignored) ||
                    local_hash(a_, false, stripe, column, block_) != digests_.get(stripe, column))
                    throw std::runtime_error("Data blocks are damaged or missing; run repair first");
                cached_ = logical;
            }
            std::copy_n(block_.data()+local, n, out.data()+done); done += n; offset += n;
        }
        return out;
    }
private:
    const Archive5& a_; VolumeCache& files_; Digests& digests_; uint64_t cached_ = UINT64_MAX; Bytes block_;
};
struct IndexScan { Verification result; std::vector<bool> forced; };
IndexScan scan_index(const Archive5& a, VolumeCache& files, ReadProgress* progress = nullptr) {
    IndexScan scan; auto& result = scan.result; result.metadata_issues = a.metadata_issues;
    const auto& b = a.bootstrap; const auto k = b.manifest.options.data_volumes, m = b.manifest.options.recovery_volumes;
    Bytes block; std::vector<blake3_hasher> states(k+m); std::vector<bool> local_bad(k+m, false);
    std::vector<uint16_t> bad_counts(b.layout.index_stripes, 0); scan.forced.assign(k+m, false);
    std::vector<bool> missing(b.layout.index_stripes*(k+m), false);
    for (auto& h : states) blake3_hasher_init(&h);
    const auto logical_bytes = uint64_t(b.layout.hash_pages)*BlockSize+b.layout.root_size;
    // Check index storage first. It is independently recoverable using its local
    // checksums; the replicated root and page hashes authenticate the result.
    for (uint32_t stripe = 0; stripe < b.layout.index_stripes; ++stripe) {
        for (uint32_t s = 0; s < k+m; ++s) {
            Digest local{};
            bool valid = read_record_block(a, files, true, stripe, s, block, local);
            if (valid) {
                blake3_hasher_update(&states[s], block.data(), block.size()); blake3_hasher_update(&states[s], local.data(), local.size());
                valid = local_hash(a, true, stripe, s, block) == local;
                const auto position = (uint64_t(stripe)*k+s)*BlockSize;
                if (s < k && position+BlockSize > logical_bytes) {
                    auto first = position < logical_bytes ? logical_bytes-position : 0;
                    if (std::any_of(block.begin()+static_cast<ptrdiff_t>(first), block.end(), [](uint8_t v) { return v != 0; })) valid = false;
                }
            }
            if (!valid) { ++bad_counts[stripe]; local_bad[s] = true; missing[uint64_t(stripe)*(k+m)+s] = true; }
            if (progress) progress->advance(PagedRecordSize);
        }
    }
    if (std::any_of(bad_counts.begin(), bad_counts.end(), [&](uint16_t bad) { return bad > m; })) {
        for (auto bad : bad_counts) { result.bad_blocks += bad; if (bad > m) ++result.unrecoverable_stripes; }
        return scan;
    }
    if (std::any_of(local_bad.begin(), local_bad.end(), [](bool bad) { return bad; })) {
        // First repair ordinary checksum erasures in memory. Otherwise a single
        // ordinary error could hide a forged-but-self-consistent record in the
        // same volume from aggregate authentication.
        for (auto& h : states) blake3_hasher_init(&h);
        IndexReader local_repair(a, files);
        for (uint32_t stripe = 0; stripe < b.layout.index_stripes; ++stripe) {
            auto blocks = local_repair.recover(stripe);
            for (uint32_t s = 0; s < k+m; ++s) {
                const auto digest = local_hash(a, true, stripe, s, blocks[s]);
                blake3_hasher_update(&states[s], blocks[s].data(), blocks[s].size());
                blake3_hasher_update(&states[s], digest.data(), digest.size());
            }
        }
    }
    for (uint32_t s = 0; s < k+m; ++s) {
        Digest actual{}; blake3_hasher_finalize(&states[s], actual.data(), actual.size());
        if (actual != b.index_volume_hashes[s]) {
            // All local checksums can be forged together. The authenticated
            // bootstrap still identifies that volume's index region as suspect.
            scan.forced[s] = true;
            for (size_t stripe = 0; stripe < bad_counts.size(); ++stripe)
                if (!missing[stripe*(k+m)+s]) ++bad_counts[stripe];
        }
    }
    for (auto bad : bad_counts) { result.bad_blocks += bad; if (bad > m) ++result.unrecoverable_stripes; }
    return scan;
}
Verification scan(const Archive5& a, uint32_t requested = 0, ReadProgress* progress = nullptr) {
    const auto& b = a.bootstrap; const auto k = b.manifest.options.data_volumes, m = b.manifest.options.recovery_volumes;
    if (progress) progress->start("storage", (b.layout.index_stripes + b.layout.data_stripes) * (k+m) * PagedRecordSize);
    VolumeCache files(a, File::Mode::Read); auto index_scan = scan_index(a, files, progress); auto result = index_scan.result;
    if (result.unrecoverable_stripes) return result;
    { IndexReader index(a, files, &index_scan.forced); Digests digests(a, index); digests.verify_pages(); }
    files.clear();
    const auto work = b.layout.data_stripes * (k+m) * BlockSize;
    const size_t workers = std::min({size_t(4), size_t(k+m), size_t(requested ? requested : std::max(1U, std::thread::hardware_concurrency())),
        size_t((work+1024*1024-1)/(1024*1024))});
    // Worst case is ~34 MiB at the 1 TiB content limit (K=1). No per-block
    // digest table is materialized; each reader caches at most 16 index pages.
    std::vector<std::atomic<uint16_t>> missing(b.layout.data_stripes);
    for (auto& count : missing) count.store(0, std::memory_order_relaxed);
    std::atomic<uint32_t> next{0}; std::atomic<uint64_t> bad_data{0}; std::atomic<bool> stopped{false};
    std::exception_ptr error; std::mutex error_mutex;
    auto run = [&] {
        try {
            VolumeCache worker_files(a, File::Mode::Read, workers); IndexReader index(a, worker_files, &index_scan.forced); Digests digests(a, index);
            Bytes block(PagedRecordSize);
            while (!stopped.load(std::memory_order_relaxed)) {
                const auto column = next.fetch_add(1); if (column >= k+m) break;
                File file(a.directory/configurable_volume_name(column >= k, column >= k ? column-k : column), File::Mode::Read, true);
                for (uint32_t stripe = 0; stripe < b.layout.data_stripes; ++stripe) {
                    check_cancel(); if (stopped.load(std::memory_order_relaxed)) return;
                    block.resize(PagedRecordSize); Digest local{};
                    bool valid = file.read(record_offset(a, false, stripe), block.data(), block.size());
                    if (valid) std::copy_n(block.data()+BlockSize, 32, local.data());
                    block.resize(BlockSize); const auto expected = digests.get(stripe, column);
                    valid = valid && local == expected && local_hash(a, false, stripe, column, block) == expected;
                    if (!valid) { missing[stripe].fetch_add(1, std::memory_order_relaxed); if (column < k) bad_data.fetch_add(1, std::memory_order_relaxed); }
                    if (progress) progress->advance(PagedRecordSize);
                }
            }
        } catch (...) {
            { std::lock_guard lock(error_mutex); if (!error) error = std::current_exception(); }
            stopped.store(true, std::memory_order_relaxed);
        }
    };
    std::vector<std::jthread> threads;
    try { for (size_t i = 1; i < workers; ++i) threads.emplace_back(run); }
    catch (...) { stopped.store(true); throw; }
    run(); threads.clear(); if (error) std::rethrow_exception(error);
    result.bad_data_blocks += bad_data.load();
    for (const auto& count : missing) { const auto bad = count.load(); result.bad_blocks += bad; if (bad > m) ++result.unrecoverable_stripes; }
    return result;
}
void verify_contents(Archive5& a, const ArchiveKeys* keys, uint32_t threads = 0, ReadProgress* progress = nullptr) {
    VolumeCache files(a, File::Mode::Read); IndexReader index(a, files); Digests digests(a, index); StreamReader stream(a, files, digests);
    RecordReader read = [&](uint64_t offset, uint32_t size) { return stream.read(offset, size); };
    unlock_index(a.bootstrap.manifest, read, keys); verify_private_records(a.bootstrap.manifest, read, keys, threads, progress);
}
void write_record(const Archive5& out, VolumeCache& files, bool index, uint32_t stripe, uint32_t column, const Bytes& block) {
    auto& file = files.get(column); const auto offset = record_offset(out, index, stripe);
    file.write(offset, block.data(), block.size()); auto digest = local_hash(out, index, stripe, column, block);
    file.write(offset+BlockSize, digest.data(), digest.size());
}
}
bool uses_paged_profile(const fs::path& directory) {
    require_directory(directory); File sidecar(directory/"manifest.rzm", File::Mode::Read, true); Bytes bytes(8);
    if (sidecar.read(0, bytes.data(), bytes.size()) && magic(bytes, "RZIDX005")) return true;
    size_t count = 0;
    for (const auto& entry : fs::directory_iterator(directory)) {
        if (entry.path().extension() != ".rzv" && entry.path().extension() != ".rzr") continue;
        if (++count > 2 * MaxPhysicalVolumes) throw std::runtime_error("Too many physical volumes");
        File file(entry.path());
        if (file.read(0, bytes.data(), bytes.size()) && magic(bytes, "RZVOL005")) return true;
        if (file.size() >= HeaderSize && file.read(file.size()-HeaderSize, bytes.data(), bytes.size()) && magic(bytes, "RZEND005")) return true;
    }
    return false;
}
ConfigurableManifest list_paged_archive(const fs::path& directory, const Password* password) {
    auto a = load(directory);
    if (!a.bootstrap.manifest.security.encrypted || password) {
        auto keys = authenticate_manifest(a.bootstrap.manifest, password);
        try {
            VolumeCache files(a, File::Mode::Read); IndexReader index(a, files); Digests digests(a, index); StreamReader stream(a, files, digests);
            unlock_index(a.bootstrap.manifest, [&](uint64_t o, uint32_t n) { return stream.read(o, n); }, keys ? &*keys : nullptr);
        } catch (const std::runtime_error& error) {
            const std::string message = error.what();
            if (message.find("run repair first") == std::string::npos && message.find("Unrecoverable profile 5 index") == std::string::npos) throw;
            a.bootstrap.manifest.directory_damaged = true;
        }
    }
    return a.bootstrap.manifest;
}
Verification verify_paged_archive(const fs::path& directory, const Password* password, ReadProgress* progress) {
    auto a = load(directory); auto keys = password ? authenticate_manifest(a.bootstrap.manifest, password) : std::optional<ArchiveKeys>();
    auto result = scan(a, 0, progress);
    if (result.exit_code() == 0 && (!a.bootstrap.manifest.security.encrypted || password)) verify_contents(a, keys ? &*keys : nullptr, 0, progress);
    return result;
}
void verify_paged_created(const fs::path& directory, const Bytes& expected_bootstrap, const ArchiveKeys* keys, uint32_t threads) {
    auto a = load(directory);
    if (a.encoded != expected_bootstrap || scan(a, threads).exit_code() != 0) throw std::runtime_error("Created profile 5 storage verification failed");
    verify_contents(a, keys, threads);
}
void repair_paged_archive(const fs::path& directory, const fs::path& output) {
    auto a = load(directory); require_outside(a.directory, output); Staging stage(output);
    Archive5 out = a; out.directory = stage.path;
    const auto& b = a.bootstrap; const auto k = b.manifest.options.data_volumes, m = b.manifest.options.recovery_volumes;
    for (uint32_t s = 0; s < k+m; ++s) {
        File file(stage.path/configurable_volume_name(s >= k, s >= k ? s-k : s), File::Mode::New);
        file.resize(2*HeaderSize+2*a.encoded.size()+payload_size(b));
    }
    VolumeCache input(a, File::Mode::Read, 2), destination(out, File::Mode::Update, 2);
    auto index_scan = scan_index(a, input);
    if (index_scan.result.unrecoverable_stripes) throw std::runtime_error("Unrecoverable profile 5 index stripe");
    IndexReader index(a, input, &index_scan.forced); Digests digests(a, index); digests.verify_pages();
    ReedSolomon rs(k, m, 2);
    for (uint32_t stripe = 0; stripe < b.layout.index_stripes; ++stripe) {
        auto blocks = index.recover(stripe);
        for (uint32_t s = 0; s < k+m; ++s) write_record(out, destination, true, stripe, s, blocks[s]);
    }
    for (uint32_t stripe = 0; stripe < b.layout.data_stripes; ++stripe) {
        std::vector<Bytes> blocks(k+m); std::vector<int> missing;
        for (uint32_t s = 0; s < k+m; ++s) {
            Digest local{};
            if (!read_record_block(a, input, false, stripe, s, blocks[s], local) || local_hash(a, false, stripe, s, blocks[s]) != digests.get(stripe, s)) {
                missing.push_back(static_cast<int>(s)); std::fill(blocks[s].begin(), blocks[s].end(), 0);
            }
        }
        if (missing.size() > m) throw std::runtime_error("Unrecoverable profile 5 data stripe");
        rs.decode(blocks, missing);
        for (uint32_t s = 0; s < k+m; ++s) {
            if (local_hash(a, false, stripe, s, blocks[s]) != digests.get(stripe, s)) throw std::runtime_error("Reconstructed profile 5 data failed authentication");
            write_record(out, destination, false, stripe, s, blocks[s]);
        }
    }
    destination.clear(); input.clear();
    for (uint32_t s = 0; s < k+m; ++s) {
        File file(stage.path/configurable_volume_name(s >= k, s >= k ? s-k : s), File::Mode::Update);
        auto front = make_paged_header(b, s >= k, s >= k ? s-k : s, false), back = make_paged_header(b, s >= k, s >= k ? s-k : s, true);
        file.write(0, front.data(), front.size()); file.write(HeaderSize, a.encoded.data(), a.encoded.size());
        const auto tail = HeaderSize+a.encoded.size()+payload_size(b);
        file.write(tail, a.encoded.data(), a.encoded.size()); file.write(tail+a.encoded.size(), back.data(), back.size()); file.sync();
    }
    { File sidecar(stage.path/"manifest.rzm", File::Mode::New); sidecar.append(a.encoded); auto h = hash(a.encoded); sidecar.append(h.data(), h.size()); sidecar.sync(); }
    if (verify_paged_archive(stage.path).exit_code() != 0) throw std::runtime_error("Repaired profile 5 verification failed");
    stage.commit();
}
ExtractionReport extract_paged_archive(const fs::path& directory, const fs::path& output, const Password* password, bool restore_attributes, ReadProgress* progress) {
    auto a = load(directory); require_outside(a.directory, output); auto keys = authenticate_manifest(a.bootstrap.manifest, password);
    VolumeCache files(a, File::Mode::Read); IndexReader index(a, files); Digests digests(a, index); StreamReader stream(a, files, digests);
    RecordReader read = [&](uint64_t o, uint32_t n) { return stream.read(o, n); };
    auto& manifest = a.bootstrap.manifest; unlock_index(manifest, read, keys ? &*keys : nullptr);
    Staging staging(output); ExtractionReport report; DecompressionPool pool(manifest.uuid, keys ? &*keys : nullptr);
    if (progress) progress->contents("extracting", manifest.entries);
    struct Rollback {
        const fs::path& root; const std::vector<Entry>& entries; bool complete = false;
        ~Rollback() { if (!complete) reset_metadata_for_cleanup(root, entries); }
    } rollback{staging.path, manifest.entries};
    for (const auto& entry : manifest.entries) {
        check_cancel(); auto path = staging.path/entry.path;
        if (entry.directory) {
            if (!fs::create_directory(path)) throw std::runtime_error("Directory name collision");
            fs::permissions(path, fs::perms::owner_all); continue;
        }
        File file(path, File::Mode::New); blake3_hasher digest; blake3_hasher_init(&digest);
        WipeMemoryOnExit clear_digest(&digest, sizeof(digest), keys.has_value());
        auto consume = [&] {
            auto job = pool.take(); file.append(job->plain); blake3_hasher_update(&digest, job->plain.data(), job->plain.size());
            if (progress) progress->advance(job->plain.size());
        };
        for (const auto& frame : entry.frames) {
            if (pool.full()) consume();
            auto job = std::make_unique<DecompressionJob>(keys.has_value()); job->offset = frame.offset; job->plain_size = frame.plain;
            job->record = read(frame.offset, frame.stored); pool.submit(std::move(job));
        }
        while (!pool.empty()) consume();
        Digest actual{}; blake3_hasher_finalize(&digest, actual.data(), 32);
        if (actual != entry.digest) throw std::runtime_error("Extracted file failed BLAKE3 verification: "+entry.path);
        file.sync();
        if (progress) progress->file_completed();
    }
    const bool attributes = manifest.security.metadata && restore_attributes;
    if (attributes && progress) progress->phase("attributes");
    if (attributes) for (auto entry = manifest.entries.rbegin(); entry != manifest.entries.rend(); ++entry) {
        auto bytes = read_metadata(manifest, *entry, read, keys ? &*keys : nullptr); WipeOnExit wipe_bytes(bytes, keys.has_value());
        restore_metadata(staging.path/entry->path, entry->path, entry->directory, bytes, report);
    }
    if (progress) progress->phase("publishing");
    staging.commit(attributes); rollback.complete = true; return report;
}
}
