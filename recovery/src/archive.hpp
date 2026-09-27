#pragma once
#include "format.hpp"

namespace rz {
class ReadProgress;
struct Verification {
    uint64_t bad_blocks = 0, bad_data_blocks = 0, unrecoverable_stripes = 0, metadata_issues = 0;
    int exit_code() const { return unrecoverable_stripes ? 3 : (bad_blocks || metadata_issues ? 2 : 0); }
};
void create_archive(const fs::path& source, const fs::path& output, uint64_t volume_size, uint32_t threads = 0);
void create_selected_archive(const std::vector<fs::path>& sources, const fs::path& output, uint64_t volume_size, uint32_t threads = 0);
Manifest list_archive(const fs::path& directory);
Verification verify_archive(const fs::path& directory, ReadProgress* progress = nullptr);
void repair_archive(const fs::path& directory, const fs::path& output);
void extract_archive(const fs::path& directory, const fs::path& output, ReadProgress* progress = nullptr);
}
