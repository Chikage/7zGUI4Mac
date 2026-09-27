#include "inputs.hpp"
#include "crypto.hpp"
#include "compression_progress.hpp"
#include "compression_pool.hpp"
#include <algorithm>
#include <set>
#include <stdexcept>
namespace rz {
void require_outside(const fs::path& source, const fs::path& output) {
    auto dest = fs::weakly_canonical(fs::absolute(output));
    if (within(dest, fs::canonical(source))) throw std::runtime_error("Output must be outside the input directory");
}
void add_input(const fs::path& root, const fs::path& path, InputPaths& paths) {
    check_cancel();
    auto status = fs::symlink_status(path);
    if (!fs::is_regular_file(status) && !fs::is_directory(status))
        throw std::runtime_error("Only regular files/directories are supported: " + path.string());
    auto relative = path.lexically_relative(root).generic_string(); validate_path(relative);
    paths.emplace(relative, fs::is_directory(status));
    if (paths.size() > 100000) throw std::runtime_error("Too many input entries");
}
void add_tree(const fs::path& root, const fs::path& source, InputPaths& paths) {
    for (const auto& e : fs::recursive_directory_iterator(source)) {
        check_cancel();
        add_input(root, e.path(), paths);
    }
}
void pack(const fs::path& source, const InputPaths& paths, const fs::path& spool_path, Manifest& m, CompressionProgress* progress, uint32_t threads) {
    File spool(spool_path, File::Mode::New);
    pack_contents(source, paths, spool, m, {}, 0, progress, threads);
}
void pack_contents(const fs::path& source, const InputPaths& paths, File& spool, Manifest& m,
                   const FrameEncoder& encoder, uint64_t reserved_plain_bytes, CompressionProgress* progress, uint32_t threads) {
    if (progress) progress->start();
    uint64_t raw_total = reserved_plain_bytes, metadata_budget = 60;
    if (raw_total > MaxOutput) throw std::runtime_error("Metadata exceeds archive size limit");
    CompressionPool pool(threads);
    auto commit_next = [&] {
        auto job = pool.take();
        auto record = encoder ? encoder(job->compressed, m.stream_size, job->plain_size) : std::move(job->compressed);
        auto& entry = m.entries.at(job->entry);
        entry.frames.push_back({m.stream_size, static_cast<uint32_t>(record.size()), job->plain_size});
        spool.append(record); m.stream_size += record.size();
        if (progress) {
            progress->advance(job->plain_size, record.size());
            if (job->last_in_file) progress->file_completed();
        }
    };
    for (const auto& path : paths) {
        check_cancel();
        const auto entry_id = m.entries.size();
        auto& e = m.entries.emplace_back(); e.path = path.first; e.directory = path.second;
        metadata_budget += 56 + e.path.size();
        if (metadata_budget > MaxManifest) throw std::runtime_error("File index exceeds manifest limit");
        blake3_hasher digest; blake3_hasher_init(&digest);
        if (!e.directory) {
            File file(source / e.path); e.size = file.size();
            if (e.size > MaxOutput - raw_total) throw std::runtime_error("Input exceeds 64 GiB phase-one limit");
            raw_total += e.size;
            for (uint64_t offset = 0; offset < e.size;) {
                // Drain BEFORE allocating: the bound covers every outstanding frame.
                if (pool.full()) commit_next();
                auto job = std::make_unique<CompressionJob>(bool(encoder));
                job->entry = entry_id;
                job->plain_size = static_cast<uint32_t>(std::min<uint64_t>(FrameSize, e.size - offset));
                job->plain.resize(job->plain_size);
                if (!file.read(offset, job->plain.data(), job->plain.size())) throw std::runtime_error("Input changed or became unreadable");
                blake3_hasher_update(&digest, job->plain.data(), job->plain.size());
                offset += job->plain_size; job->last_in_file = offset == e.size;
                metadata_budget += 16;
                if (metadata_budget > MaxManifest) throw std::runtime_error("File index exceeds manifest limit");
                pool.submit(std::move(job));
            }
            if (file.size() != e.size) throw std::runtime_error("Input file size changed during compression");
            if (progress && e.size == 0) progress->file_completed();
        }
        blake3_hasher_finalize(&digest, e.digest.data(), e.digest.size());
    }
    while (!pool.empty()) commit_next();
    if (progress) progress->finish_compression();
}

InputPlan directory_inputs(const fs::path& source_path, const fs::path& output) {
    require_directory(source_path); auto source = fs::canonical(source_path); require_outside(source, output);
    InputPaths paths; add_tree(source, source, paths);
    return {source, std::move(paths)};
}
InputPlan selected_inputs(const std::vector<fs::path>& source_paths, const fs::path& output) {
    if (source_paths.empty()) throw std::runtime_error("No input selected");
    std::set<fs::path> unique;
    for (const auto& p : source_paths) {
        auto absolute = fs::absolute(p).lexically_normal();
        if (absolute == absolute.root_path()) throw std::runtime_error("Cannot archive filesystem root");
        // Resolve parent aliases, but retain the leaf so selected symlinks remain rejected.
        unique.insert(fs::canonical(absolute.parent_path()) / absolute.filename());
    }
    auto root = unique.begin()->parent_path();
    for (const auto& p : unique) while (!within(p, root)) root = root.parent_path();
    InputPaths paths;
    std::vector<fs::path> selected;
    for (const auto& p : unique) {
        if (std::any_of(selected.begin(), selected.end(), [&](const auto& parent) { return within(p, parent); })) continue;
        auto status = fs::symlink_status(p);
        if (fs::is_directory(status)) require_outside(p, output);
        if (fs::weakly_canonical(fs::absolute(output)) == p) throw std::runtime_error("Output is an input file");
        add_input(root, p, paths);
        for (auto parent = p.parent_path(); parent != root; parent = parent.parent_path()) add_input(root, parent, paths);
        if (fs::is_directory(status)) add_tree(root, p, paths);
        selected.push_back(p);
    }
    return {root, std::move(paths)};
}
}
