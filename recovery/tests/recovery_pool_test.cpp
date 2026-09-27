#include "recovery_pool.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
uint8_t multiply(uint8_t a, uint8_t b) {
    unsigned x = a, y = b, value = 0;
    while (y) { if (y & 1) value ^= x; y >>= 1; x <<= 1; if (x & 256) x ^= 0x11d; }
    return static_cast<uint8_t>(value);
}
uint8_t inverse(uint8_t value) {
    uint8_t result = 1;
    for (int i = 0; i < 254; ++i) result = multiply(result, value);
    return result;
}
rz::Digest old_block_hash(const rz::UUID& uuid, uint32_t group, uint32_t shard, const rz::Bytes& block) {
    rz::Bytes bytes{'r','z','-','b','l','o','c','k','-','v','2'};
    bytes.insert(bytes.end(), uuid.begin(), uuid.end());
    for (uint32_t value : {group, shard})
        for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<uint8_t>(value >> (8 * i)));
    bytes.insert(bytes.end(), block.begin(), block.end()); return rz::hash(bytes);
}
void golden(bool race_check) {
    rz::RecoveryEncoder encoder;
    for (auto [k, m] : {std::pair<uint32_t, uint32_t>{1, 1}, {7, 3}, {100, 1}, {100, 20}, {100, 100}, {1, 128}}) {
        if (race_check && k == 100 && m == 100) continue;
        std::vector<rz::Bytes> blocks(k + m, rz::Bytes(rz::BlockSize));
        for (uint32_t c = 0; c < k; ++c)
            for (uint32_t i = 0; i < rz::BlockSize; ++i) blocks[c][i] = static_cast<uint8_t>(i * 31 + c * 17);
        auto legacy = blocks; rz::ReedSolomon(k, m, 2).encode(legacy);
        encoder.encode(k, m, blocks);
        require(blocks == legacy, "parity must match Jerasure byte for byte");
        for (uint32_t r = 0; r < m; ++r) {
            std::array<uint8_t, 256> expected{};
            for (uint32_t c = 0; c < k; ++c) {
                auto coefficient = inverse(static_cast<uint8_t>((128 + r) ^ c));
                for (size_t b = 0; b < expected.size(); ++b) expected[b] ^= multiply(coefficient, blocks[c][b]);
            }
            for (uint32_t b = 0; b < rz::BlockSize; ++b)
                require(blocks[k + r][b] == expected[b % expected.size()], "independent GF polynomial/Cauchy oracle");
        }
        // A second use must overwrite old parity rather than XOR it twice.
        if (!race_check || k <= 7) {
            encoder.encode(k, m, blocks); require(blocks == legacy, "reusable context resets parity output");
        }
        bool rejected = false; std::stop_source stop; stop.request_stop();
        try { encoder.encode(k, m, blocks, stop.get_token()); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "in-flight encoding cancellation token");
    }
    bool rejected = false;
    std::vector<rz::Bytes> short_blocks(2, rz::Bytes(12));
    try { encoder.encode(1, 1, short_blocks); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "invalid block shape");
}
void pools(bool race_check) {
    const auto uuid = rz::random_uuid();
    auto root = rz::fs::temp_directory_path() / ("rz-recovery-pool-" + rz::hex(rz::hash(uuid.data(), uuid.size())));
    struct Cleanup { rz::fs::path path; ~Cleanup() { std::error_code error; rz::fs::remove_all(path, error); } } cleanup{root};
    rz::fs::create_directory(root);
    const uint64_t size = 302ULL * rz::BlockSize + 17; // Four groups, partial final block and tail group.
    {
        rz::File file(root / "stream", rz::File::Mode::New); rz::Bytes block(rz::BlockSize);
        for (uint64_t offset = 0; offset < size; offset += rz::BlockSize) {
            for (size_t i = 0; i < block.size(); ++i) block[i] = static_cast<uint8_t>(i * 37 + offset / rz::BlockSize * 13);
            file.append(block.data(), std::min<uint64_t>(block.size(), size - offset));
        }
    }
    rz::File source(root / "stream");
    // Counted-volume scheduling uses K+M to account for memory and amortizes
    // automatic workers over useful work, rather than spawning per physical file.
    for (uint32_t k : {1U, 4U, 100U}) {
        std::vector<rz::CodingGroup> groups(128, {k, k, {}});
        rz::RecoveryPool pool(source, uint64_t(128) * k * rz::BlockSize - 17, uuid, groups, 64, true);
        require(pool.limits().estimated_bytes <= rz::RecoveryMemoryBudget, "counted worker memory cap");
        if (k == 100) require(pool.limits().workers < 64, "wide counted stripes reduce parallelism");
    }
    {
        std::vector<rz::CodingGroup> groups(1, {10, 2, {}});
        rz::RecoveryPool pool(source, 17, uuid, groups, 0, true);
        require(pool.limits().workers == 1, "one padded stripe starts one worker");
        pool.submit_next(); auto job = pool.take();
        for (uint32_t s = 1; s < 10; ++s)
            require(std::all_of(job->blocks[s].begin(), job->blocks[s].end(), [](auto b) { return b == 0; }), "unused data shards are zero padded");
    }
    for (uint64_t percent : {100, 2000, 10000}) {
        if (race_check && percent == 10000) continue;
        rz::Manifest packed; packed.uuid = uuid; packed.stream_size = size;
        auto manifest = rz::configure(std::move(packed), {1024 * 1024, rz::RecoveryMode::Percent, percent});
        for (uint32_t threads : {1U, 4U, 0U}) {
            if (race_check && percent == 2000 && threads != 4) continue;
            rz::RecoveryPool pool(source, size, uuid, manifest.groups, threads);
            require(pool.limits().estimated_bytes <= rz::RecoveryMemoryBudget, "recovery memory budget");
            require(pool.limits().workers <= manifest.groups.size(), "workers capped by useful group count");
            size_t submitted = 0, completed = 0; uint64_t data_start = 0, parity_start = 0;
            auto take = [&] {
                auto job = pool.take();
                require(job->index == completed && job->data_start == data_start && job->parity_start == parity_start, "ordered group offsets");
                std::vector<rz::Bytes> expected(job->k + job->m, rz::Bytes(rz::BlockSize));
                for (uint32_t s = 0; s < job->k; ++s) {
                    const auto offset = (data_start + s) * rz::BlockSize;
                    const auto length = std::min<uint64_t>(rz::BlockSize, size - offset);
                    require(source.read(offset, expected[s].data(), length), "oracle source read");
                }
                rz::ReedSolomon(job->k, job->m, 2).encode(expected);
                require(job->blocks == expected, "pool payload matches the serial encoder including zero padding");
                for (uint32_t s = 0; s < expected.size(); ++s)
                    require(job->hashes[s] == old_block_hash(uuid, job->index, s, expected[s]), "block digest domain and identity");
                // Reconstruct selected erasures with the legacy decoder. Full
                // budget reconstruction is covered by the archive fault tests.
                std::vector<int> missing;
                for (uint32_t s = 0; s < std::min(job->m, 3U); ++s) { missing.push_back(s); std::fill(expected[s].begin(), expected[s].end(), 0); }
                rz::ReedSolomon(job->k, job->m, 2).decode(expected, missing);
                require(expected == job->blocks, "legacy decode of parallel parity");
                data_start += job->k; parity_start += job->m; ++completed;
            };
            while (!pool.full()) { pool.submit_next(); ++submitted; }
            bool rejected = false;
            try { pool.submit_next(); } catch (const std::runtime_error&) { rejected = true; }
            require(rejected, "completed groups must still occupy queue slots");
            while (submitted < manifest.groups.size()) { take(); pool.submit_next(); ++submitted; }
            while (!pool.empty()) take();
            require(completed == manifest.groups.size() && pool.peak_jobs() <= pool.limits().slots, "bounded queue completion");
        }
    }
    // Budget cap under the most expensive geometry, without allocating the data.
    std::vector<rz::CodingGroup> many(100, {100, 100, {}});
    {
        rz::RecoveryPool pool(source, 10000ULL * rz::BlockSize, uuid, many, 64);
        require(pool.limits().workers < 64 && pool.limits().estimated_bytes <= rz::RecoveryMemoryBudget, "large thread request memory cap");
    }
    bool failed = false;
    try {
        rz::RecoveryPool pool(source, 10000ULL * rz::BlockSize, uuid, many, 4);
        for (int i = 0; i < 8; ++i) pool.submit_next();
        while (!pool.empty()) (void)pool.take();
    } catch (const std::runtime_error& error) { failed = std::string(error.what()) == "Compressed spool is truncated"; }
    require(failed, "worker read error must cancel peers and reach coordinator");
    {
        rz::Manifest packed; packed.stream_size = size;
        auto m = rz::configure(std::move(packed), {1024 * 1024, rz::RecoveryMode::Percent, 10000});
        rz::RecoveryPool pool(source, size, uuid, m.groups, 4);
        for (size_t i = 0; i < m.groups.size(); ++i) pool.submit_next();
        rz::interrupted.store(SIGINT); failed = false;
        try { (void)pool.take(); } catch (const std::runtime_error&) { failed = true; }
        require(failed, "signal cancellation during group work");
    }
    rz::interrupted.store(0);
    // Coordinator abandonment (for example a failed volume write) joins peers.
    { rz::RecoveryPool pool(source, 10000ULL * rz::BlockSize, uuid, many, 4); pool.submit_next(); pool.submit_next(); }
}
}
int main(int argc, char** argv) {
    // Scalar TSan focuses on shared-state/concurrency boundaries. The full wide
    // arithmetic matrix runs under Release, ASan/UBSan and NEON TSan.
    const bool race_check = argc == 2 && std::string(argv[1]) == "--race-check";
    try { golden(race_check); pools(race_check); std::cout << "Independent GF encoding, serial parity/hash compatibility, bounded groups, recovery and cancellation passed\n"; }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
