#include "paged.hpp"
#include "binary.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class Action> void rejects(Action action, const char* message) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, message);
}
void put(rz::Bytes& bytes, size_t offset, uint64_t value, size_t width) {
    require(offset + width <= bytes.size(), "invalid test field offset");
    for (size_t i = 0; i < width; ++i) bytes[offset + i] = static_cast<uint8_t>(value >> (i * 8));
}
rz::PagedBootstrap bootstrap(uint64_t size, uint32_t k = 10, uint32_t m = 2) {
    rz::PagedBootstrap b; b.manifest.uuid[3] = 73;
    b.manifest.stream_size = size;
    b.manifest.options.data_volumes = k; b.manifest.options.recovery_volumes = m;
    b.manifest.security.index_plain_size = 64;
    b.manifest.security.index_frames.push_back({size - 128, 128, 64});
    b.index_volume_hashes.resize(k + m);
    for (size_t i = 0; i < b.index_volume_hashes.size(); ++i) b.index_volume_hashes[i][0] = static_cast<uint8_t>(i + 1);
    b.layout = rz::paged_layout(size, k, m); rz::update_paged_summary(b); return b;
}
void layouts() {
    require(rz::MaxOutput == 64ULL * 1024 * 1024 * 1024, "legacy content limit changed");
    require(rz::MaxPagedOutput == 1024ULL * 1024 * 1024 * 1024, "profile 5 content limit is not 1 TiB");
    for (uint32_t k : {1U, 2U, 10U, 100U}) {
        for (uint32_t m : {1U, k}) {
            for (uint64_t size : {uint64_t(1), uint64_t(k) * rz::BlockSize - 1,
                                  uint64_t(k) * rz::BlockSize, uint64_t(k) * rz::BlockSize + 1,
                                  rz::MaxOutput + 1, rz::MaxPagedOutput, rz::MaxPagedStream}) {
                const auto layout = rz::paged_layout(size, k, m);
                require(layout.data_stripes * k * rz::BlockSize >= size, "content does not fit physical stripe allocation");
                require((layout.data_stripes - 1) * k * rz::BlockSize < size, "content stripe allocation is not minimal");
                const auto hash_bytes = layout.data_stripes * (k + m) * 32;
                require(uint64_t(layout.hash_pages) * rz::BlockSize >= hash_bytes, "hash page allocation truncates block digests");
                require(uint64_t(layout.hash_pages - 1) * rz::BlockSize < hash_bytes, "hash page allocation is not minimal");
                const auto index_bytes = uint64_t(layout.hash_pages) * rz::BlockSize + layout.root_size;
                require(layout.index_stripes * k * rz::BlockSize >= index_bytes, "protected index allocation is too short");
                require((layout.index_stripes - 1) * k * rz::BlockSize < index_bytes, "protected index allocation is not minimal");
                require(layout.root_size <= rz::MaxPagedRoot && layout.data_stripes <= UINT32_MAX, "large archive exceeds bounded root/stripe representation");
                if (size < 128) continue;
                auto b = bootstrap(size, k, m); auto encoded = rz::serialize_bootstrap(b);
                auto decoded = rz::parse_bootstrap(encoded);
                require(rz::serialize_bootstrap(decoded) == encoded, "large bootstrap roundtrip changed wire bytes");
                require(decoded.manifest.profile == 5 && decoded.manifest.content_limit == rz::MaxPagedOutput,
                        "parsed profile 5 summary exposes the wrong limit");
                require(decoded.manifest.data_blocks == layout.data_stripes * k &&
                        decoded.manifest.recovery_blocks == layout.data_stripes * m, "summary block counts do not match stripes");
            }
        }
    }
    for (auto size : {uint64_t(0), rz::MaxPagedStream + 1, UINT64_MAX})
        rejects([&] { (void)rz::paged_layout(size, 10, 2); }, "out-of-range stream accepted");
    for (auto pair : {std::pair{0U, 1U}, std::pair{101U, 1U}, std::pair{10U, 0U}, std::pair{10U, 11U}})
        rejects([&] { (void)rz::paged_layout(128, pair.first, pair.second); }, "unsupported RS geometry accepted");
}
void malformed_bootstraps() {
    auto b = bootstrap(rz::MaxPagedOutput); auto valid = rz::serialize_bootstrap(b);
    for (size_t length = 0; length < valid.size(); ++length) {
        rz::Bytes short_bytes(valid.begin(), valid.begin() + length);
        rejects([&] { (void)rz::parse_bootstrap(short_bytes); }, "truncated bootstrap accepted");
    }
    auto test = [&](size_t offset, uint64_t value, size_t width) {
        auto changed = valid; put(changed, offset, value, width);
        rejects([&] { (void)rz::parse_bootstrap(changed); }, "malformed bootstrap field accepted");
    };
    test(0, 0, 1); test(24, 4, 4); test(28, 1, 4); test(32, 0, 4);
    test(36, 0, 4); test(36, 101, 4); test(40, 0, 4); test(40, 11, 4);
    test(44, 0, 8); test(44, rz::MaxPagedStream + 1, 8); test(44, UINT64_MAX, 8);
    test(52, b.layout.data_stripes + 1, 8); test(60, b.layout.index_stripes + 1, 8);
    test(68, UINT32_MAX, 4); test(72, UINT64_MAX, 8);
    test(112, 8, 4); test(112, 4, 4);
    test(116, 0, 8); test(116, rz::MaxManifest + 1, 8); test(124, UINT32_MAX, 4);
    test(128, UINT64_MAX, 8); test(128, b.manifest.stream_size, 8);
    test(136, 0, 4); test(136, rz::FrameSize + rz::FrameSize / 100 + 1, 4);
    test(140, 0, 4); test(140, rz::FrameSize + 1, 4);
    test(144, 0, 4); test(144, UINT32_MAX, 4);
    auto missing_digest = b; missing_digest.index_volume_hashes.pop_back();
    rejects([&] { (void)rz::serialize_bootstrap(missing_digest); }, "incomplete index volume digest table serialized");
    auto trailing = valid; trailing.push_back(0);
    rejects([&] { (void)rz::parse_bootstrap(trailing); }, "trailing bootstrap data accepted");
    rejects([&] { (void)rz::parse_bootstrap(rz::Bytes(rz::MaxBootstrap + 1)); }, "unbounded bootstrap accepted");
    rejects([&] { (void)rz::parse_configurable_manifest(valid); }, "legacy parser silently accepted profile 5");
}
void roots_and_headers() {
    for (auto size : {rz::MaxOutput + 1, rz::MaxPagedOutput, rz::MaxPagedStream}) {
        auto b = bootstrap(size, 1, 1);
        std::vector<rz::Digest> hashes(b.layout.hash_pages);
        for (size_t i = 0; i < hashes.size(); ++i) {
            hashes[i][0] = static_cast<uint8_t>(i); hashes[i][1] = static_cast<uint8_t>(i >> 8);
        }
        auto root = rz::serialize_page_root(b, hashes); b.root_hash = rz::hash(root);
        require(rz::parse_page_root(b, root) == hashes, "large root digest list changed");
        auto missing = hashes; missing.pop_back();
        rejects([&] { (void)rz::serialize_page_root(b, missing); }, "wrong page digest count accepted");
        auto damaged = root; damaged.back() ^= 1;
        rejects([&] { (void)rz::parse_page_root(b, damaged); }, "damaged root passed authentication");
        damaged = root; damaged.pop_back();
        rejects([&] { (void)rz::parse_page_root(b, damaged); }, "truncated root accepted");
        for (size_t offset : {size_t(0), size_t(8), size_t(24), size_t(28), size_t(32), size_t(40)}) {
            damaged = root; damaged[offset] ^= 1;
            auto rehashed = b; rehashed.root_hash = rz::hash(damaged);
            rejects([&] { (void)rz::parse_page_root(rehashed, damaged); }, "root identity field not independently validated");
        }
        for (bool parity : {false, true}) {
            for (bool footer : {false, true}) {
                auto header = rz::make_paged_header(b, parity, 0, footer);
                auto h = rz::parse_paged_header(header, footer);
                require(h.profile == 5 && h.parity == parity && h.uuid == b.manifest.uuid,
                        "volume header identity changed");
                require(h.payload_size == (b.layout.data_stripes + b.layout.index_stripes) * rz::PagedRecordSize,
                        "volume payload size excludes protected index");
                require(h.manifest_hash == rz::hash(rz::serialize_bootstrap(b)), "header does not bind bootstrap");
                rejects([&] { (void)rz::parse_paged_header(header, !footer); }, "header/footer role substitution accepted");
                for (size_t i = 0; i < header.size(); ++i) {
                    auto changed = header; changed[i] ^= 1;
                    rejects([&] { (void)rz::parse_paged_header(changed, footer); }, "damaged header checksum accepted");
                }
                auto field = [&](size_t offset, uint64_t value, size_t width) {
                    auto changed = header; put(changed, offset, value, width);
                    auto digest = rz::hash(changed.data(), changed.size() - 32);
                    std::copy(digest.begin(), digest.end(), changed.end() - 32);
                    rejects([&] { (void)rz::parse_paged_header(changed, footer); }, "malformed rechecksummed header accepted");
                };
                field(8, 4, 4); field(12, 2, 4); field(32, 100, 4); field(36, 1, 4);
                field(40, 143, 8); field(40, rz::MaxBootstrap + 1, 8);
                field(48, 0, 8); field(48, UINT64_MAX, 8); field(48, h.payload_size + 1, 8);
            }
        }
    }
    rz::UUID uuid{}; rz::Bytes block(rz::BlockSize, 73);
    const auto baseline = rz::index_block_hash(uuid, 0, 0, block);
    require(baseline != rz::block_hash_v2(uuid, 0, 0, block), "index and content block hash domains collide");
    require(baseline != rz::index_block_hash(uuid, 1, 0, block), "index stripe absent from hash domain");
    require(baseline != rz::index_block_hash(uuid, 0, 1, block), "index column absent from hash domain");
    uuid[0] = 1; require(baseline != rz::index_block_hash(uuid, 0, 0, block), "archive identity absent from index hash");
}
void authentication() {
    for (auto suite : {rz::CryptoProfile, rz::DualCryptoProfile}) {
        if (suite == rz::DualCryptoProfile && !rz::aes_available()) continue;
        auto b = bootstrap(rz::MaxPagedOutput); auto credential = rz::generate_recovery_key();
        credential.archive_uuid = b.manifest.uuid;
        auto& security = b.manifest.security; security.encrypted = true;
        security.key_slot.key_file = true; security.key_slot.suite = suite;
        auto keys = rz::create_keys(b.manifest.uuid, credential, security.key_slot, rz::MaxPagedOutput);
        security.public_mac = keys.manifest_mac(rz::serialize_bootstrap(b));
        auto valid = rz::serialize_bootstrap(b); auto parsed = rz::parse_bootstrap(valid);
        require(rz::authenticate_manifest(parsed.manifest, &credential).has_value(), "parsed profile 5 authentication failed");
        require(rz::serialize_bootstrap(parsed) == valid, "encrypted bootstrap roundtrip changed bytes");
        auto zeroed = parsed; zeroed.manifest.security.public_mac.fill(0);
        require(parsed.manifest.authentication_bytes == rz::serialize_bootstrap(zeroed), "runtime authentication bytes do not zero only the MAC");
        const auto mac_last = valid.size() - 4 - b.index_volume_hashes.size() * 32 - 1;
        for (size_t offset : {size_t(80), size_t(112), mac_last, valid.size() - 1}) {
            auto changed = valid; changed[offset] ^= offset == 112 ? 2 : 1;
            auto forged = rz::parse_bootstrap(changed);
            rejects([&] { (void)rz::authenticate_manifest(forged.manifest, &credential); }, "modified authenticated bootstrap accepted");
        }
        for (auto [offset, width] : {std::pair{size_t(144), size_t(4)}, std::pair{size_t(148), size_t(8)}, std::pair{size_t(156), size_t(8)}}) {
            auto changed = valid; put(changed, offset, UINT32_MAX, width);
            rejects([&] { (void)rz::parse_bootstrap(changed); }, "unsupported encryption/KDF parameter accepted");
        }
        auto missing = parsed.manifest; missing.authentication_bytes.clear();
        rejects([&] { (void)rz::authenticate_manifest(missing, &credential); }, "missing authentication bootstrap accepted");
        missing.authentication_bytes.resize(rz::MaxBootstrap + 1);
        rejects([&] { (void)rz::authenticate_manifest(missing, &credential); }, "unbounded authentication bootstrap accepted");
        auto wrong = rz::generate_recovery_key(); wrong.archive_uuid = b.manifest.uuid;
        rejects([&] { (void)rz::authenticate_manifest(parsed.manifest, &wrong); }, "wrong recovery key authenticated profile 5");
    }
}
void legacy_limit() {
    rz::binary::Writer w; rz::Entry entry; entry.path = "large"; entry.size = rz::MaxOutput + 1;
    uint64_t offset = 0;
    while (offset < entry.size) {
        const auto size = static_cast<uint32_t>(std::min<uint64_t>(rz::FrameSize, entry.size - offset));
        entry.frames.push_back({offset, size, size}); offset += size;
    }
    rz::binary::write_entries(w, {entry});
    rz::binary::Reader old{w.b};
    rejects([&] { (void)rz::binary::read_entries(old, entry.size); }, "legacy entry parser lost 64 GiB cap");
    rz::binary::Reader paged{w.b}; auto entries = rz::binary::read_entries(paged, entry.size, 0, rz::MaxPagedOutput);
    require(entries.size() == 1 && entries.front().size == entry.size, "profile 5 cannot index content beyond 64 GiB");
    paged.end();
}
}
int main() {
    try {
        layouts(); malformed_bootstraps(); roots_and_headers(); authentication(); legacy_limit();
        std::cout << "Profile 5 1 TiB layout, bounded bootstrap/root/header parsing, authentication and legacy limits passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
