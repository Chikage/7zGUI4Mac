#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <span>
#include <vector>
#include <memory>
#include <stop_token>
#include <blake3.h>

namespace rz {
using Bytes = std::vector<uint8_t>;
using Digest = std::array<uint8_t, 32>;
using UUID = std::array<uint8_t, 16>;
constexpr uint32_t MaxDataShards = 100;
constexpr uint32_t BlockSize = 64 * 1024, FrameSize = 4 * 1024 * 1024;
void validate_volume_counts(uint32_t k, uint32_t m);

Digest hash(const void* data, size_t size);
Digest hash(const Bytes& data);
std::string hex(const Digest& digest);
Digest data_block_hash(const UUID& uuid, uint32_t group, uint32_t shard, const Bytes& block);
Bytes compress_frame(const Bytes& data);
Bytes decompress_frame(const Bytes& data, uint32_t size);

// A complete independent frame decoder; one context per worker. Context storage
// and failed output buffers are wiped before release, including on cancellation.
class FrameDecoder {
public:
    FrameDecoder();
    ~FrameDecoder();
    FrameDecoder(const FrameDecoder&) = delete;
    FrameDecoder& operator=(const FrameDecoder&) = delete;
    Bytes decode(const Bytes& data, uint32_t size);
    static size_t memory_usage();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Process-scoped Jerasure field state is initialized once. CLI operations are serial.
// Systematic Cauchy, GF(256)/0x11d, A[row,col] = inv((128+row) XOR col).
class ReedSolomon {
public:
    ReedSolomon(uint32_t k, uint32_t m);
    void encode(std::span<Bytes> blocks) const;
    void decode(std::span<Bytes> blocks, const std::vector<int>& missing) const;
private:
    uint32_t k_, m_;
    std::vector<int> matrix_;
};

// Parallel encoder with no Jerasure calls or shared mutable field state.
// Construct contexts serially before starting workers; one instance per worker.
class RecoveryEncoder {
public:
    RecoveryEncoder();
    ~RecoveryEncoder();
    RecoveryEncoder(const RecoveryEncoder&) = delete;
    RecoveryEncoder& operator=(const RecoveryEncoder&) = delete;
    void encode(uint32_t k, uint32_t m, std::span<Bytes> blocks, std::stop_token stop = {});
    size_t memory_usage() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
