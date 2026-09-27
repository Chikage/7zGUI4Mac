#pragma once
#include "format.hpp"
#include <cstring>
#include <stdexcept>

namespace rz::binary {
struct Writer {
    Bytes b;
    size_t limit = MaxManifest;
    void raw(const void* p, size_t n) {
        if (b.size() > limit || n > limit - b.size()) throw std::runtime_error("Serialized record exceeds limit");
        if (n == 0) return;
        auto q = static_cast<const uint8_t*>(p); b.insert(b.end(), q, q + n);
    }
    void u32(uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i))); }
    void u64(uint64_t v) { for (int i = 0; i < 8; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i))); }
};
struct Reader {
    const Bytes& b; size_t p = 0;
    void raw(void* out, size_t n) {
        if (n > b.size() - p) throw std::runtime_error("Truncated metadata");
        std::memcpy(out, b.data() + p, n); p += n;
    }
    uint32_t u32() { uint8_t v[4]; raw(v, 4); uint32_t x = 0; for (int i = 0; i < 4; ++i) x |= uint32_t(v[i]) << (8 * i); return x; }
    uint64_t u64() { uint8_t v[8]; raw(v, 8); uint64_t x = 0; for (int i = 0; i < 8; ++i) x |= uint64_t(v[i]) << (8 * i); return x; }
    void magic(const char* value) { char v[8]; raw(v, 8); if (std::memcmp(v, value, 8)) throw std::runtime_error("Unknown format"); }
    void end() { if (p != b.size()) throw std::runtime_error("Trailing metadata bytes"); }
};
void write_entries(Writer& writer, const std::vector<Entry>& entries);
std::vector<Entry> read_entries(Reader& reader, uint64_t stream_size, uint64_t initial_offset = 0, uint64_t max_output = MaxOutput);
}
