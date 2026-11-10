#pragma once
#include "inputs.hpp"
#include "crypto.hpp"
#include "metadata.hpp"

namespace rz {
class ReadProgress;
struct Verification {
    uint64_t bad_blocks = 0, bad_data_blocks = 0, unrecoverable_stripes = 0, metadata_issues = 0;
    int exit_code() const { return unrecoverable_stripes ? 3 : (bad_blocks || metadata_issues ? 2 : 0); }
};
struct RecoveryOptions {
    uint32_t data_volumes = 10, recovery_volumes = 2;
    uint32_t volume_count(bool parity) const { return parity ? recovery_volumes : data_volumes; }
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
struct ArchiveManifest {
    UUID uuid{};
    RecoveryOptions options;
    uint64_t stream_size = 0;
    std::vector<Entry> entries;
    SecurityInfo security;
    bool unlocked = false, directory_damaged = false;
    uint64_t data_bytes_per_volume = 0, metadata_bytes_per_volume = 0;
    Bytes authentication_bytes; // Bootstrap with its MAC zeroed.
};
}
