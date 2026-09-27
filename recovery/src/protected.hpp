#pragma once
#include "configurable.hpp"
#include <optional>

namespace rz {
struct ProtectedInput {
    Manifest packed;
    SecurityInfo security;
    std::optional<ArchiveKeys> keys;
};
using RecordReader = std::function<Bytes(uint64_t, uint32_t)>;
ProtectedInput pack_protected(const InputPlan& plan, const fs::path& spool, const SecurityOptions& options, CompressionProgress* progress = nullptr, uint32_t threads = 0);
void sign_manifest(ConfigurableManifest& manifest, const ArchiveKeys& keys);
std::optional<ArchiveKeys> authenticate_manifest(const ConfigurableManifest& manifest, const Password* password);
void unlock_index(ConfigurableManifest& manifest, const RecordReader& reader, const ArchiveKeys* keys);
Bytes read_record(const ConfigurableManifest& manifest, const RecordReader& reader, const Frame& frame, RecordKind kind, const ArchiveKeys* keys);
Bytes read_metadata(const ConfigurableManifest& manifest, const Entry& entry, const RecordReader& reader, const ArchiveKeys* keys);
void verify_private_records(const ConfigurableManifest& manifest, const RecordReader& reader, const ArchiveKeys* keys);
}
