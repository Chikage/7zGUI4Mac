#pragma once
#include "protected.hpp"

namespace rz {
constexpr uint32_t PagedRecordSize = BlockSize + 32;
constexpr uint32_t MaxBootstrap = 8192;
constexpr uint32_t MaxPagedRoot = 1024 * 1024;
struct PagedHeader {
    UUID uuid{};
    bool parity = false;
    uint32_t volume = 0;
    uint64_t manifest_size = 0, payload_size = 0;
    Digest manifest_hash{};
};
struct PagedLayout {
    uint64_t data_stripes = 0, index_stripes = 0;
    uint32_t hash_pages = 0;
    uint64_t root_size = 0;
};
struct PagedBootstrap {
    ArchiveManifest manifest;
    PagedLayout layout;
    Digest root_hash{};
    std::vector<Digest> index_volume_hashes;
};
PagedLayout paged_layout(uint64_t stream_size, uint32_t k, uint32_t m);
Bytes serialize_bootstrap(const PagedBootstrap& bootstrap);
PagedBootstrap parse_bootstrap(const Bytes& bytes);
Bytes serialize_page_root(const PagedBootstrap& bootstrap, const std::vector<Digest>& hashes);
std::vector<Digest> parse_page_root(const PagedBootstrap& bootstrap, const Bytes& bytes);
Digest index_block_hash(const UUID& uuid, uint32_t stripe, uint32_t column, const Bytes& block);
Bytes make_paged_header(const PagedBootstrap& bootstrap, bool parity, uint32_t volume, bool footer);
PagedHeader parse_paged_header(const Bytes& bytes, bool footer);
void create_paged_archive(const InputPlan& plan, const fs::path& output, const RecoveryOptions& options,
                          const SecurityOptions& security, bool report_progress = false, uint32_t threads = 0);
ArchiveManifest list_paged_archive(const fs::path& directory, const Password* password = nullptr);
Verification verify_paged_archive(const fs::path& directory, const Password* password = nullptr, ReadProgress* progress = nullptr);
void verify_paged_created(const fs::path& directory, const Bytes& expected_bootstrap, const ArchiveKeys* keys, uint32_t threads = 0, ReadProgress* progress = nullptr);
void repair_paged_archive(const fs::path& directory, const fs::path& output);
ExtractionReport extract_paged_archive(const fs::path& directory, const fs::path& output,
                                       const Password* password = nullptr, bool restore_attributes = true, ReadProgress* progress = nullptr);
}
