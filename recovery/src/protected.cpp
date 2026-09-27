#include "protected.hpp"
#include "binary.hpp"
#include "decompression_pool.hpp"
#include "read_progress.hpp"
#include "paged.hpp"
#include <algorithm>

namespace rz {
namespace {
std::vector<Frame> append_records(File& file, Manifest& m, const Bytes& bytes, RecordKind kind, ArchiveKeys* keys) {
    std::vector<Frame> frames;
    for (size_t position = 0; position < bytes.size();) {
        auto size = std::min<size_t>(FrameSize, bytes.size() - position);
        Bytes plain(bytes.begin() + static_cast<ptrdiff_t>(position), bytes.begin() + static_cast<ptrdiff_t>(position + size));
        WipeOnExit wipe_plain(plain, keys != nullptr);
        auto compressed = compress_frame(plain);
        WipeOnExit wipe_compressed(compressed, keys != nullptr);
        auto record = keys ? keys->seal(m.uuid, kind, m.stream_size, static_cast<uint32_t>(size), compressed) : std::move(compressed);
        frames.push_back({m.stream_size, static_cast<uint32_t>(record.size()), static_cast<uint32_t>(size)});
        file.append(record); m.stream_size += record.size(); position += size;
    }
    return frames;
}
Bytes private_index(const Manifest& m, uint64_t metadata_end, bool sensitive) {
    size_t index_size = 24;
    auto add = [&](size_t n) {
        if (n > MaxManifest - index_size) throw std::runtime_error("Private index exceeds 16 MiB limit");
        index_size += n;
    };
    for (const auto& e : m.entries) {
        add(96); add(e.path.size());
        for (size_t count : {e.frames.size(), e.metadata_frames.size()}) {
            if (count > MaxManifest / 16) throw std::runtime_error("Private index exceeds 16 MiB limit");
            add(count * 16);
        }
    }
    // Reserve once so serialized private names/digests cannot survive vector
    // growth in allocations that the final buffer guard can no longer wipe.
    binary::Writer w; w.b.reserve(index_size); WipeOnExit cleanup(w.b, sensitive);
    w.raw("RZPRI003", 8); w.u64(metadata_end);
    binary::write_entries(w, m.entries); w.u32(static_cast<uint32_t>(m.entries.size()));
    for (const auto& e : m.entries) {
        w.u64(e.metadata_size); w.raw(e.metadata_digest.data(), 32); w.u32(static_cast<uint32_t>(e.metadata_frames.size()));
        for (const auto& f : e.metadata_frames) { w.u64(f.offset); w.u32(f.stored); w.u32(f.plain); }
    }
    if (w.b.size() > MaxManifest) throw std::runtime_error("Private index exceeds 16 MiB limit");
    cleanup.release(); return std::move(w.b);
}
void parse_private(ConfigurableManifest& m, const Bytes& bytes) {
    binary::Reader r{bytes}; r.magic("RZPRI003"); auto metadata_end = r.u64();
    auto index_start = m.security.index_frames.front().offset;
    if (metadata_end > index_start) throw std::runtime_error("Invalid private index mapping");
    const auto max_output = m.profile == 5 ? MaxPagedOutput : MaxOutput;
    m.entries = binary::read_entries(r, index_start, metadata_end, max_output);
    if (r.u32() != m.entries.size()) throw std::runtime_error("Invalid metadata entry count");
    uint64_t next = 0, total_plain = 0;
    for (auto& e : m.entries) {
        e.metadata_size = r.u64(); r.raw(e.metadata_digest.data(), 32); auto count = r.u32();
        if (e.metadata_size > MaxMetadata || count != (e.metadata_size + FrameSize - 1) / FrameSize ||
            (m.security.metadata ? e.metadata_size == 0 : e.metadata_size != 0)) throw std::runtime_error("Invalid metadata record count");
        if (e.size > max_output - total_plain || e.metadata_size > max_output - total_plain - e.size)
            throw std::runtime_error("Expanded archive exceeds profile content limit");
        total_plain += e.size + e.metadata_size;
        uint64_t plain = 0;
        for (uint32_t i = 0; i < count; ++i) {
            Frame f{r.u64(), r.u32(), r.u32()};
            if (f.offset != next || f.stored == 0 || f.stored > FrameSize + FrameSize / 100 || f.plain == 0 || f.plain > FrameSize ||
                (i + 1 < count && f.plain != FrameSize)) throw std::runtime_error("Invalid metadata frame");
            next += f.stored; plain += f.plain; e.metadata_frames.push_back(f);
        }
        if (plain != e.metadata_size) throw std::runtime_error("Invalid metadata length");
    }
    if (next != metadata_end) throw std::runtime_error("Invalid metadata extent");
    r.end(); m.unlocked = true;
}
}
ProtectedInput pack_protected(const InputPlan& plan, const fs::path& spool_path, const SecurityOptions& options, CompressionProgress* progress, uint32_t threads, uint64_t max_output) {
    ProtectedInput result; auto& m = result.packed; m.uuid = random_uuid();
    result.security.encrypted = options.encrypt; result.security.metadata = options.metadata;
    validate_crypto_suite(options.crypto_suite);
    if (!options.encrypt && options.crypto_suite != CryptoProfile) throw std::runtime_error("Dual encryption requires a password");
    result.security.key_slot.suite = options.crypto_suite;
    result.security.key_slot.key_file = options.generate_key_file;
    if (options.encrypt) {
        if (!options.password) throw PasswordError();
        result.keys.emplace(create_keys(m.uuid, *options.password, result.security.key_slot, max_output));
    }
    auto* keys = result.keys ? &*result.keys : nullptr;
    File spool(spool_path, File::Mode::New); std::vector<Entry> attributes; uint64_t total_metadata = 0;
    for (const auto& [path, directory] : plan.paths) {
        Entry info;
        if (options.metadata) {
            auto bytes = capture_metadata(plan.root / path);
            WipeOnExit wipe_metadata(bytes, keys != nullptr);
            if (bytes.size() > max_output - total_metadata) throw std::runtime_error("Metadata exceeds archive size limit");
            total_metadata += bytes.size();
            info.metadata_size = bytes.size(); info.metadata_digest = hash(bytes);
            info.metadata_frames = append_records(spool, m, bytes, RecordKind::Metadata, keys);
        }
        attributes.push_back(std::move(info));
        (void)directory;
    }
    uint64_t metadata_end = m.stream_size;
    FrameEncoder encoder;
    if (keys) encoder = [&](const Bytes& compressed, uint64_t offset, uint32_t size) { return keys->seal(m.uuid, RecordKind::Content, offset, size, compressed); };
    pack_contents(plan.root, plan.paths, spool, m, encoder, total_metadata, progress, threads, max_output);
    for (size_t i = 0; i < m.entries.size(); ++i) {
        m.entries[i].metadata_size = attributes[i].metadata_size;
        m.entries[i].metadata_digest = attributes[i].metadata_digest;
        m.entries[i].metadata_frames = std::move(attributes[i].metadata_frames);
    }
    auto index = private_index(m, metadata_end, keys != nullptr); result.security.index_plain_size = index.size();
    WipeOnExit wipe_index(index, keys != nullptr);
    result.security.index_frames = append_records(spool, m, index, RecordKind::Index, keys);
    return result;
}
void sign_manifest(ConfigurableManifest& m, const ArchiveKeys& keys) {
    m.security.public_mac.fill(0); m.security.public_mac = keys.manifest_mac(serialize(m));
}
std::optional<ArchiveKeys> authenticate_manifest(const ConfigurableManifest& m, const Password* password) {
    if (!m.security.encrypted) return std::nullopt;
    if (!password) { if (m.security.key_slot.key_file) throw KeyFileError(); throw PasswordError(); }
    if (m.profile == 5 && (m.authentication_bytes.empty() || m.authentication_bytes.size() > MaxBootstrap))
        throw std::runtime_error("Invalid profile 5 authentication bootstrap");
    auto keys = unlock_keys(m.uuid, *password, m.security.key_slot);
    if (m.profile == 5) {
        if (!secure_equal(keys.manifest_mac(m.authentication_bytes), m.security.public_mac))
            throw std::runtime_error("Archive authentication failed");
        return keys;
    }
    auto copy = m; copy.security.public_mac.fill(0);
    if (!secure_equal(keys.manifest_mac(serialize(copy)), m.security.public_mac)) throw std::runtime_error("Archive authentication failed");
    return keys;
}
Bytes read_record(const ConfigurableManifest& m, const RecordReader& reader, const Frame& frame, RecordKind kind, const ArchiveKeys* keys) {
    auto record = reader(frame.offset, frame.stored);
    auto compressed = m.security.encrypted ? (keys ? keys->open(m.uuid, kind, frame.offset, frame.plain, record) : throw PasswordError()) : std::move(record);
    WipeOnExit cleanup(compressed, keys != nullptr);
    return decompress_frame(compressed, frame.plain);
}
void unlock_index(ConfigurableManifest& m, const RecordReader& reader, const ArchiveKeys* keys) {
    if (m.profile < 3) return;
    if (m.security.index_frames.empty() || m.security.index_plain_size > MaxManifest)
        throw std::runtime_error("Invalid private index length");
    Bytes bytes; bytes.reserve(static_cast<size_t>(m.security.index_plain_size)); WipeOnExit cleanup(bytes, keys != nullptr);
    for (const auto& frame : m.security.index_frames) {
        auto plain = read_record(m, reader, frame, RecordKind::Index, keys);
        WipeOnExit wipe_plain(plain, keys != nullptr);
        if (plain.size() > m.security.index_plain_size - bytes.size()) throw std::runtime_error("Invalid private index length");
        bytes.insert(bytes.end(), plain.begin(), plain.end());
    }
    if (bytes.size() != m.security.index_plain_size) throw std::runtime_error("Invalid private index length");
    parse_private(m, bytes);
}
Bytes read_metadata(const ConfigurableManifest& m, const Entry& e, const RecordReader& reader, const ArchiveKeys* keys) {
    if (e.metadata_size > MaxMetadata) throw std::runtime_error("Invalid metadata length");
    Bytes bytes; bytes.reserve(static_cast<size_t>(e.metadata_size)); WipeOnExit cleanup(bytes, keys != nullptr);
    for (const auto& frame : e.metadata_frames) {
        auto plain = read_record(m, reader, frame, RecordKind::Metadata, keys);
        WipeOnExit wipe_plain(plain, keys != nullptr);
        if (plain.size() > e.metadata_size - bytes.size()) throw std::runtime_error("Invalid metadata length");
        bytes.insert(bytes.end(), plain.begin(), plain.end());
    }
    if (bytes.size() != e.metadata_size || hash(bytes) != e.metadata_digest) throw std::runtime_error("File metadata verification failed");
    validate_metadata(bytes); cleanup.release(); return bytes;
}
void verify_private_records(const ConfigurableManifest& m, const RecordReader& reader, const ArchiveKeys* keys, uint32_t threads, ReadProgress* progress) {
    if (m.security.encrypted && !keys) throw PasswordError();
    DecompressionPool pool(m.uuid, m.security.encrypted ? keys : nullptr, threads);
    if (progress) progress->contents("checking", m.entries);
    for (const auto& e : m.entries) {
        blake3_hasher h; blake3_hasher_init(&h);
        WipeMemoryOnExit wipe_hasher(&h, sizeof h, keys != nullptr);
        auto consume = [&] {
            auto job = pool.take();
            blake3_hasher_update(&h, job->plain.data(), job->plain.size());
            if (progress) progress->advance(job->plain.size());
        };
        for (const auto& f : e.frames) {
            if (pool.full()) consume();
            auto job = std::make_unique<DecompressionJob>(keys != nullptr);
            job->offset = f.offset; job->plain_size = f.plain;
            job->record = reader(f.offset, f.stored);
            pool.submit(std::move(job));
        }
        while (!pool.empty()) consume();
        Digest digest{}; blake3_hasher_finalize(&h, digest.data(), 32);
        if (digest != e.digest) throw std::runtime_error("Original file digest verification failed");
        if (m.security.metadata) { auto bytes = read_metadata(m, e, reader, keys); WipeOnExit cleanup(bytes, keys != nullptr); }
        if (progress && !e.directory) progress->file_completed();
    }
}
}
