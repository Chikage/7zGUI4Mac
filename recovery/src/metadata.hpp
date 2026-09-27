#pragma once
#include "format.hpp"

namespace rz {
constexpr uint64_t MaxMetadata = 64 * 1024 * 1024;
struct ExtractionReport {
    uint64_t warning_count = 0;
    std::vector<std::string> warnings;
    void warn(const std::string& path, const std::string& detail);
};
Bytes capture_metadata(const fs::path& path);
void validate_metadata(const Bytes& bytes);
void restore_metadata(const fs::path& path, const std::string& relative, bool directory, const Bytes& bytes, ExtractionReport& report);
void reset_metadata_for_cleanup(const fs::path& root, const std::vector<Entry>& entries) noexcept;
}
