#pragma once
#include "codec.hpp"
#include <filesystem>

namespace rz {
namespace fs = std::filesystem;
constexpr uint64_t MaxManifest = 16 * 1024 * 1024;
constexpr uint64_t MaxVolume = 1024ULL * 1024 * 1024;
constexpr uint64_t MaxOutput = 64ULL * 1024 * 1024 * 1024;
// Profile 5 alone opts into the larger limit. Legacy readers retain MaxOutput.
constexpr uint64_t MaxPagedOutput = 1024ULL * 1024 * 1024 * 1024;
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
struct Group {
    uint32_t stripes = 0;
    uint64_t valid = 0;
    // shard-major, then stripe number
    std::vector<Digest> hashes;
    uint64_t span() const { return uint64_t(stripes) * BlockSize; }
};
struct Manifest {
    UUID uuid{};
    uint64_t stream_size = 0;
    std::vector<Group> groups;
    std::vector<Entry> entries;
};
struct Header {
    UUID uuid{};
    uint32_t group = 0, shard = 0;
    uint64_t manifest_size = 0, payload_size = 0;
    Digest manifest_hash{};
};
void validate_path(const std::string& path);
Bytes serialize(const Manifest& manifest);
Manifest parse_manifest(const Bytes& data);
Bytes make_header(const Header& header, bool footer);
Header parse_header(const Bytes& data, bool footer);
std::string volume_name(uint32_t group, uint32_t shard);
}
