#pragma once
#include "archive.hpp"
#include "inputs.hpp"
#include "crypto.hpp"
#include "metadata.hpp"

namespace rz {
constexpr uint32_t MaxDataShards = 100;
constexpr uint64_t MaxConfigurableVolume = 16ULL * 1024 * 1024 * 1024;
constexpr uint32_t MaxPhysicalVolumes = 65536;
enum class RecoveryMode : uint32_t { Percent = 0, Bytes = 1, Volumes = 2 };
struct RecoveryOptions {
    uint64_t volume_size = 64 * 1024 * 1024;
    RecoveryMode mode = RecoveryMode::Percent;
    uint64_t value = 2000; // hundredths of a percent, or requested payload bytes
    uint32_t data_volumes = 10, recovery_volumes = 2;
};
struct CodingGroup {
    uint32_t k = 0, m = 0;
    std::vector<Digest> hashes; // data columns, then stable parity row IDs 0..m-1
};
struct SecurityInfo {
    bool encrypted = false, metadata = false;
    KeySlot key_slot;
    Digest public_mac{};
    uint64_t index_plain_size = 0;
    std::vector<Frame> index_frames;
};
struct SecurityOptions {
    bool encrypt = false, metadata = true;
    const Password* password = nullptr;
    uint32_t crypto_suite = CryptoProfile;
    bool generate_key_file = false;
};
struct ConfigurableManifest {
    UUID uuid{};
    RecoveryOptions options;
    uint32_t blocks_per_volume = 0;
    uint64_t stream_size = 0, data_blocks = 0, recovery_blocks = 0;
    std::vector<CodingGroup> groups;
    std::vector<Entry> entries;
    uint32_t profile = 2;
    SecurityInfo security;
    bool unlocked = true;
    bool directory_damaged = false; // Runtime-only state; never serialized.
    uint32_t volume_count(bool parity) const;
    uint64_t payload_size(bool parity, uint32_t volume) const;
};
struct ConfigurableHeader {
    UUID uuid{};
    bool parity = false;
    uint32_t volume = 0;
    uint64_t manifest_size = 0, payload_size = 0;
    Digest manifest_hash{};
    uint32_t profile = 2;
};
void validate_options(const RecoveryOptions& options);
ConfigurableManifest configure(Manifest packed, const RecoveryOptions& options, const SecurityInfo* security = nullptr);
Bytes serialize(const ConfigurableManifest& manifest);
ConfigurableManifest parse_configurable_manifest(const Bytes& bytes);
Bytes make_header(const ConfigurableHeader& header, bool footer);
ConfigurableHeader parse_configurable_header(const Bytes& bytes, bool footer);
std::string configurable_volume_name(bool parity, uint32_t index);
bool uses_configurable_profile(const fs::path& directory);
void create_configurable_archive(const InputPlan& plan, const fs::path& output, const RecoveryOptions& options, const SecurityOptions* security = nullptr, bool report_progress = false, uint32_t threads = 0);
ConfigurableManifest list_configurable_archive(const fs::path& directory, const Password* password = nullptr);
Verification verify_configurable_archive(const fs::path& directory, const Password* password = nullptr);
void repair_configurable_archive(const fs::path& directory, const fs::path& output);
ExtractionReport extract_configurable_archive(const fs::path& directory, const fs::path& output, const Password* password = nullptr, bool restore_attributes = true);
}
