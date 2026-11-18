#pragma once
#include "paged.hpp"
#include <memory>

namespace rz {
constexpr uint32_t ContainerHeaderSize = 128;
struct ContainerHeader {
    UUID uuid{};
    uint32_t data_volumes = 0, recovery_volumes = 0;
    uint64_t bootstrap_size = 0, volume_size = 0, total_size = 0;
};
// Both storage forms expose the same profile 5 members, without unpacking the
// container or trusting member paths supplied by an archive.
class ArchiveStorage {
public:
    explicit ArchiveStorage(const fs::path& path);
    const fs::path& path() const { return path_; }
    uint64_t metadata_issues() const { return metadata_issues_; }
    std::vector<fs::path> volumes() const;
    std::unique_ptr<File> open(const fs::path& name, File::Mode mode = File::Mode::Read, bool optional = true) const;
    void validate(const PagedBootstrap& bootstrap, size_t encoded_size) const;
private:
    fs::path path_;
    std::shared_ptr<File> container_;
    ContainerHeader header_;
    uint64_t metadata_issues_ = 0;
};
// Consume the private staged members, keeping copy memory bounded to 1 MiB.
fs::path pack_container(const fs::path& stage, const PagedBootstrap& bootstrap, size_t encoded_size);
}
