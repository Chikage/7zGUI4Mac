#include "codec.hpp"
#include "io.hpp"
#include "crypto.hpp"
#include <algorithm>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
extern "C" {
#include <gf_complete.h>
#include <gf_cpu.h>
#include <galois.h>
#include <jerasure.h>
}

namespace rz {
Digest hash(const void* data, size_t size) {
    blake3_hasher h;
    WipeMemoryOnExit cleanup(&h, sizeof h);
    blake3_hasher_init(&h);
    blake3_hasher_update(&h, data, size);
    Digest out{};
    blake3_hasher_finalize(&h, out.data(), out.size());
    return out;
}
Digest hash(const Bytes& data) { return hash(data.data(), data.size()); }
std::string hex(const Digest& d) {
    constexpr char digits[] = "0123456789abcdef";
    std::string out;
    for (auto b : d) { out += digits[b >> 4]; out += digits[b & 15]; }
    return out;
}
Digest block_hash(const UUID& uuid, uint32_t group, uint32_t shard, uint32_t stripe, const Bytes& block) {
    blake3_hasher h;
    blake3_hasher_init(&h);
    constexpr char domain[] = "rz-block-v1";
    blake3_hasher_update(&h, domain, sizeof(domain) - 1);
    blake3_hasher_update(&h, uuid.data(), uuid.size());
    for (uint32_t v : {group, shard, stripe}) {
        uint8_t le[4];
        for (int i = 0; i < 4; ++i) le[i] = static_cast<uint8_t>(v >> (i * 8));
        blake3_hasher_update(&h, le, 4);
    }
    blake3_hasher_update(&h, block.data(), block.size());
    Digest out{};
    blake3_hasher_finalize(&h, out.data(), out.size());
    return out;
}
Bytes compress_frame(const Bytes& data) {
    Bytes out(ZSTD_compressBound(data.size())); WipeOnExit cleanup(out);
    auto n = ZSTD_compress(out.data(), out.size(), data.data(), data.size(), 3);
    if (ZSTD_isError(n)) throw std::runtime_error(ZSTD_getErrorName(n));
    out.resize(n);
    cleanup.release(); return out;
}
struct FrameDecoder::Impl {
    Impl() : storage(std::malloc(FrameDecoder::memory_usage())) {
        if (!storage) throw std::bad_alloc();
        context = ZSTD_initStaticDCtx(storage.get(), FrameDecoder::memory_usage());
        if (!context) throw std::runtime_error("Cannot initialize Zstd decoder");
    }
    struct Cleanup {
        void operator()(void* memory) const noexcept {
            if (memory) { wipe(memory, FrameDecoder::memory_usage()); std::free(memory); }
        }
    };
    std::unique_ptr<void, Cleanup> storage;
    ZSTD_DCtx* context = nullptr;
};
FrameDecoder::FrameDecoder() : impl_(std::make_unique<Impl>()) {}
FrameDecoder::~FrameDecoder() = default;
size_t FrameDecoder::memory_usage() { return ZSTD_estimateDCtxSize(); }
Bytes FrameDecoder::decode(const Bytes& data, uint32_t size) {
    check_cancel();
    if (size == 0 || size > FrameSize || data.size() > ZSTD_compressBound(FrameSize))
        throw std::runtime_error("Invalid frame size");
    if (ZSTD_findFrameCompressedSize(data.data(), data.size()) != data.size() ||
        ZSTD_getFrameContentSize(data.data(), data.size()) != size)
        throw std::runtime_error("Invalid independent Zstd frame");
    Bytes out(size); WipeOnExit cleanup(out);
    auto n = ZSTD_decompressDCtx(impl_->context, out.data(), out.size(), data.data(), data.size());
    if (ZSTD_isError(n) || n != size) throw std::runtime_error("Zstd decompression failed");
    check_cancel(); cleanup.release(); return out;
}
Bytes decompress_frame(const Bytes& data, uint32_t size) { FrameDecoder decoder; return decoder.decode(data, size); }
Digest block_hash_v2(const UUID& uuid, uint32_t group, uint32_t shard, const Bytes& block) {
    blake3_hasher h; blake3_hasher_init(&h);
    constexpr char domain[] = "rz-block-v2";
    blake3_hasher_update(&h, domain, sizeof(domain) - 1);
    blake3_hasher_update(&h, uuid.data(), uuid.size());
    for (uint32_t value : {group, shard})
        for (int i = 0; i < 4; ++i) {
            auto byte = static_cast<uint8_t>(value >> (8 * i));
            blake3_hasher_update(&h, &byte, 1);
        }
    blake3_hasher_update(&h, block.data(), block.size());
    Digest digest{}; blake3_hasher_finalize(&h, digest.data(), digest.size());
    return digest;
}

struct RecoveryEncoder::Impl {
    Impl() {
        // Detection must precede scratch sizing (NEON uses different tables).
        // All contexts are initialized by the coordinator, before worker launch.
        gf_cpu_identify();
        const auto size = gf_scratch_size(8, GF_MULT_DEFAULT, GF_REGION_DEFAULT, GF_DIVIDE_DEFAULT, 0, 0);
        if (size <= 0) throw std::runtime_error("Cannot size GF(256) context");
        scratch_size = static_cast<size_t>(size);
        scratch.reset(std::malloc(scratch_size));
        if (!scratch) throw std::bad_alloc();
        if (!gf_init_hard(&field, 8, GF_MULT_DEFAULT, GF_REGION_DEFAULT, GF_DIVIDE_DEFAULT, 0x11d, 0, 0, nullptr, scratch.get()))
            throw std::runtime_error("Cannot initialize independent GF(256) context");
        for (uint32_t r = 0; r < 128; ++r)
            for (uint32_t c = 0; c < 100; ++c)
                matrix[r * 100 + c] = static_cast<uint8_t>(field.divide.w32(&field, 1, (128 + r) ^ c));
    }
    gf_t field{};
    std::unique_ptr<void, decltype(&std::free)> scratch{nullptr, std::free};
    size_t scratch_size = 0;
    std::array<uint8_t, 128 * 100> matrix{};
};
RecoveryEncoder::RecoveryEncoder() : impl_(std::make_unique<Impl>()) {}
RecoveryEncoder::~RecoveryEncoder() = default;
size_t RecoveryEncoder::memory_usage() const { return sizeof(*this) + sizeof(Impl) + impl_->scratch_size; }
void RecoveryEncoder::encode(uint32_t k, uint32_t m, std::span<Bytes> blocks, std::stop_token stop) {
    if (k < 1 || k > 100 || m < 1 || m > 128 || blocks.size() != k + m)
        throw std::runtime_error("Invalid recovery encoding geometry");
    for (const auto& block : blocks)
        if (block.size() != BlockSize) throw std::runtime_error("Invalid recovery block size");
    for (uint32_t r = 0; r < m; ++r) {
        check_cancel();
        if (stop.stop_requested()) throw std::runtime_error("Operation cancelled");
        for (uint32_t c = 0; c < k; ++c)
            impl_->field.multiply_region.w32(&impl_->field, blocks[c].data(), blocks[k + r].data(),
                                             impl_->matrix[r * 100 + c], BlockSize, c != 0);
    }
}
ReedSolomon::ReedSolomon(uint32_t k, uint32_t m, uint32_t profile) : k_(k), m_(m) {
    if (!((profile == 1 && k == K && m == M) || (profile == 2 && k >= 1 && k <= 100 && m >= 1 && m <= 128)))
        throw std::runtime_error("Unsupported RS geometry");
    matrix_.resize(k * m);
    static std::once_flag once;
    std::call_once(once, [] {
        // Jerasure's galois_init_field sizes scratch before CPU detection. With
        // NEON the subsequent initializer may require a larger table. Let
        // gf_init_hard detect the CPU and own its scratch allocation instead.
        auto* field = static_cast<gf_t*>(std::calloc(1, sizeof(gf_t)));
        if (!field) throw std::bad_alloc();
        if (!gf_init_hard(field, 8, GF_MULT_DEFAULT, GF_REGION_DEFAULT, GF_DIVIDE_DEFAULT, 0x11d, 0, 0, nullptr, nullptr)) {
            std::free(field); throw std::runtime_error("Cannot initialize GF(256)");
        }
        galois_change_technique(field, 8);
        std::atexit([] { galois_uninit_field(8); });
    });
    for (uint32_t r = 0; r < m; ++r)
        for (uint32_t c = 0; c < k; ++c)
            matrix_[r * k + c] = galois_single_divide(1, static_cast<int>(profile == 1 ? r ^ (M + c) : (128 + r) ^ c), 8);
}
static std::vector<char*> pointers(std::span<Bytes> blocks, uint32_t expected) {
    if (blocks.size() != expected) throw std::runtime_error("Invalid RS shard count");
    std::vector<char*> p(expected);
    for (uint32_t i = 0; i < expected; ++i) {
        if (blocks[i].size() != BlockSize) throw std::runtime_error("Invalid RS block size");
        p[i] = reinterpret_cast<char*>(blocks[i].data());
    }
    return p;
}
void ReedSolomon::encode(std::span<Bytes> blocks) const {
    auto p = pointers(blocks, k_ + m_);
    auto matrix = matrix_;
    jerasure_matrix_encode(k_, m_, 8, matrix.data(), p.data(), p.data() + k_, BlockSize);
}
void ReedSolomon::decode(std::span<Bytes> blocks, const std::vector<int>& missing) const {
    if (missing.empty()) return;
    if (missing.size() > m_) throw std::runtime_error("RS capacity exceeded");
    auto erasures = missing;
    std::sort(erasures.begin(), erasures.end());
    if (erasures.front() < 0 || erasures.back() >= static_cast<int>(k_ + m_) ||
        std::adjacent_find(erasures.begin(), erasures.end()) != erasures.end())
        throw std::runtime_error("Invalid erasure indices");
    erasures.push_back(-1);
    auto p = pointers(blocks, k_ + m_);
    auto matrix = matrix_;
    // Cauchy row zero is NOT all ones. The row_k_ones shortcut must be disabled.
    if (jerasure_matrix_decode(k_, m_, 8, matrix.data(), 0, erasures.data(), p.data(), p.data() + k_, BlockSize) != 0)
        throw std::runtime_error("RS reconstruction failed");
}
}
