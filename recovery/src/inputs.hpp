#pragma once
#include "io.hpp"
#include <map>
#include <functional>

namespace rz {
class CompressionProgress;
using InputPaths = std::map<std::string, bool>;
struct InputPlan { fs::path root; InputPaths paths; };
void require_outside(const fs::path& source, const fs::path& output);
InputPlan directory_inputs(const fs::path& source, const fs::path& output);
InputPlan selected_inputs(const std::vector<fs::path>& sources, const fs::path& output);
void pack(const fs::path& root, const InputPaths& paths, const fs::path& spool, Manifest& output, CompressionProgress* progress = nullptr, uint32_t threads = 0);
using FrameEncoder = std::function<Bytes(const Bytes&, uint64_t, uint32_t)>;
void pack_contents(const fs::path& root, const InputPaths& paths, File& spool, Manifest& output,
                   const FrameEncoder& encoder = {}, uint64_t reserved_plain_bytes = 0, CompressionProgress* progress = nullptr, uint32_t threads = 0, uint64_t max_output = MaxOutput);
}
