#include "configurable.hpp"
#include "protected.hpp"
#include "compression_progress.hpp"
#include "recovery_pool.hpp"
#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <mutex>
#include <thread>

namespace rz {
namespace {
struct Archive2 {
    fs::path directory;
    ConfigurableManifest manifest;
    Bytes encoded;
    Digest digest{};
    uint64_t metadata_issues = 0;
};
std::optional<Bytes> read_bytes(const File& file, uint64_t offset, size_t size) {
    Bytes bytes(size);
    if (!file.read(offset, bytes.data(), size)) return std::nullopt;
    return bytes;
}
bool magic(const Bytes& b, const char* value) { return b.size() >= 8 && std::memcmp(b.data(), value, 8) == 0; }
std::optional<ConfigurableHeader> read_header(const File& f, bool footer) {
    if (!f.exists() || f.size() < HeaderSize) return std::nullopt;
    auto b = read_bytes(f, footer ? f.size() - HeaderSize : 0, HeaderSize);
    if (!b) return std::nullopt;
    try {
        auto h = parse_configurable_header(*b, footer);
        if (footer && f.size() != 2 * HeaderSize + 2 * h.manifest_size + h.payload_size) return std::nullopt;
        return h;
    } catch (const std::runtime_error&) { return std::nullopt; }
}
ConfigurableHeader header_for(const Archive2& a, bool parity, uint32_t volume) {
    return {a.manifest.uuid, parity, volume, a.encoded.size(), a.manifest.payload_size(parity, volume), a.digest, a.manifest.profile};
}
bool metadata_ok(const File& file, const ConfigurableHeader& h, const Bytes& manifest) {
    if (!file.exists() || file.size() != 2 * HeaderSize + 2 * h.manifest_size + h.payload_size) return false;
    auto front = read_bytes(file, 0, HeaderSize), back = read_bytes(file, file.size() - HeaderSize, HeaderSize);
    if (!front || !back || *front != make_header(h, false) || *back != make_header(h, true)) return false;
    for (auto offset : {uint64_t(HeaderSize), HeaderSize + h.manifest_size + h.payload_size}) {
        auto copy = read_bytes(file, offset, manifest.size());
        if (!copy || *copy != manifest) return false;
    }
    return true;
}
Archive2 load(const fs::path& directory) {
    require_directory(directory); Archive2 a; a.directory = fs::canonical(directory); bool found = false;
    auto consider = [&](Bytes bytes) {
        if (magic(bytes, "RZIDX001")) {
            try { (void)parse_manifest(bytes); } catch (const std::runtime_error&) { return; }
            throw std::runtime_error("Mixed archive IDs or profiles");
        }
        std::optional<ConfigurableManifest> m;
        try { m = parse_configurable_manifest(bytes); } catch (const std::runtime_error&) { return; }
        auto digest = hash(bytes);
        if (found && digest != a.digest) throw std::runtime_error("Mixed archive IDs or conflicting manifests");
        if (!found) { a.manifest = std::move(*m); a.encoded = std::move(bytes); a.digest = digest; found = true; }
    };
    File sidecar(a.directory / "manifest.rzm", File::Mode::Read, true);
    if (sidecar.exists() && sidecar.size() >= 32 && sidecar.size() <= MaxManifest + 32) {
        auto bytes = read_bytes(sidecar, 0, static_cast<size_t>(sidecar.size()));
        if (bytes) {
            Digest expected{}; std::copy(bytes->end() - 32, bytes->end(), expected.begin()); bytes->resize(bytes->size() - 32);
            if (hash(*bytes) == expected) consider(std::move(*bytes));
        }
    }
    std::vector<std::pair<fs::path, ConfigurableHeader>> hints;
    std::vector<fs::path> candidates;
    for (const auto& e : fs::directory_iterator(a.directory)) {
        if (e.path().extension() != ".rzv" && e.path().extension() != ".rzr") continue;
        if (candidates.size() >= 2 * MaxPhysicalVolumes) throw std::runtime_error("Too many physical volumes");
        candidates.push_back(e.path()); File file(e.path());
        for (bool footer : {false, true}) {
            auto h = read_header(file, footer); if (!h) continue;
            hints.emplace_back(e.path(), *h);
            if (found) continue;
            for (auto offset : {uint64_t(HeaderSize), HeaderSize + h->manifest_size + h->payload_size}) {
                auto bytes = read_bytes(file, offset, static_cast<size_t>(h->manifest_size));
                if (bytes && hash(*bytes) == h->manifest_hash) consider(std::move(*bytes));
            }
        }
    }
    if (!found) throw std::runtime_error("No valid manifest remains; recovery parameters are unavailable");
    std::set<std::string> names;
    for (bool parity : {false, true})
        for (uint32_t i = 0; i < a.manifest.volume_count(parity); ++i) names.insert(configurable_volume_name(parity, i));
    for (const auto& path : candidates)
        if (!names.contains(path.filename().string())) throw std::runtime_error("Unexpected volume filename: " + path.filename().string());
    for (const auto& [path, h] : hints) {
        if (h.uuid != a.manifest.uuid || h.manifest_hash != a.digest || h.profile != a.manifest.profile) throw std::runtime_error("Mixed archive IDs or conflicting volume headers");
        if (h.volume >= a.manifest.volume_count(h.parity) || path.filename() != configurable_volume_name(h.parity, h.volume) ||
            h.manifest_size != a.encoded.size() || h.payload_size != a.manifest.payload_size(h.parity, h.volume))
            throw std::runtime_error("Volume identity or geometry conflicts with manifest");
    }
    auto expected = a.encoded; expected.insert(expected.end(), a.digest.begin(), a.digest.end());
    auto actual = sidecar.exists() && sidecar.size() == expected.size() ? read_bytes(sidecar, 0, expected.size()) : std::nullopt;
    if (!actual || *actual != expected) ++a.metadata_issues;
    for (bool parity : {false, true}) {
        for (uint32_t i = 0; i < a.manifest.volume_count(parity); ++i) {
            File file(a.directory / configurable_volume_name(parity, i), File::Mode::Read, true);
            if (!metadata_ok(file, header_for(a, parity, i), a.encoded)) ++a.metadata_issues;
        }
    }
    return a;
}
// Bounded open-file count, independent of archive size and user volume size.
class FileCache {
public:
    FileCache(fs::path root, File::Mode mode, std::string suffix = "") : root_(std::move(root)), mode_(mode), suffix_(std::move(suffix)) {}
    File& get(bool parity, uint32_t volume) {
        auto name = configurable_volume_name(parity, volume) + suffix_;
        auto it = cache_.find(name);
        if (it == cache_.end()) {
            if (cache_.size() == 16) {
                auto oldest = std::min_element(cache_.begin(), cache_.end(), [](const auto& a, const auto& b) { return a.second.age < b.second.age; });
                cache_.erase(oldest);
            }
            it = cache_.emplace(name, Cached{std::make_unique<File>(root_ / name, mode_, mode_ == File::Mode::Read), 0}).first;
        }
        it->second.age = ++age_; return *it->second.file;
    }
    void clear() { cache_.clear(); }
private:
    struct Cached { std::unique_ptr<File> file; uint64_t age; };
    fs::path root_; File::Mode mode_; std::string suffix_; uint64_t age_ = 0;
    std::map<std::string, Cached> cache_;
};
std::vector<int> read_group(const Archive2& a, FileCache& files, uint32_t index, uint64_t data_start, uint64_t parity_start, std::vector<Bytes>& blocks) {
    const auto& g = a.manifest.groups[index]; blocks.assign(g.k + g.m, Bytes(BlockSize)); std::vector<int> missing;
    for (uint32_t s = 0; s < g.k + g.m; ++s) {
        bool parity = s >= g.k; auto logical = parity ? parity_start + s - g.k : data_start + s;
        auto count = a.manifest.volume_count(parity);
        auto& file = files.get(parity, static_cast<uint32_t>(logical % count));
        auto& b = blocks[s];
        bool ok = file.read(HeaderSize + a.encoded.size() + (logical / count) * BlockSize, b.data(), b.size());
        if (!ok || block_hash_v2(a.manifest.uuid, index, s, b) != g.hashes[s]) {
            missing.push_back(static_cast<int>(s)); std::fill(b.begin(), b.end(), 0);
        }
    }
    return missing;
}
Verification scan(const Archive2& a) {
    Verification result; result.metadata_issues = a.metadata_issues;
    FileCache files(a.directory, File::Mode::Read); std::vector<Bytes> blocks;
    uint64_t data_start = 0, parity_start = 0;
    for (uint32_t i = 0; i < a.manifest.groups.size(); ++i) {
        const auto& g = a.manifest.groups[i]; auto missing = read_group(a, files, i, data_start, parity_start, blocks);
        result.bad_blocks += missing.size();
        result.bad_data_blocks += std::count_if(missing.begin(), missing.end(), [&](int s) { return s < static_cast<int>(g.k); });
        if (missing.size() > g.m) ++result.unrecoverable_stripes;
        data_start += g.k; parity_start += g.m;
    }
    return result;
}
void append_block(FileCache& files, const ConfigurableManifest& m, bool parity, uint64_t logical, const Bytes& bytes) {
    files.get(parity, static_cast<uint32_t>(logical % m.volume_count(parity))).append(bytes);
}
void write_sidecar(const fs::path& directory, const Archive2& a) {
    File file(directory / "manifest.rzm", File::Mode::New);
    file.append(a.encoded); file.append(a.digest.data(), a.digest.size()); file.sync();
}
// Each task owns its input/output files. Only profile 4 opts into concurrent
// finalization; cap IO fan-out and join all workers before staging can be removed.
size_t write_volumes(const fs::path& directory, const Archive2& a, uint32_t requested) {
    const auto data = a.manifest.volume_count(false), count = data + a.manifest.volume_count(true);
    const auto bytes = (a.manifest.data_blocks + a.manifest.recovery_blocks) * BlockSize;
    const auto desired = requested ? requested : std::max(1U, std::thread::hardware_concurrency());
    const auto workers = a.manifest.profile == 4
        ? std::min({uint64_t(count), uint64_t(desired), uint64_t(4), (bytes + 1024 * 1024 - 1) / (1024 * 1024)}) : 1;
    std::atomic<uint32_t> next{0}; std::atomic<bool> stopped{false};
    std::mutex mutex; std::exception_ptr error;
    auto run = [&] {
        try {
            while (!stopped.load()) {
                const auto index = next.fetch_add(1); if (index >= count) break;
                const bool parity = index >= data; const auto volume = parity ? index - data : index;
                auto name = configurable_volume_name(parity, volume); auto h = header_for(a, parity, volume);
                File file(directory / name, File::Mode::New); file.append(make_header(h, false)); file.append(a.encoded);
                File payload(directory / (name + ".tmp"));
                Bytes block(BlockSize);
                for (uint64_t offset = 0; offset < h.payload_size; offset += BlockSize) {
                    if (stopped.load()) return;
                    if (!payload.read(offset, block.data(), block.size())) throw std::runtime_error("Truncated source during copy");
                    file.append(block);
                }
                file.append(a.encoded); file.append(make_header(h, true)); file.sync(); fs::remove(directory / (name + ".tmp"));
            }
        } catch (...) {
            { std::lock_guard lock(mutex); if (!error) error = std::current_exception(); }
            stopped.store(true);
        }
    };
    std::vector<std::jthread> threads;
    try { for (size_t i = 1; i < workers; ++i) threads.emplace_back(run); }
    catch (...) { stopped.store(true); throw; }
    run(); threads.clear();
    if (error) std::rethrow_exception(error);
    return workers;
}
class StreamReader {
public:
    explicit StreamReader(const Archive2& a) : a_(a), files_(a.directory, File::Mode::Read) {}
    Bytes read(uint64_t offset, uint32_t size) {
        if (offset > a_.manifest.stream_size || size > a_.manifest.stream_size - offset) throw std::runtime_error("Frame outside stream");
        Bytes out(size); size_t done = 0; auto count = a_.manifest.volume_count(false);
        while (done < size) {
            auto block = offset / BlockSize, local = offset % BlockSize;
            auto n = static_cast<size_t>(std::min<uint64_t>(size - done, BlockSize - local));
            auto& file = files_.get(false, static_cast<uint32_t>(block % count));
            if (a_.manifest.profile >= 3) {
                if (cached_block_ != block) {
                    const auto width = a_.manifest.profile == 4 ? a_.manifest.options.data_volumes : MaxDataShards;
                    uint32_t group = static_cast<uint32_t>(block / width), column = static_cast<uint32_t>(block % width);
                    if (!file.read(HeaderSize + a_.encoded.size() + (block / count) * BlockSize, cached_.data(), cached_.size()) ||
                        block_hash_v2(a_.manifest.uuid, group, column, cached_) != a_.manifest.groups.at(group).hashes.at(column))
                        throw std::runtime_error("Data blocks are damaged or missing; run repair first");
                    cached_block_ = block;
                }
                std::copy_n(cached_.data() + local, n, out.data() + done);
            } else if (!file.read(HeaderSize + a_.encoded.size() + (block / count) * BlockSize + local, out.data() + done, n)) {
                throw std::runtime_error("Missing frame bytes; run repair first");
            }
            offset += n; done += n;
        }
        return out;
    }
private:
    const Archive2& a_; FileCache files_;
    uint64_t cached_block_ = UINT64_MAX;
    Bytes cached_ = Bytes(BlockSize);
};
}
bool uses_configurable_profile(const fs::path& directory) {
    require_directory(directory);
    File sidecar(directory / "manifest.rzm", File::Mode::Read, true); Bytes b(8);
    if (sidecar.read(0, b.data(), b.size()) && (magic(b, "RZIDX002") || magic(b, "RZIDX003") || magic(b, "RZIDX004"))) return true;
    for (const auto& e : fs::directory_iterator(directory)) {
        if (e.path().extension() != ".rzv" && e.path().extension() != ".rzr") continue;
        File file(e.path());
        if (file.read(0, b.data(), b.size()) && (magic(b, "RZVOL002") || magic(b, "RZVOL003") || magic(b, "RZVOL004"))) return true;
        if (file.size() >= HeaderSize && file.read(file.size() - HeaderSize, b.data(), b.size()) && (magic(b, "RZEND002") || magic(b, "RZEND003") || magic(b, "RZEND004"))) return true;
    }
    return false;
}
void create_configurable_archive(const InputPlan& plan, const fs::path& output, const RecoveryOptions& options, const SecurityOptions* security, bool report_progress, uint32_t threads) {
    if (security && security->generate_key_file) {
        if (!security->encrypt || !security->password || !security->password->from_key_file) throw KeyFileError();
        if (fs::exists(fs::symlink_status(recovery_key_path(output)))) throw std::runtime_error("Recovery key file already exists");
    }
    validate_options(options); Staging staging(output); auto spool = staging.path / "compressed.tmp";
    CompressionProgress progress(plan.root, plan.paths, report_progress);
    CreationTiming timing; const auto started = TimingClock::now(); auto phase_start = started;
    Archive2 a; std::optional<ArchiveKeys> keys;
    if (security) {
        auto protected_input = pack_protected(plan, spool, *security, &progress, threads);
        keys = std::move(protected_input.keys);
        a.manifest = configure(std::move(protected_input.packed), options, &protected_input.security);
    } else {
        Manifest packed; packed.uuid = random_uuid(); pack(plan.root, plan.paths, spool, packed, &progress, threads);
        a.manifest = configure(std::move(packed), options);
    }
    auto& m = a.manifest; File stream(spool);
    timing.packing = elapsed_ns(phase_start); phase_start = TimingClock::now();
    progress.phase("recovery");
    for (bool parity : {false, true})
        for (uint32_t v = 0; v < m.volume_count(parity); ++v) { File file(staging.path / (configurable_volume_name(parity, v) + ".tmp"), File::Mode::New); }
    FileCache payloads(staging.path, File::Mode::Append, ".tmp");
    RecoveryLimits recovery_limits{}; size_t peak_jobs = 0;
    {
        RecoveryPool pool(stream, m.stream_size, m.uuid, m.groups, threads, m.profile == 4);
        recovery_limits = pool.limits();
        auto commit_next = [&] {
            auto job = pool.take();
            timing.work.read += job->timing.read; timing.work.encode += job->timing.encode; timing.work.hash += job->timing.hash;
            const auto write_start = TimingClock::now();
            m.groups[job->index].hashes = std::move(job->hashes);
            for (uint32_t s = 0; s < job->k + job->m; ++s)
                append_block(payloads, m, s >= job->k, s < job->k ? job->data_start + s : job->parity_start + s - job->k, job->blocks[s]);
            timing.payload_write += elapsed_ns(write_start);
        };
        for (size_t i = 0; i < m.groups.size(); ++i) {
            if (pool.full()) commit_next();
            pool.submit_next();
        }
        while (!pool.empty()) commit_next();
        peak_jobs = pool.peak_jobs();
    }
    payloads.clear(); timing.recovery = elapsed_ns(phase_start); phase_start = TimingClock::now();
    if (keys) sign_manifest(m, *keys);
    a.encoded = serialize(m); a.digest = hash(a.encoded); (void)parse_configurable_manifest(a.encoded);
    timing.index = elapsed_ns(phase_start); phase_start = TimingClock::now();
    progress.phase("writing");
    timing.volume_workers = write_volumes(staging.path, a, threads);
    fs::remove(spool); write_sidecar(staging.path, a);
    timing.volume_write = elapsed_ns(phase_start); phase_start = TimingClock::now();
    progress.phase("verifying");
    if (verify_configurable_archive(staging.path).exit_code() != 0) throw std::runtime_error("Created output verification failed");
    timing.verify = elapsed_ns(phase_start); phase_start = TimingClock::now();
    if (security && security->generate_key_file) {
        auto key_file = staging.path / ".recovery-key";
        write_key_file(key_file, m.uuid, *security->password);
        staging.commit_with_key(key_file);
    } else staging.commit();
    progress.phase("completed");
    timing.publish = elapsed_ns(phase_start);
    if (report_progress) timing.report(elapsed_ns(started), progress.compression_microseconds(),
                                      recovery_limits.workers, peak_jobs, recovery_limits.estimated_bytes);
}
ConfigurableManifest list_configurable_archive(const fs::path& directory, const Password* password) {
    auto a = load(directory);
    if (a.manifest.profile >= 3 && (!a.manifest.security.encrypted || password)) {
        auto keys = authenticate_manifest(a.manifest, password); StreamReader stream(a);
        try {
            unlock_index(a.manifest, [&](uint64_t o, uint32_t n) { return stream.read(o, n); }, keys ? &*keys : nullptr);
        } catch (const std::runtime_error& error) {
            // Preserve a repair entry point even when automatic key-file unlock
            // finds that the RS-protected private index needs reconstruction.
            if (std::string(error.what()).find("run repair first") == std::string::npos) throw;
            a.manifest.directory_damaged = true;
        }
    }
    return a.manifest;
}
Verification verify_configurable_archive(const fs::path& directory, const Password* password) {
    auto a = load(directory);
    auto keys = password ? authenticate_manifest(a.manifest, password) : std::optional<ArchiveKeys>();
    auto result = scan(a);
    if (result.exit_code() == 0 && a.manifest.profile >= 3 && (!a.manifest.security.encrypted || password)) {
        StreamReader stream(a);
        RecordReader read = [&](uint64_t o, uint32_t n) { return stream.read(o, n); };
        unlock_index(a.manifest, read, keys ? &*keys : nullptr);
        verify_private_records(a.manifest, read, keys ? &*keys : nullptr);
    }
    return result;
}
void repair_configurable_archive(const fs::path& directory, const fs::path& output) {
    auto a = load(directory); require_outside(a.directory, output); Staging staging(output); const auto& m = a.manifest;
    for (bool parity : {false, true}) {
        for (uint32_t v = 0; v < m.volume_count(parity); ++v) {
            File file(staging.path / configurable_volume_name(parity, v), File::Mode::New);
            file.append(make_header(header_for(a, parity, v), false)); file.append(a.encoded);
        }
    }
    FileCache input(a.directory, File::Mode::Read), out(staging.path, File::Mode::Append);
    std::vector<Bytes> blocks; uint64_t data_start = 0, parity_start = 0;
    for (uint32_t i = 0; i < m.groups.size(); ++i) {
        const auto& g = m.groups[i]; auto missing = read_group(a, input, i, data_start, parity_start, blocks);
        if (missing.size() > g.m) throw std::runtime_error("Unrecoverable stripe: group=" + std::to_string(i));
        ReedSolomon(g.k, g.m, 2).decode(blocks, missing);
        for (uint32_t s = 0; s < g.k + g.m; ++s) {
            if (block_hash_v2(m.uuid, i, s, blocks[s]) != g.hashes[s]) throw std::runtime_error("Reconstructed block failed BLAKE3 verification");
            append_block(out, m, s >= g.k, s < g.k ? data_start + s : parity_start + s - g.k, blocks[s]);
        }
        data_start += g.k; parity_start += g.m;
    }
    out.clear();
    for (bool parity : {false, true}) {
        for (uint32_t v = 0; v < m.volume_count(parity); ++v) {
            File file(staging.path / configurable_volume_name(parity, v), File::Mode::Append);
            file.append(a.encoded); file.append(make_header(header_for(a, parity, v), true)); file.sync();
        }
    }
    write_sidecar(staging.path, a);
    if (verify_configurable_archive(staging.path).exit_code() != 0) throw std::runtime_error("Repaired output verification failed");
    staging.commit();
}
ExtractionReport extract_configurable_archive(const fs::path& directory, const fs::path& output, const Password* password, bool restore_attributes) {
    auto a = load(directory); require_outside(a.directory, output);
    auto keys = authenticate_manifest(a.manifest, password);
    if (scan(a).bad_data_blocks) throw std::runtime_error("Data blocks are damaged or missing; run repair first");
    StreamReader stream(a); RecordReader read = [&](uint64_t o, uint32_t n) { return stream.read(o, n); };
    unlock_index(a.manifest, read, keys ? &*keys : nullptr);
    Staging staging(output); ExtractionReport report;
    struct MetadataRollback {
        const fs::path& root; const std::vector<Entry>& entries; bool complete = false;
        ~MetadataRollback() { if (!complete) reset_metadata_for_cleanup(root, entries); }
    } rollback{staging.path, a.manifest.entries};
    for (const auto& e : a.manifest.entries) {
        check_cancel(); auto path = staging.path / e.path;
        if (e.directory) {
            if (!fs::create_directory(path)) throw std::runtime_error("Directory name collision");
            fs::permissions(path, fs::perms::owner_all); continue;
        }
        File file(path, File::Mode::New); blake3_hasher digest; blake3_hasher_init(&digest);
        for (const auto& frame : e.frames) {
            auto bytes = read_record(a.manifest, read, frame, RecordKind::Content, keys ? &*keys : nullptr);
            file.append(bytes); blake3_hasher_update(&digest, bytes.data(), bytes.size());
            if (keys) wipe(bytes);
        }
        Digest actual{}; blake3_hasher_finalize(&digest, actual.data(), actual.size());
        if (actual != e.digest) throw std::runtime_error("Extracted file failed BLAKE3 verification: " + e.path);
        file.sync();
    }
    bool attributes = a.manifest.profile >= 3 && a.manifest.security.metadata && restore_attributes;
    if (attributes) {
        for (auto entry = a.manifest.entries.rbegin(); entry != a.manifest.entries.rend(); ++entry) {
            auto bytes = read_metadata(a.manifest, *entry, read, keys ? &*keys : nullptr);
            restore_metadata(staging.path / entry->path, entry->path, entry->directory, bytes, report);
            if (keys) wipe(bytes);
        }
    }
    staging.commit(attributes); rollback.complete = true; return report;
}
}
