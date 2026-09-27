#include "codec.hpp"
#include "format.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>

// Independent, bit-at-a-time field arithmetic: a format oracle, not Jerasure.
static uint8_t multiply(uint8_t a, uint8_t b) {
    unsigned x = a, y = b, out = 0;
    while (y) { if (y & 1) out ^= x; y >>= 1; x <<= 1; if (x & 256) x ^= 0x11d; }
    return static_cast<uint8_t>(out);
}
static uint8_t inverse(uint8_t x) {
    uint8_t result = 1;
    for (int i = 0; i < 254; ++i) result = multiply(result, x);
    return result;
}
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    try {
        require(rz::hex(rz::hash(nullptr, 0)) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", "BLAKE3 empty golden vector");
        require(rz::hex(rz::hash("abc", 3)) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85", "BLAKE3 abc golden vector");
        rz::Stripe original;
        for (uint32_t i = 0; i < rz::N; ++i) {
            original[i].resize(rz::BlockSize);
            if (i < rz::K) for (uint32_t j = 0; j < rz::BlockSize; ++j)
                original[i][j] = static_cast<uint8_t>((j * 37 + i * 19) ^ (j >> (i % 5)));
        }
        rz::ReedSolomon rs; rs.encode(original);
        for (uint32_t r = 0; r < rz::M; ++r) {
            std::array<uint8_t, rz::K> coefficients{};
            for (uint32_t c = 0; c < rz::K; ++c) coefficients[c] = inverse(static_cast<uint8_t>(r ^ (rz::M + c)));
            for (uint32_t b = 0; b < rz::BlockSize; ++b) {
                uint8_t parity = 0;
                for (uint32_t c = 0; c < rz::K; ++c)
                    parity ^= multiply(coefficients[c], original[c][b]);
                require(parity == original[rz::K + r][b], "Jerasure differs from profile oracle");
            }
        }
        for (int a = 0; a < static_cast<int>(rz::N); ++a) {
            auto damaged = original; std::fill(damaged[a].begin(), damaged[a].end(), 0);
            rs.decode(damaged, {a}); require(damaged == original, "single erasure");
            for (int b = a + 1; b < static_cast<int>(rz::N); ++b) {
                damaged = original; std::fill(damaged[a].begin(), damaged[a].end(), 0); std::fill(damaged[b].begin(), damaged[b].end(), 0);
                rs.decode(damaged, {a, b}); require(damaged == original, "double erasure");
            }
        }
        bool rejected = false;
        try { rs.decode(original, {0, 1, 2}); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "three erasures must be rejected");
        // Profile 2: independently check the stable Cauchy rows and reconstruct
        // up to the full configured budget, including all data columns at 100%.
        for (auto [k, m] : {std::pair<uint32_t, uint32_t>{1, 1}, {7, 3}, {100, 1}, {100, 20}, {100, 100}}) {
            std::vector<rz::Bytes> blocks(k + m, rz::Bytes(rz::BlockSize));
            for (uint32_t c = 0; c < k; ++c)
                for (uint32_t i = 0; i < rz::BlockSize; ++i) blocks[c][i] = static_cast<uint8_t>(i * 17 + c * 31 + (i >> (c % 5)));
            rz::ReedSolomon engine(k, m, 2); engine.encode(blocks);
            for (uint32_t row = 0; row < m; ++row) {
                std::vector<uint8_t> coefficients(k);
                for (uint32_t c = 0; c < k; ++c) coefficients[c] = inverse(static_cast<uint8_t>((128 + row) ^ c));
                for (uint32_t b = 0; b < 256; ++b) {
                    uint8_t expected = 0;
                    for (uint32_t c = 0; c < k; ++c)
                        expected ^= multiply(coefficients[c], blocks[c][b]);
                    require(blocks[k + row][b] == expected, "Profile 2 differs from independent GF oracle");
                }
            }
            auto complete = blocks; std::vector<int> missing;
            for (uint32_t i = 0; i < m; ++i) { missing.push_back(static_cast<int>(i)); std::fill(blocks[i].begin(), blocks[i].end(), 0); }
            engine.decode(blocks, missing); require(blocks == complete, "Profile 2 erasure budget");
            if (m > 1) {
                auto fewer = std::vector<rz::Bytes>(complete.begin(), complete.begin() + k);
                fewer.resize(k + 1, rz::Bytes(rz::BlockSize)); rz::ReedSolomon(k, 1, 2).encode(fewer);
                require(fewer[k] == complete[k], "Parity row must not depend on total m");
            }
        }
        auto frame = rz::compress_frame(original[0]);
        require(rz::decompress_frame(frame, rz::BlockSize) == original[0], "Zstd frame round-trip");
        frame.push_back(0); rejected = false;
        try { (void)rz::decompress_frame(frame, rz::BlockSize); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "trailing bytes in frame must fail");
        std::cout << "BLAKE3 vectors, both GF profiles, legacy 12 single/66 double erasures, stable rows and frame bounds passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
