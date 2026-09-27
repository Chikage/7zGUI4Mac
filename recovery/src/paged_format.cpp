#include "paged.hpp"
#include "binary.hpp"
#include <algorithm>

namespace rz {
namespace {
uint64_t ceil_div(uint64_t a, uint64_t b) { return a / b + (a % b != 0); }
void write_security(binary::Writer& w, const SecurityInfo& s) {
    if (s.key_slot.key_file && !s.encrypted) throw std::runtime_error("Key file requires encryption");
    w.u32((s.encrypted ? 1U : 0U) | (s.metadata ? 2U : 0U) | (s.key_slot.key_file ? 4U : 0U));
    w.u64(s.index_plain_size); w.u32(static_cast<uint32_t>(s.index_frames.size()));
    for (const auto& f : s.index_frames) { w.u64(f.offset); w.u32(f.stored); w.u32(f.plain); }
    if (!s.encrypted) return;
    validate_crypto_suite(s.key_slot.suite);
    const bool dual = s.key_slot.suite == DualCryptoProfile;
    if (s.key_slot.wrapped_key.size() != (dual ? 96 : 48)) throw std::runtime_error("Invalid wrapped key size");
    w.u32(s.key_slot.suite); w.u64(s.key_slot.key_file ? 0 : PasswordOps); w.u64(s.key_slot.key_file ? 0 : PasswordMemory);
    w.raw(s.key_slot.salt.data(), 16); w.raw(s.key_slot.nonce.data(), 24);
    if (dual) w.raw(s.key_slot.aes_nonce.data(), 12);
    w.raw(s.key_slot.wrapped_key.data(), s.key_slot.wrapped_key.size()); w.raw(s.public_mac.data(), 32);
}
}
PagedLayout paged_layout(uint64_t stream_size, uint32_t k, uint32_t m) {
    if (!stream_size || stream_size > MaxPagedStream || k < 1 || k > 100 || m < 1 || m > k)
        throw std::runtime_error("Invalid profile 5 geometry");
    PagedLayout l;
    l.data_stripes = ceil_div(stream_size, uint64_t(k) * BlockSize);
    l.hash_pages = static_cast<uint32_t>(ceil_div(l.data_stripes * (k + m) * 32, BlockSize));
    l.root_size = 44 + uint64_t(l.hash_pages) * 32;
    if (l.root_size > MaxPagedRoot || l.data_stripes > UINT32_MAX) throw std::runtime_error("Profile 5 index limit exceeded");
    l.index_stripes = ceil_div(uint64_t(l.hash_pages) * BlockSize + l.root_size, uint64_t(k) * BlockSize);
    return l;
}
Bytes serialize_bootstrap(const PagedBootstrap& b) {
    const auto& m = b.manifest; binary::Writer w; w.limit = MaxBootstrap;
    w.raw("RZIDX005", 8); w.raw(m.uuid.data(), 16);
    for (auto v : {5U, BlockSize, FrameSize, m.options.data_volumes, m.options.recovery_volumes}) w.u32(v);
    w.u64(m.stream_size); w.u64(b.layout.data_stripes); w.u64(b.layout.index_stripes);
    w.u32(b.layout.hash_pages); w.u64(b.layout.root_size); w.raw(b.root_hash.data(), 32);
    write_security(w, m.security);
    if (b.index_volume_hashes.size() != m.options.data_volumes + m.options.recovery_volumes)
        throw std::runtime_error("Invalid index volume digest count");
    w.u32(static_cast<uint32_t>(b.index_volume_hashes.size()));
    for (const auto& h : b.index_volume_hashes) w.raw(h.data(), h.size());
    if (w.b.size() > MaxBootstrap) throw std::runtime_error("Profile 5 bootstrap limit exceeded");
    return w.b;
}
void update_paged_summary(PagedBootstrap& b) {
    auto& m = b.manifest; m.profile = 5; m.options.profile = 5;
    m.options.mode = RecoveryMode::Volumes; m.options.value = 0; m.options.volume_size = 0;
    m.blocks_per_volume = static_cast<uint32_t>(b.layout.data_stripes);
    m.data_blocks = b.layout.data_stripes * m.options.data_volumes;
    m.recovery_blocks = b.layout.data_stripes * m.options.recovery_volumes;
    m.content_limit = MaxPagedOutput;
    m.metadata_bytes_per_volume = 2 * HeaderSize + 2 * serialize_bootstrap(b).size()
        + b.layout.data_stripes * 32 + b.layout.index_stripes * PagedRecordSize;
    const auto mac = m.security.public_mac;
    m.security.public_mac.fill(0);
    m.authentication_bytes = serialize_bootstrap(b);
    m.security.public_mac = mac;
}
PagedBootstrap parse_bootstrap(const Bytes& bytes) {
    if (bytes.size() > MaxBootstrap) throw std::runtime_error("Oversized profile 5 bootstrap");
    binary::Reader r{bytes}; PagedBootstrap b; auto& m = b.manifest;
    r.magic("RZIDX005"); r.raw(m.uuid.data(), 16);
    for (auto expected : {5U, BlockSize, FrameSize}) if (r.u32() != expected) throw std::runtime_error("Unsupported profile 5 parameters");
    m.options.data_volumes = r.u32(); m.options.recovery_volumes = r.u32(); m.stream_size = r.u64();
    auto expected = paged_layout(m.stream_size, m.options.data_volumes, m.options.recovery_volumes);
    b.layout.data_stripes = r.u64(); b.layout.index_stripes = r.u64(); b.layout.hash_pages = r.u32(); b.layout.root_size = r.u64();
    if (b.layout.data_stripes != expected.data_stripes || b.layout.index_stripes != expected.index_stripes ||
        b.layout.hash_pages != expected.hash_pages || b.layout.root_size != expected.root_size)
        throw std::runtime_error("Invalid profile 5 index geometry");
    r.raw(b.root_hash.data(), 32); auto flags = r.u32();
    if ((flags & ~7U) || ((flags & 4U) && !(flags & 1U))) throw std::runtime_error("Invalid profile 5 security flags");
    auto& s = m.security; s.encrypted = flags & 1; s.metadata = flags & 2; s.key_slot.key_file = flags & 4;
    s.index_plain_size = r.u64(); auto count = r.u32();
    if (!s.index_plain_size || s.index_plain_size > MaxManifest || count != ceil_div(s.index_plain_size, FrameSize))
        throw std::runtime_error("Invalid profile 5 private index size");
    uint64_t next = 0, plain = 0;
    for (uint32_t i = 0; i < count; ++i) {
        Frame f{r.u64(), r.u32(), r.u32()}; if (i == 0) next = f.offset;
        if (f.offset != next || f.offset > m.stream_size || !f.stored || f.stored > m.stream_size - f.offset ||
            f.stored > FrameSize + FrameSize / 100 || !f.plain || f.plain > FrameSize || (i + 1 < count && f.plain != FrameSize))
            throw std::runtime_error("Invalid profile 5 private index mapping");
        next += f.stored; plain += f.plain; s.index_frames.push_back(f);
    }
    if (next != m.stream_size || plain != s.index_plain_size) throw std::runtime_error("Invalid private index extent");
    if (s.encrypted) {
        s.key_slot.suite = r.u32(); validate_crypto_suite(s.key_slot.suite);
        if (r.u64() != (s.key_slot.key_file ? 0 : PasswordOps) || r.u64() != (s.key_slot.key_file ? 0 : PasswordMemory))
            throw std::runtime_error("Unsupported password derivation parameters");
        r.raw(s.key_slot.salt.data(), 16); r.raw(s.key_slot.nonce.data(), 24);
        const bool dual = s.key_slot.suite == DualCryptoProfile;
        if (dual) r.raw(s.key_slot.aes_nonce.data(), 12);
        s.key_slot.wrapped_key.resize(dual ? 96 : 48); r.raw(s.key_slot.wrapped_key.data(), s.key_slot.wrapped_key.size());
        r.raw(s.public_mac.data(), 32);
    }
    const auto hash_count = r.u32();
    if (hash_count != m.options.data_volumes + m.options.recovery_volumes) throw std::runtime_error("Invalid index volume digest count");
    b.index_volume_hashes.resize(hash_count);
    for (auto& h : b.index_volume_hashes) r.raw(h.data(), h.size());
    r.end(); m.unlocked = false; update_paged_summary(b); return b;
}
Bytes serialize_page_root(const PagedBootstrap& b, const std::vector<Digest>& hashes) {
    if (hashes.size() != b.layout.hash_pages) throw std::runtime_error("Invalid hash page count");
    binary::Writer w; w.limit = MaxPagedRoot; w.raw("RZROOT05", 8); w.raw(b.manifest.uuid.data(), 16);
    w.u32(b.manifest.options.data_volumes); w.u32(b.manifest.options.recovery_volumes); w.u64(b.layout.data_stripes);
    w.u32(b.layout.hash_pages); for (const auto& h : hashes) w.raw(h.data(), 32); return w.b;
}
std::vector<Digest> parse_page_root(const PagedBootstrap& b, const Bytes& bytes) {
    if (bytes.size() != b.layout.root_size || hash(bytes) != b.root_hash) throw std::runtime_error("Profile 5 index root failed authentication");
    binary::Reader r{bytes}; r.magic("RZROOT05"); UUID uuid{}; r.raw(uuid.data(), 16);
    if (uuid != b.manifest.uuid || r.u32() != b.manifest.options.data_volumes || r.u32() != b.manifest.options.recovery_volumes ||
        r.u64() != b.layout.data_stripes || r.u32() != b.layout.hash_pages) throw std::runtime_error("Invalid index root identity");
    std::vector<Digest> out(b.layout.hash_pages); for (auto& h : out) r.raw(h.data(), 32); r.end(); return out;
}
Digest index_block_hash(const UUID& uuid, uint32_t stripe, uint32_t column, const Bytes& block) {
    blake3_hasher h; blake3_hasher_init(&h); constexpr char domain[] = "rz5-index-block";
    blake3_hasher_update(&h, domain, sizeof(domain)-1); blake3_hasher_update(&h, uuid.data(), 16);
    binary::Writer id; id.u32(stripe); id.u32(column); blake3_hasher_update(&h, id.b.data(), id.b.size());
    blake3_hasher_update(&h, block.data(), block.size()); Digest digest{}; blake3_hasher_finalize(&h, digest.data(), 32); return digest;
}
Bytes make_paged_header(const PagedBootstrap& b, bool parity, uint32_t volume, bool footer) {
    auto bootstrap = serialize_bootstrap(b); binary::Writer w;
    w.raw(footer ? "RZEND005" : "RZVOL005", 8); w.u32(5); w.u32(parity ? 1 : 0); w.raw(b.manifest.uuid.data(), 16);
    w.u32(volume); w.u32(0); w.u64(bootstrap.size()); w.u64((b.layout.data_stripes + b.layout.index_stripes) * PagedRecordSize);
    auto digest = hash(bootstrap); w.raw(digest.data(), 32); digest = hash(w.b); w.raw(digest.data(), 32); return w.b;
}
ConfigurableHeader parse_paged_header(const Bytes& bytes, bool footer) {
    if (bytes.size() != HeaderSize) throw std::runtime_error("Invalid profile 5 header size");
    Digest expected{}; std::copy(bytes.end()-32, bytes.end(), expected.begin());
    if (hash(bytes.data(), HeaderSize-32) != expected) throw std::runtime_error("Bad profile 5 header checksum");
    binary::Reader r{bytes}; ConfigurableHeader h; r.magic(footer ? "RZEND005" : "RZVOL005");
    h.profile = r.u32(); auto parity = r.u32(); r.raw(h.uuid.data(), 16); h.volume = r.u32(); auto reserved = r.u32();
    h.manifest_size = r.u64(); h.payload_size = r.u64(); r.raw(h.manifest_hash.data(), 32);
    if (h.profile != 5 || parity > 1 || reserved || h.volume >= 100 || h.manifest_size < 144 || h.manifest_size > MaxBootstrap ||
        !h.payload_size || h.payload_size % PagedRecordSize || h.payload_size > 2 * MaxPagedStream)
        throw std::runtime_error("Invalid profile 5 header geometry");
    h.parity = parity; return h;
}
}
