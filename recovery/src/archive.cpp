#include "archive.hpp"
#include "io.hpp"
#include "inputs.hpp"
#include <algorithm>
#include <array>
#include <memory>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>

namespace rz {
namespace {
using Files = std::array<std::unique_ptr<File>, N>;
constexpr const char* ManifestName = "manifest.rzm";
struct Archive {
    fs::path directory;
    Manifest manifest;
    Bytes encoded;
    Digest digest;
    uint64_t metadata_issues = 0;
};
std::optional<Bytes> read_bytes(const File& file, uint64_t offset, size_t size) {
    Bytes bytes(size);
    if (!file.read(offset, bytes.data(), bytes.size())) return std::nullopt;
    return bytes;
}
std::optional<Header> read_header(const File& file, bool footer) {
    if (!file.exists() || file.size() < HeaderSize) return std::nullopt;
    auto bytes = read_bytes(file, footer ? file.size() - HeaderSize : 0, HeaderSize);
    if (!bytes) return std::nullopt;
    try {
        auto h = parse_header(*bytes, footer);
        if (footer && file.size() != 2 * HeaderSize + 2 * h.manifest_size + h.payload_size) return std::nullopt;
        return h;
    } catch (const std::runtime_error&) { return std::nullopt; }
}
Header header_for(const Archive& a, uint32_t group, uint32_t shard) {
    return {a.manifest.uuid, group, shard, a.encoded.size(), a.manifest.groups[group].span(), a.digest};
}
bool metadata_ok(const File& file, const Header& h, const Bytes& manifest) {
    if (!file.exists() || file.size() != 2 * HeaderSize + 2 * h.manifest_size + h.payload_size) return false;
    auto first = read_bytes(file, 0, HeaderSize);
    auto last = read_bytes(file, file.size() - HeaderSize, HeaderSize);
    if (!first || !last || *first != make_header(h, false) || *last != make_header(h, true)) return false;
    for (auto offset : {uint64_t(HeaderSize), HeaderSize + h.manifest_size + h.payload_size}) {
        auto copy = read_bytes(file, offset, manifest.size());
        if (!copy || *copy != manifest) return false;
    }
    return true;
}
Archive load_archive(const fs::path& directory) {
    require_directory(directory);
    Archive a; a.directory = fs::canonical(directory);
    bool found = false;
    auto consider = [&](Bytes bytes) {
        std::optional<Manifest> candidate;
        try { candidate = parse_manifest(bytes); } catch (const std::runtime_error&) { return; }
        auto digest = hash(bytes);
        if (found && digest != a.digest) throw std::runtime_error("Mixed archive IDs or conflicting manifests");
        if (!found) {
            a.manifest = std::move(*candidate); a.encoded = std::move(bytes); a.digest = digest; found = true;
        }
    };
    File sidecar(a.directory / ManifestName, File::Mode::Read, true);
    if (sidecar.exists() && sidecar.size() >= 32 && sidecar.size() <= MaxManifest + 32) {
        auto bytes = read_bytes(sidecar, 0, static_cast<size_t>(sidecar.size()));
        if (bytes) {
            Digest expected{}; std::copy(bytes->end() - 32, bytes->end(), expected.begin()); bytes->resize(bytes->size() - 32);
            if (hash(*bytes) == expected) consider(std::move(*bytes));
        }
    }
    std::vector<std::pair<fs::path, Header>> hints;
    std::vector<fs::path> candidates;
    for (const auto& e : fs::directory_iterator(a.directory)) {
        auto ext = e.path().extension();
        if (ext != ".rzv" && ext != ".rzr") continue;
        if (candidates.size() >= 4096 * N) throw std::runtime_error("Too many volume files");
        candidates.push_back(e.path());
        File file(e.path());
        for (bool footer : {false, true}) {
            auto h = read_header(file, footer);
            if (!h) continue;
            hints.emplace_back(e.path(), *h);
            // One intact copy bootstraps the set. All remaining copies are checked
            // against it below without reparsing the same file tree dozens of times.
            if (found) continue;
            for (auto offset : {uint64_t(HeaderSize), HeaderSize + h->manifest_size + h->payload_size}) {
                auto bytes = read_bytes(file, offset, static_cast<size_t>(h->manifest_size));
                if (bytes && hash(*bytes) == h->manifest_hash) consider(std::move(*bytes));
            }
        }
    }
    if (!found) throw std::runtime_error("No valid manifest remains; recovery parameters are unavailable");
    std::set<std::string> expected_names;
    for (uint32_t g = 0; g < a.manifest.groups.size(); ++g)
        for (uint32_t s = 0; s < N; ++s) expected_names.insert(volume_name(g, s));
    for (const auto& p : candidates)
        if (!expected_names.count(p.filename().string())) throw std::runtime_error("Unexpected volume filename: " + p.filename().string());
    for (const auto& hint : hints) {
        const auto& h = hint.second;
        if (h.uuid != a.manifest.uuid || h.manifest_hash != a.digest)
            throw std::runtime_error("Mixed archive IDs or conflicting volume headers");
        if (h.group >= a.manifest.groups.size() || hint.first.filename() != volume_name(h.group, h.shard) ||
            h.manifest_size != a.encoded.size() || h.payload_size != a.manifest.groups[h.group].span())
            throw std::runtime_error("Volume identity or geometry conflicts with manifest");
    }
    auto sidecar_bytes = a.encoded;
    sidecar_bytes.insert(sidecar_bytes.end(), a.digest.begin(), a.digest.end());
    auto actual = sidecar.exists() && sidecar.size() == sidecar_bytes.size() ? read_bytes(sidecar, 0, sidecar_bytes.size()) : std::nullopt;
    if (!actual || *actual != sidecar_bytes) ++a.metadata_issues;
    for (uint32_t g = 0; g < a.manifest.groups.size(); ++g) {
        for (uint32_t s = 0; s < N; ++s) {
            File file(a.directory / volume_name(g, s), File::Mode::Read, true);
            if (!metadata_ok(file, header_for(a, g, s), a.encoded)) ++a.metadata_issues;
        }
    }
    return a;
}
Files open_group(const Archive& a, uint32_t group) {
    Files files;
    for (uint32_t i = 0; i < N; ++i) files[i] = std::make_unique<File>(a.directory / volume_name(group, i), File::Mode::Read, true);
    return files;
}
Stripe empty_stripe() {
    Stripe blocks;
    for (auto& b : blocks) b.resize(BlockSize);
    return blocks;
}
std::vector<int> read_stripe(const Archive& a, const Files& files, uint32_t group, uint32_t stripe, Stripe& blocks) {
    const auto& g = a.manifest.groups[group];
    std::vector<int> missing;
    for (uint32_t s = 0; s < N; ++s) {
        auto& b = blocks[s];
        bool ok = files[s]->read(HeaderSize + a.encoded.size() + uint64_t(stripe) * BlockSize, b.data(), b.size());
        if (!ok || block_hash(a.manifest.uuid, group, s, stripe, b) != g.hashes[s * g.stripes + stripe]) {
            missing.push_back(static_cast<int>(s)); std::fill(b.begin(), b.end(), 0);
        }
    }
    return missing;
}
Verification scan(const Archive& a) {
    Verification result; result.metadata_issues = a.metadata_issues;
    auto blocks = empty_stripe();
    for (uint32_t g = 0; g < a.manifest.groups.size(); ++g) {
        auto files = open_group(a, g);
        for (uint32_t stripe = 0; stripe < a.manifest.groups[g].stripes; ++stripe) {
            auto missing = read_stripe(a, files, g, stripe, blocks);
            result.bad_blocks += missing.size();
            result.bad_data_blocks += std::count_if(missing.begin(), missing.end(), [](int i) { return i < static_cast<int>(K); });
            if (missing.size() > M) ++result.unrecoverable_stripes;
        }
    }
    return result;
}
void write_sidecar(const fs::path& directory, const Bytes& manifest) {
    File out(directory / ManifestName, File::Mode::New);
    out.append(manifest); auto digest = hash(manifest); out.append(digest.data(), digest.size()); out.sync();
}
void layout(Manifest& m, uint64_t volume_size) {
    if (volume_size < 1024 * 1024 || volume_size > MaxVolume) throw std::runtime_error("Volume size must be between 1 MiB and 1 GiB");
    uint64_t capacity = (volume_size - 2 * HeaderSize) / BlockSize * BlockSize;
    for (int attempt = 0; attempt < 64; ++attempt) {
        m.groups.clear();
        uint64_t remaining = m.stream_size, hash_bytes = 0;
        do {
            Group g; g.valid = std::min(remaining, capacity * K);
            g.stripes = static_cast<uint32_t>(std::max<uint64_t>(1, (g.valid + K * BlockSize - 1) / (K * BlockSize)));
            hash_bytes += uint64_t(g.stripes) * N * 32;
            if (hash_bytes > MaxManifest || m.groups.size() >= 4096) throw std::runtime_error("Block index exceeds phase-one limit");
            g.hashes.resize(g.stripes * N);
            remaining -= g.valid; m.groups.push_back(std::move(g));
        } while (remaining);
        auto size = serialize(m).size();
        if (2 * size + 2 * HeaderSize + BlockSize > volume_size)
            throw std::runtime_error("Replicated index does not fit volume; increase --volume-size");
        auto available = (volume_size - 2 * size - 2 * HeaderSize) / BlockSize * BlockSize;
        if (available >= capacity) return;
        capacity = available;
    }
    throw std::runtime_error("Volume layout did not converge; increase --volume-size");
}
void write_volume(const fs::path& directory, const Archive& a, uint32_t g, uint32_t s, const fs::path& payload) {
    auto h = header_for(a, g, s);
    File out(directory / volume_name(g, s), File::Mode::New);
    out.append(make_header(h, false)); out.append(a.encoded);
    File source(payload); copy_file_contents(source, out, h.payload_size);
    out.append(a.encoded); out.append(make_header(h, true)); out.sync();
}
// Maps the compressed logical stream into contiguous data-volume extents.
class StreamReader {
public:
    explicit StreamReader(const Archive& a) : archive_(a) {}
    Bytes read(uint64_t offset, uint32_t size) {
        Bytes out(size); size_t done = 0;
        if (offset > archive_.manifest.stream_size || size > archive_.manifest.stream_size - offset)
            throw std::runtime_error("Frame outside stream");
        while (done < size) {
            uint64_t start = 0; uint32_t group = 0;
            for (; group < archive_.manifest.groups.size(); ++group) {
                if (offset < start + archive_.manifest.groups[group].valid) break;
                start += archive_.manifest.groups[group].valid;
            }
            const auto& g = archive_.manifest.groups.at(group);
            auto local = offset - start;
            auto shard = static_cast<uint32_t>(local / g.span()); auto in_shard = local % g.span();
            auto count = static_cast<size_t>(std::min<uint64_t>({size - done, g.span() - in_shard, g.valid - local}));
            File file(archive_.directory / volume_name(group, shard));
            if (!file.read(HeaderSize + archive_.encoded.size() + in_shard, out.data() + done, count))
                throw std::runtime_error("Missing frame bytes; run repair first");
            done += count; offset += count;
        }
        return out;
    }
private:
    const Archive& archive_;
};
}
static void create_from_inputs(const fs::path& source, const InputPaths& paths, const fs::path& output, uint64_t volume_size, uint32_t threads) {
    if (volume_size < 1024 * 1024 || volume_size > MaxVolume) throw std::runtime_error("Volume size must be between 1 MiB and 1 GiB");
    Staging staging(output);
    auto spool = staging.path / "compressed.tmp";
    Manifest m; m.uuid = random_uuid(); pack(source, paths, spool, m, nullptr, threads); layout(m, volume_size);
    ReedSolomon rs; auto blocks = empty_stripe(); File stream(spool);
    uint64_t stream_start = 0;
    for (uint32_t group = 0; group < m.groups.size(); ++group) {
        auto& g = m.groups[group]; Files payloads;
        for (uint32_t s = 0; s < N; ++s)
            payloads[s] = std::make_unique<File>(staging.path / (volume_name(group, s) + ".tmp"), File::Mode::New);
        for (uint32_t stripe = 0; stripe < g.stripes; ++stripe) {
            for (uint32_t s = 0; s < K; ++s) {
                auto& b = blocks[s]; std::fill(b.begin(), b.end(), 0);
                uint64_t local = s * g.span() + uint64_t(stripe) * BlockSize;
                auto size = local < g.valid ? static_cast<size_t>(std::min<uint64_t>(BlockSize, g.valid - local)) : 0;
                if (size && !stream.read(stream_start + local, b.data(), size)) throw std::runtime_error("Compressed spool is truncated");
            }
            rs.encode(blocks);
            for (uint32_t s = 0; s < N; ++s) {
                g.hashes[s * g.stripes + stripe] = block_hash(m.uuid, group, s, stripe, blocks[s]);
                payloads[s]->append(blocks[s]);
            }
        }
        stream_start += g.valid;
    }
    Archive a; a.manifest = std::move(m); a.encoded = serialize(a.manifest); a.digest = hash(a.encoded);
    // Round-trip the metadata through the same strict reader used by consumers.
    (void)parse_manifest(a.encoded);
    for (uint32_t g = 0; g < a.manifest.groups.size(); ++g) {
        for (uint32_t s = 0; s < N; ++s) {
            auto payload = staging.path / (volume_name(g, s) + ".tmp");
            write_volume(staging.path, a, g, s, payload); fs::remove(payload);
        }
    }
    write_sidecar(staging.path, a.encoded); fs::remove(spool);
    if (verify_archive(staging.path).exit_code() != 0) throw std::runtime_error("Created output verification failed");
    staging.commit();
}
void create_archive(const fs::path& source_path, const fs::path& output, uint64_t volume_size, uint32_t threads) {
    auto plan = directory_inputs(source_path, output);
    create_from_inputs(plan.root, plan.paths, output, volume_size, threads);
}
void create_selected_archive(const std::vector<fs::path>& source_paths, const fs::path& output, uint64_t volume_size, uint32_t threads) {
    auto plan = selected_inputs(source_paths, output);
    create_from_inputs(plan.root, plan.paths, output, volume_size, threads);
}
Manifest list_archive(const fs::path& directory) { return load_archive(directory).manifest; }
Verification verify_archive(const fs::path& directory) { return scan(load_archive(directory)); }
void repair_archive(const fs::path& directory, const fs::path& output) {
    auto a = load_archive(directory); require_outside(a.directory, output);
    Staging staging(output); ReedSolomon rs; auto blocks = empty_stripe();
    for (uint32_t g = 0; g < a.manifest.groups.size(); ++g) {
        const auto& group = a.manifest.groups[g]; auto input = open_group(a, g); Files out;
        for (uint32_t s = 0; s < N; ++s) {
            out[s] = std::make_unique<File>(staging.path / volume_name(g, s), File::Mode::New);
            out[s]->append(make_header(header_for(a, g, s), false)); out[s]->append(a.encoded);
        }
        for (uint32_t stripe = 0; stripe < group.stripes; ++stripe) {
            auto missing = read_stripe(a, input, g, stripe, blocks);
            if (missing.size() > M) throw std::runtime_error("Unrecoverable stripe: group=" + std::to_string(g) + " stripe=" + std::to_string(stripe));
            rs.decode(blocks, missing);
            for (uint32_t s = 0; s < N; ++s) {
                if (block_hash(a.manifest.uuid, g, s, stripe, blocks[s]) != group.hashes[s * group.stripes + stripe])
                    throw std::runtime_error("Reconstructed block failed BLAKE3 verification");
                out[s]->append(blocks[s]);
            }
        }
        for (uint32_t s = 0; s < N; ++s) {
            out[s]->append(a.encoded); out[s]->append(make_header(header_for(a, g, s), true)); out[s]->sync();
        }
    }
    write_sidecar(staging.path, a.encoded);
    if (verify_archive(staging.path).exit_code() != 0) throw std::runtime_error("Repaired output verification failed");
    staging.commit();
}
void extract_archive(const fs::path& directory, const fs::path& output) {
    auto a = load_archive(directory); require_outside(a.directory, output);
    if (scan(a).bad_data_blocks) throw std::runtime_error("Data blocks are damaged or missing; run repair first");
    Staging staging(output); StreamReader stream(a);
    for (const auto& e : a.manifest.entries) {
        check_cancel();
        auto target = staging.path / e.path;
        if (e.directory) {
            if (!fs::create_directory(target)) throw std::runtime_error("Directory name collision");
            fs::permissions(target, fs::perms::owner_all); continue;
        }
        File file(target, File::Mode::New); blake3_hasher digest; blake3_hasher_init(&digest);
        for (const auto& f : e.frames) {
            auto plain = decompress_frame(stream.read(f.offset, f.stored), f.plain);
            blake3_hasher_update(&digest, plain.data(), plain.size()); file.append(plain);
        }
        Digest actual{}; blake3_hasher_finalize(&digest, actual.data(), actual.size());
        if (actual != e.digest) throw std::runtime_error("Extracted file failed BLAKE3 verification: " + e.path);
        file.sync();
    }
    staging.commit();
}
}
