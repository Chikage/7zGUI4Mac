#include "configurable.hpp"
#include "binary.hpp"
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace rz {
namespace {
uint64_t ceil_div(uint64_t a, uint64_t b) { return a / b + (a % b != 0); }
uint64_t recovery_count(uint64_t data_blocks, const RecoveryOptions& options) {
    auto count = options.mode == RecoveryMode::Percent ? ceil_div(data_blocks * options.value, 10000)
                                                     : ceil_div(options.value, BlockSize);
    auto minimum = ceil_div(data_blocks, MaxDataShards);
    if (count < minimum) throw std::runtime_error("Recovery payload too small: minimum=" + std::to_string(minimum * BlockSize) + " bytes");
    if (count > data_blocks) throw std::runtime_error("Recovery payload too large: maximum=" + std::to_string(data_blocks * BlockSize) + " bytes (100% of padded compressed data)");
    return count;
}
// One row per group, then divide the remaining rows proportionally by k-1.
// Cumulative integer division avoids drift and exactly meets the rounded budget.
std::vector<std::pair<uint32_t, uint32_t>> geometry(uint64_t data, uint64_t parity) {
    auto count = ceil_div(data, MaxDataShards), weight_total = data - count, spare = parity - count;
    uint64_t weight = 0, previous = 0;
    std::vector<std::pair<uint32_t, uint32_t>> result;
    for (uint64_t i = 0; i < count; ++i) {
        auto k = static_cast<uint32_t>(std::min<uint64_t>(MaxDataShards, data - i * MaxDataShards));
        weight += k - 1;
        auto allocated = weight_total ? weight * spare / weight_total : 0;
        auto m = static_cast<uint32_t>(1 + allocated - previous);
        result.emplace_back(k, m); previous = allocated;
    }
    return result;
}
uint32_t capacity(uint64_t volume, uint64_t manifest_size) {
    auto overhead = 2 * HeaderSize + 2 * manifest_size;
    if (volume < overhead + BlockSize) throw std::runtime_error("Replicated index does not fit volume; increase --volume-size");
    return static_cast<uint32_t>((volume - overhead) / BlockSize);
}
}
void validate_options(const RecoveryOptions& o) {
    if (o.mode == RecoveryMode::Volumes) {
        if (o.data_volumes < 1 || o.data_volumes > MaxDataShards ||
            o.recovery_volumes < 1 || o.recovery_volumes > o.data_volumes)
            throw std::runtime_error("Volume counts require 1 <= recovery volumes <= data volumes <= 100");
        if (o.value != 0 || o.volume_size != 0) throw std::runtime_error("Volume counts cannot be combined with size or recovery budget");
        return;
    }
    if (o.volume_size < 1024 * 1024 || o.volume_size > MaxConfigurableVolume)
        throw std::runtime_error("Volume size must be between 1 MiB and 16 GiB");
    if (o.mode == RecoveryMode::Percent) {
        if (o.value < 100 || o.value > 10000) throw std::runtime_error("Recovery percent must be between 1 and 100 (up to two decimal places)");
    } else if (o.mode == RecoveryMode::Bytes) {
        if (o.value == 0 || o.value > MaxOutput) throw std::runtime_error("Invalid recovery payload byte count");
    } else throw std::runtime_error("Unknown recovery mode");
}
uint32_t ConfigurableManifest::volume_count(bool parity) const {
    if (blocks_per_volume == 0) throw std::runtime_error("Invalid volume capacity");
    return static_cast<uint32_t>(ceil_div(parity ? recovery_blocks : data_blocks, blocks_per_volume));
}
uint64_t ConfigurableManifest::payload_size(bool parity, uint32_t volume) const {
    auto count = volume_count(parity);
    if (volume >= count) throw std::runtime_error("Invalid volume index");
    auto blocks = parity ? recovery_blocks : data_blocks;
    return ((blocks - 1 - volume) / count + 1) * BlockSize;
}
ConfigurableManifest configure(Manifest packed, const RecoveryOptions& options, const SecurityInfo* security) {
    validate_options(options);
    if (packed.stream_size > MaxOutput + MaxOutput / 100) throw std::runtime_error("Stream exceeds supported limit");
    ConfigurableManifest m;
    m.uuid = packed.uuid; m.stream_size = packed.stream_size; m.entries = std::move(packed.entries); m.options = options;
    if (security) { m.profile = 3; m.security = *security; }
    const bool counted = options.mode == RecoveryMode::Volumes;
    if (counted && !security) throw std::runtime_error("Counted volumes require profile 4 records");
    if (counted) {
        m.profile = 4;
        m.blocks_per_volume = static_cast<uint32_t>(std::max<uint64_t>(1, ceil_div(m.stream_size, uint64_t(options.data_volumes) * BlockSize)));
        m.data_blocks = uint64_t(m.blocks_per_volume) * options.data_volumes;
        m.recovery_blocks = uint64_t(m.blocks_per_volume) * options.recovery_volumes;
    } else {
        m.data_blocks = std::max<uint64_t>(1, ceil_div(m.stream_size, BlockSize));
        m.recovery_blocks = recovery_count(m.data_blocks, options);
    }
    if ((m.data_blocks + m.recovery_blocks) * 32 > MaxManifest) throw std::runtime_error("Block index exceeds 16 MiB limit");
    if (counted) {
        m.groups.assign(m.blocks_per_volume, {options.data_volumes, options.recovery_volumes,
            std::vector<Digest>(options.data_volumes + options.recovery_volumes)});
        (void)serialize(m); // Includes per-stripe headers and security metadata in the index limit.
    } else {
        for (auto [k, parity] : geometry(m.data_blocks, m.recovery_blocks))
            m.groups.push_back({k, parity, std::vector<Digest>(k + parity)});
        m.blocks_per_volume = capacity(options.volume_size, serialize(m).size());
    }
    if (m.volume_count(false) > MaxPhysicalVolumes || m.volume_count(true) > MaxPhysicalVolumes)
        throw std::runtime_error("Too many physical volumes");
    return m;
}
Bytes serialize(const ConfigurableManifest& m) {
    binary::Writer w;
    if (m.profile < 2 || m.profile > 4) throw std::runtime_error("Unsupported coding profile");
    w.raw(m.profile == 4 ? "RZIDX004" : m.profile == 3 ? "RZIDX003" : "RZIDX002", 8); w.raw(m.uuid.data(), 16);
    for (auto value : {m.profile, BlockSize, FrameSize, static_cast<uint32_t>(m.options.mode)}) w.u32(value);
    w.u64(m.options.value); w.u64(m.options.volume_size);
    if (m.profile == 4) { w.u32(m.options.data_volumes); w.u32(m.options.recovery_volumes); }
    w.u32(m.blocks_per_volume);
    w.u64(m.stream_size); w.u64(m.data_blocks); w.u64(m.recovery_blocks);
    w.u32(static_cast<uint32_t>(m.groups.size()));
    for (const auto& g : m.groups) {
        w.u32(g.k); w.u32(g.m);
        for (const auto& digest : g.hashes) w.raw(digest.data(), 32);
    }
    if (m.profile == 2) binary::write_entries(w, m.entries);
    else {
        if (m.security.key_slot.key_file && !m.security.encrypted) throw std::runtime_error("Key file requires encryption");
        w.u32((m.security.encrypted ? 1U : 0U) | (m.security.metadata ? 2U : 0U) | (m.security.key_slot.key_file ? 4U : 0U));
        w.u64(m.security.index_plain_size); w.u32(static_cast<uint32_t>(m.security.index_frames.size()));
        for (const auto& f : m.security.index_frames) { w.u64(f.offset); w.u32(f.stored); w.u32(f.plain); }
        if (m.security.encrypted) {
            validate_crypto_suite(m.security.key_slot.suite);
            bool dual = m.security.key_slot.suite == DualCryptoProfile;
            if (m.security.key_slot.wrapped_key.size() != (dual ? 96 : 48)) throw std::runtime_error("Invalid wrapped key size");
            w.u32(m.security.key_slot.suite); w.u64(m.security.key_slot.key_file ? 0 : PasswordOps); w.u64(m.security.key_slot.key_file ? 0 : PasswordMemory);
            w.raw(m.security.key_slot.salt.data(), 16); w.raw(m.security.key_slot.nonce.data(), 24);
            if (dual) w.raw(m.security.key_slot.aes_nonce.data(), 12);
            w.raw(m.security.key_slot.wrapped_key.data(), m.security.key_slot.wrapped_key.size()); w.raw(m.security.public_mac.data(), 32);
        }
    }
    if (w.b.size() > MaxManifest) throw std::runtime_error("Manifest exceeds limit");
    return w.b;
}
ConfigurableManifest parse_configurable_manifest(const Bytes& bytes) {
    if (bytes.size() > MaxManifest) throw std::runtime_error("Manifest exceeds limit");
    binary::Reader r{bytes}; ConfigurableManifest m;
    m.profile = bytes.size() >= 8 && std::memcmp(bytes.data(), "RZIDX004", 8) == 0 ? 4 :
        bytes.size() >= 8 && std::memcmp(bytes.data(), "RZIDX003", 8) == 0 ? 3 : 2;
    r.magic(m.profile == 4 ? "RZIDX004" : m.profile == 3 ? "RZIDX003" : "RZIDX002"); r.raw(m.uuid.data(), 16);
    for (auto expected : {m.profile, BlockSize, FrameSize}) if (r.u32() != expected) throw std::runtime_error("Unsupported coding profile");
    m.options.mode = static_cast<RecoveryMode>(r.u32()); m.options.value = r.u64(); m.options.volume_size = r.u64();
    if (m.profile == 4) { m.options.data_volumes = r.u32(); m.options.recovery_volumes = r.u32(); }
    if ((m.profile == 4) != (m.options.mode == RecoveryMode::Volumes)) throw std::runtime_error("Recovery mode does not match profile");
    validate_options(m.options);
    m.blocks_per_volume = r.u32(); m.stream_size = r.u64(); m.data_blocks = r.u64(); m.recovery_blocks = r.u64();
    if (m.stream_size > MaxOutput + MaxOutput / 100)
        throw std::runtime_error("Invalid stream geometry");
    if (m.profile == 4) {
        auto stripes = std::max<uint64_t>(1, ceil_div(m.stream_size, uint64_t(m.options.data_volumes) * BlockSize));
        if (m.blocks_per_volume != stripes || m.data_blocks != stripes * m.options.data_volumes ||
            m.recovery_blocks != stripes * m.options.recovery_volumes)
            throw std::runtime_error("Invalid counted volume geometry");
    } else {
        if (m.data_blocks != std::max<uint64_t>(1, ceil_div(m.stream_size, BlockSize))) throw std::runtime_error("Invalid stream geometry");
        if (m.recovery_blocks != recovery_count(m.data_blocks, m.options)) throw std::runtime_error("Invalid recovery budget");
        if (m.blocks_per_volume != capacity(m.options.volume_size, bytes.size())) throw std::runtime_error("Invalid volume mapping");
    }
    if ((m.data_blocks + m.recovery_blocks) * 32 > bytes.size()) throw std::runtime_error("Truncated block hashes");
    if (m.volume_count(false) > MaxPhysicalVolumes || m.volume_count(true) > MaxPhysicalVolumes)
        throw std::runtime_error("Invalid volume mapping");
    auto expected = m.profile == 4
        ? std::vector<std::pair<uint32_t, uint32_t>>(m.blocks_per_volume, {m.options.data_volumes, m.options.recovery_volumes})
        : geometry(m.data_blocks, m.recovery_blocks);
    if (r.u32() != expected.size()) throw std::runtime_error("Invalid group count");
    for (auto [k, parity] : expected) {
        if (r.u32() != k || r.u32() != parity) throw std::runtime_error("Invalid group allocation");
        CodingGroup g{k, parity, std::vector<Digest>(k + parity)};
        for (auto& digest : g.hashes) r.raw(digest.data(), 32);
        m.groups.push_back(std::move(g));
    }
    if (m.profile == 2) m.entries = binary::read_entries(r, m.stream_size);
    else {
        auto flags = r.u32(); if (flags & ~7U || ((flags & 4) && !(flags & 1))) throw std::runtime_error("Unknown security flags");
        m.security.encrypted = flags & 1; m.security.metadata = flags & 2; m.unlocked = false;
        m.security.key_slot.key_file = flags & 4;
        m.security.index_plain_size = r.u64(); auto count = r.u32();
        if (m.security.index_plain_size == 0 || m.security.index_plain_size > MaxManifest ||
            count != (m.security.index_plain_size + FrameSize - 1) / FrameSize) throw std::runtime_error("Invalid private index size");
        uint64_t next = 0, plain = 0;
        for (uint32_t i = 0; i < count; ++i) {
            Frame f{r.u64(), r.u32(), r.u32()};
            if (i == 0) next = f.offset;
            if (f.offset != next || f.offset > m.stream_size || f.stored > m.stream_size - f.offset ||
                f.stored == 0 || f.stored > FrameSize + FrameSize / 100 || f.plain == 0 || f.plain > FrameSize ||
                (i + 1 < count && f.plain != FrameSize)) throw std::runtime_error("Invalid private index record");
            next += f.stored; plain += f.plain; m.security.index_frames.push_back(f);
        }
        if (next != m.stream_size || plain != m.security.index_plain_size) throw std::runtime_error("Invalid private index mapping");
        if (m.security.encrypted) {
            m.security.key_slot.suite = r.u32(); validate_crypto_suite(m.security.key_slot.suite);
            if (r.u64() != (m.security.key_slot.key_file ? 0 : PasswordOps) || r.u64() != (m.security.key_slot.key_file ? 0 : PasswordMemory))
                throw std::runtime_error("Unsupported or excessive password derivation parameters");
            r.raw(m.security.key_slot.salt.data(), 16); r.raw(m.security.key_slot.nonce.data(), 24);
            bool dual = m.security.key_slot.suite == DualCryptoProfile;
            if (dual) r.raw(m.security.key_slot.aes_nonce.data(), 12);
            m.security.key_slot.wrapped_key.resize(dual ? 96 : 48);
            r.raw(m.security.key_slot.wrapped_key.data(), m.security.key_slot.wrapped_key.size()); r.raw(m.security.public_mac.data(), 32);
        }
    }
    r.end(); return m;
}
Bytes make_header(const ConfigurableHeader& h, bool footer) {
    binary::Writer w;
    if (h.profile < 2 || h.profile > 4) throw std::runtime_error("Unsupported volume version");
    w.raw(h.profile == 4 ? (footer ? "RZEND004" : "RZVOL004") :
        h.profile == 3 ? (footer ? "RZEND003" : "RZVOL003") : (footer ? "RZEND002" : "RZVOL002"), 8);
    w.u32(h.profile); w.u32(h.parity ? 1 : 0);
    w.raw(h.uuid.data(), 16); w.u32(h.volume); w.u32(0);
    w.u64(h.manifest_size); w.u64(h.payload_size); w.raw(h.manifest_hash.data(), 32);
    auto digest = hash(w.b); w.raw(digest.data(), 32); return w.b;
}
ConfigurableHeader parse_configurable_header(const Bytes& bytes, bool footer) {
    if (bytes.size() != HeaderSize) throw std::runtime_error("Invalid header size");
    Digest expected{}; std::copy(bytes.end() - 32, bytes.end(), expected.begin());
    if (hash(bytes.data(), HeaderSize - 32) != expected) throw std::runtime_error("Bad volume header checksum");
    binary::Reader r{bytes}; ConfigurableHeader h;
    h.profile = std::memcmp(bytes.data(), footer ? "RZEND004" : "RZVOL004", 8) == 0 ? 4 :
        std::memcmp(bytes.data(), footer ? "RZEND003" : "RZVOL003", 8) == 0 ? 3 : 2;
    r.magic(h.profile == 4 ? (footer ? "RZEND004" : "RZVOL004") :
        h.profile == 3 ? (footer ? "RZEND003" : "RZVOL003") : (footer ? "RZEND002" : "RZVOL002"));
    if (r.u32() != h.profile) throw std::runtime_error("Unsupported volume version");
    auto kind = r.u32(); if (kind > 1) throw std::runtime_error("Invalid volume kind"); h.parity = kind == 1;
    r.raw(h.uuid.data(), 16); h.volume = r.u32();
    if (r.u32() != 0) throw std::runtime_error("Unknown header flags");
    h.manifest_size = r.u64(); h.payload_size = r.u64(); r.raw(h.manifest_hash.data(), 32);
    if (h.volume >= MaxPhysicalVolumes || h.manifest_size == 0 || h.manifest_size > MaxManifest ||
        h.payload_size == 0 || h.payload_size > (h.profile == 4 ? MaxOutput + MaxOutput / 100 + BlockSize : MaxConfigurableVolume) || h.payload_size % BlockSize)
        throw std::runtime_error("Invalid volume geometry");
    return h;
}
std::string configurable_volume_name(bool parity, uint32_t index) {
    std::ostringstream s;
    s << (parity ? 'p' : 'd') << std::setfill('0') << std::setw(6) << index << (parity ? ".rzr" : ".rzv");
    return s.str();
}
}
