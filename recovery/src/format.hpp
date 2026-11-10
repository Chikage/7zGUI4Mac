#pragma once
#include "codec.hpp"
#include <filesystem>

namespace rz {
namespace fs = std::filesystem;
constexpr uint64_t MaxManifest = 16 * 1024 * 1024;
constexpr uint32_t FormatVersion = 5;
constexpr uint64_t MaxOutput = 1024ULL * 1024 * 1024 * 1024;
constexpr uint64_t MaxStream = MaxOutput + MaxOutput / 100;
constexpr uint32_t HeaderSize = 120;
struct Frame { uint64_t offset; uint32_t stored, plain; };
struct Entry {
    bool directory = false;
    std::string path;
    uint64_t size = 0;
    Digest digest{};
    std::vector<Frame> frames;
    uint64_t metadata_size = 0;
    Digest metadata_digest{};
    std::vector<Frame> metadata_frames;
};
struct PackedContents {
    UUID uuid{};
    uint64_t stream_size = 0;
    std::vector<Entry> entries;
};
void validate_path(const std::string& path);
std::string volume_name(bool parity, uint32_t index);
}
