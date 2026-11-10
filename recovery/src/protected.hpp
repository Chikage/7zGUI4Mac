#pragma once
#include "archive.hpp"
#include <optional>

namespace rz {
struct ProtectedInput {
    PackedContents packed;
    SecurityInfo security;
    std::optional<ArchiveKeys> keys;
};
using RecordReader = std::function<Bytes(uint64_t, uint32_t)>;
ProtectedInput pack_protected(const InputPlan& plan, const fs::path& spool, const SecurityOptions& options, CompressionProgress* progress = nullptr, uint32_t threads = 0);
std::optional<ArchiveKeys> authenticate_manifest(const ArchiveManifest& manifest, const Password* password);
void unlock_index(ArchiveManifest& manifest, const RecordReader& reader, const ArchiveKeys* keys);
Bytes read_record(const ArchiveManifest& manifest, const RecordReader& reader, const Frame& frame, RecordKind kind, const ArchiveKeys* keys);
Bytes read_metadata(const ArchiveManifest& manifest, const Entry& entry, const RecordReader& reader, const ArchiveKeys* keys);
void verify_private_records(const ArchiveManifest& manifest, const RecordReader& reader, const ArchiveKeys* keys, uint32_t threads = 0, ReadProgress* progress = nullptr);
}
