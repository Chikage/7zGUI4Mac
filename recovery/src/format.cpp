#include "format.hpp"
#include "binary.hpp"
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>

namespace rz {
void validate_path(const std::string& path) {
    if (path.empty() || path.size() > 4096 || path.front() == '/' || path.back() == '/')
        throw std::runtime_error("Unsafe archive path");
    for (size_t i = 0; i < path.size();) {
        auto c = static_cast<uint8_t>(path[i++]);
        if (c < 32 || c == 127 || c == '\\' || c == ':') throw std::runtime_error("Unsupported archive filename");
        if (c < 128) continue;
        unsigned extra; uint32_t value, minimum;
        if (c >= 0xc2 && c <= 0xdf) { extra = 1; value = c & 31; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { extra = 2; value = c & 15; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { extra = 3; value = c & 7; minimum = 0x10000; }
        else throw std::runtime_error("Filename is not UTF-8");
        while (extra--) {
            if (i == path.size()) throw std::runtime_error("Truncated UTF-8 filename");
            auto b = static_cast<uint8_t>(path[i++]);
            if ((b & 0xc0) != 0x80) throw std::runtime_error("Invalid UTF-8 filename");
            value = (value << 6) | (b & 63);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff))
            throw std::runtime_error("Invalid UTF-8 filename");
    }
    size_t start = 0;
    while (start < path.size()) {
        auto end = path.find('/', start);
        auto part = path.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") throw std::runtime_error("Unsafe path component");
        if (end == std::string::npos) break;
        start = end + 1;
    }
}
std::string volume_name(bool parity, uint32_t index) {
    std::ostringstream s;
    s << (parity ? 'p' : 'd') << std::setfill('0') << std::setw(6) << index << (parity ? ".rzr" : ".rzv");
    return s.str();
}
}

namespace rz::binary {
void write_entries(Writer& w, const std::vector<Entry>& entries) {
    w.u32(static_cast<uint32_t>(entries.size()));
    for (const auto& e : entries) {
        w.u32(e.directory ? 1 : 0); w.u32(static_cast<uint32_t>(e.path.size())); w.raw(e.path.data(), e.path.size());
        w.u64(e.size); w.raw(e.digest.data(), 32); w.u32(static_cast<uint32_t>(e.frames.size()));
        for (const auto& f : e.frames) { w.u64(f.offset); w.u32(f.stored); w.u32(f.plain); }
    }
}
std::vector<Entry> read_entries(Reader& r, uint64_t stream_size, uint64_t initial_offset) {
    const auto& b = r.b;
    std::vector<Entry> result;
    auto entries = r.u32();
    if (entries > 100000 || entries > (b.size() - r.p) / 53) throw std::runtime_error("Invalid entry count");
    std::map<std::string, bool> paths;
    uint64_t next_offset = initial_offset, output_size = 0;
    for (uint32_t i = 0; i < entries; ++i) {
        Entry e; auto kind = r.u32();
        if (kind > 1) throw std::runtime_error("Unknown entry kind");
        e.directory = kind == 1;
        auto length = r.u32();
        if (length == 0 || length > 4096) throw std::runtime_error("Invalid path length");
        e.path.resize(length); r.raw(e.path.data(), length); validate_path(e.path);
        if (!result.empty() && result.back().path >= e.path) throw std::runtime_error("Unsorted or duplicate paths");
        auto slash = e.path.rfind('/');
        if (slash != std::string::npos) {
            auto parent = paths.find(e.path.substr(0, slash));
            if (parent == paths.end() || !parent->second) throw std::runtime_error("Missing directory parent");
        }
        paths.emplace(e.path, e.directory);
        e.size = r.u64(); r.raw(e.digest.data(), 32);
        if (e.size > MaxOutput - output_size) throw std::runtime_error("Output exceeds profile content limit");
        output_size += e.size;
        auto frames = r.u32();
        if (frames > (b.size() - r.p) / 16 || frames != (e.size + FrameSize - 1) / FrameSize)
            throw std::runtime_error("Invalid frame count");
        uint64_t plain = 0;
        for (uint32_t j = 0; j < frames; ++j) {
            Frame f{r.u64(), r.u32(), r.u32()};
            if (f.offset != next_offset || f.stored == 0 || f.stored > FrameSize + FrameSize / 100 ||
                f.plain == 0 || f.plain > FrameSize || (j + 1 < frames && f.plain != FrameSize))
                throw std::runtime_error("Invalid frame mapping");
            next_offset += f.stored; plain += f.plain; e.frames.push_back(f);
        }
        if (plain != e.size || (e.directory && e.size != 0)) throw std::runtime_error("Invalid entry size");
        if (e.size == 0 && e.digest != hash(nullptr, 0)) throw std::runtime_error("Invalid empty entry digest");
        result.push_back(std::move(e));
    }
    if (next_offset != stream_size) throw std::runtime_error("Invalid indexed stream length");
    return result;
}
}
