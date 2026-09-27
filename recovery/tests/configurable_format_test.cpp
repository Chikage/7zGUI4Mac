#include "configurable.hpp"
#include <iostream>
#include <random>
#include <stdexcept>

static void require(bool ok, const char* what) { if (!ok) throw std::runtime_error(what); }
template<class F> static void rejects(F action) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Invalid configuration was accepted");
}
static rz::Manifest synthetic(uint64_t size) {
    rz::Manifest m; m.stream_size = size;
    rz::Entry entry; entry.path = "data"; entry.size = size; entry.digest = rz::hash(nullptr, 0);
    for (uint64_t offset = 0; offset < size;) {
        auto length = static_cast<uint32_t>(std::min<uint64_t>(rz::FrameSize, size - offset));
        entry.frames.push_back({offset, length, length}); offset += length;
    }
    m.entries.push_back(std::move(entry)); return m;
}
int main() {
    try {
        for (uint64_t blocks = 1; blocks <= 301; ++blocks) {
            for (uint64_t percent : {100, 101, 750, 3333, 10000}) {
                rz::RecoveryOptions options{1572864, rz::RecoveryMode::Percent, percent};
                auto m = rz::configure(synthetic(blocks * rz::BlockSize), options);
                require(m.recovery_blocks == (blocks * percent + 9999) / 10000, "Rounded budget mismatch");
                uint64_t data = 0, parity = 0;
                for (const auto& g : m.groups) {
                    require(g.k >= 1 && g.k <= 100 && g.m >= 1 && g.m <= g.k, "Group budget bounds");
                    data += g.k; parity += g.m;
                }
                require(data == blocks && parity == m.recovery_blocks, "Budget allocation sum");
                auto encoded = rz::serialize(m);
                require(rz::serialize(rz::parse_configurable_manifest(encoded)) == encoded, "Profile 2 roundtrip");
                for (bool p : {false, true}) {
                    uint64_t sum = 0;
                    for (uint32_t i = 0; i < m.volume_count(p); ++i) {
                        auto payload = m.payload_size(p, i); sum += payload;
                        require(payload + 2 * encoded.size() + 2 * rz::HeaderSize <= options.volume_size, "Volume cap exceeded");
                    }
                    require(sum == (p ? parity : data) * rz::BlockSize, "Physical payload mismatch");
                }
            }
        }
        rejects([] { rz::configure(synthetic(101 * rz::BlockSize), {1572864, rz::RecoveryMode::Bytes, 1}); });
        rejects([] { rz::configure(synthetic(rz::BlockSize), {1572864, rz::RecoveryMode::Bytes, rz::BlockSize + 1}); });
        for (uint32_t k : {1U, 2U, 7U, 100U}) {
            for (uint32_t parity : {1U, k}) {
                for (uint64_t size : {uint64_t(1), uint64_t(k) * rz::BlockSize - 1, uint64_t(k) * rz::BlockSize,
                                      uint64_t(k) * rz::BlockSize + 1}) {
                    rz::SecurityInfo security;
                    security.index_plain_size = 1; security.index_frames.push_back({size - 1, 1, 1});
                    auto counted = rz::configure(synthetic(size), {0, rz::RecoveryMode::Volumes, 0, k, parity}, &security);
                    auto bytes = rz::serialize(counted);
                    require(rz::serialize(rz::parse_configurable_manifest(bytes)) == bytes, "Profile 4 roundtrip");
                    auto stripes = (size + uint64_t(k) * rz::BlockSize - 1) / (uint64_t(k) * rz::BlockSize);
                    require(counted.profile == 4 && counted.groups.size() == stripes, "Counted stripe allocation");
                    require(counted.volume_count(false) == k && counted.volume_count(true) == parity, "Exact physical counts");
                    for (bool p : {false, true})
                        for (uint32_t v = 0; v < counted.volume_count(p); ++v)
                            require(counted.payload_size(p, v) == stripes * rz::BlockSize, "Equal data/recovery payloads");
                    for (size_t offset : {36, 40, 48, 56, 60, 64, 76, 84, 92, 96, 100}) {
                        auto invalid = bytes; invalid[offset] ^= 255;
                        rejects([&] { (void)rz::parse_configurable_manifest(invalid); });
                    }
                    for (bool footer : {false, true}) {
                        rz::ConfigurableHeader h{counted.uuid, true, parity - 1, bytes.size(), counted.payload_size(true, 0), rz::hash(bytes), 4};
                        require(rz::parse_configurable_header(rz::make_header(h, footer), footer).profile == 4, "Profile 4 header roundtrip");
                    }
                }
            }
        }
        auto m = rz::configure(synthetic(101 * rz::BlockSize), {1572864, rz::RecoveryMode::Percent, 750});
        auto valid = rz::serialize(m);
        for (size_t size = 0; size < valid.size(); size += 17) {
            rz::Bytes cut(valid.begin(), valid.begin() + size);
            rejects([&] { (void)rz::parse_configurable_manifest(cut); });
        }
        for (size_t offset : {24, 28, 32, 36, 56, 68, 76, 84, 88, 92}) {
            auto bytes = valid; bytes[offset] ^= 255;
            rejects([&] { (void)rz::parse_configurable_manifest(bytes); });
        }
        std::mt19937 rng(42);
        for (int i = 0; i < 2000; ++i) {
            auto bytes = valid; bytes[rng() % bytes.size()] ^= static_cast<uint8_t>(rng());
            try { (void)rz::parse_configurable_manifest(bytes); } catch (const std::runtime_error&) {}
        }
        rz::ConfigurableHeader h{m.uuid, true, 0, valid.size(), m.payload_size(true, 0), rz::hash(valid)};
        for (bool footer : {false, true}) {
            auto b = rz::make_header(h, footer);
            require(rz::parse_configurable_header(b, footer).manifest_hash == h.manifest_hash, "Header roundtrip");
            for (size_t i = 0; i < b.size(); ++i) {
                auto changed = b; changed[i] ^= 1;
                rejects([&] { (void)rz::parse_configurable_header(changed, footer); });
            }
        }
        std::cout << "1505 allocation/cap cases, format bounds and mutation checks passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
