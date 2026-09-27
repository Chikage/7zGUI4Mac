#include "compression_pool.hpp"
#include "inputs.hpp"
#include <iostream>
#include <random>
#include <stdexcept>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
rz::Bytes bytes(size_t size, uint32_t seed) {
    std::mt19937 random(seed); rz::Bytes result(size);
    for (auto& byte : result) byte = static_cast<uint8_t>(random());
    return result;
}
std::unique_ptr<rz::CompressionJob> job(size_t id, size_t size) {
    auto result = std::make_unique<rz::CompressionJob>(true);
    result->entry = id; result->plain_size = static_cast<uint32_t>(size);
    result->plain = bytes(size, static_cast<uint32_t>(id));
    return result;
}
void queues() {
    for (uint32_t count : {1U, 4U, 64U, 0U}) {
        rz::CompressionPool pool(count);
        require(pool.limits().estimated_bytes <= rz::CompressionMemoryBudget, "memory admission budget");
        require(pool.limits().workers >= 1 && pool.limits().slots == 2 * pool.limits().workers, "worker/window limits");
        const size_t slots = pool.limits().slots;
        // A large, incompressible head followed by tiny frames exercises out-of-order completion.
        for (size_t i = 0; i < slots; ++i) pool.submit(job(i, i == 0 ? rz::FrameSize : 31 + i));
        require(pool.full(), "completed jobs must continue occupying admission slots");
        bool rejected = false;
        try { pool.submit(job(slots, 1)); } catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "reject unbounded admission");
        for (size_t i = 0; i < slots * 3; ++i) {
            auto result = pool.take();
            const size_t size = i == 0 ? rz::FrameSize : 31 + i;
            auto plain = bytes(size, static_cast<uint32_t>(i));
            require(result->entry == i, "results must preserve submission order");
            require(result->plain.empty(), "plaintext released before result delivery");
            require(result->compressed == rz::compress_frame(plain), "byte identity with the legacy frame encoder");
            result.reset(); // Commit/release before admitting another frame.
            if (i < slots * 2) pool.submit(job(i + slots, 31 + i + slots));
        }
        require(pool.empty(), "queue fully drained");
    }
    bool failed = false;
    try {
        rz::CompressionPool pool(4);
        pool.submit(job(0, rz::FrameSize));
        pool.submit(job(1, 0)); // Worker-side failure while another job can still be running.
        while (!pool.empty()) (void)pool.take();
    } catch (const std::runtime_error& error) { failed = std::string(error.what()) == "Invalid compression frame"; }
    require(failed, "first worker error must reach the coordinator without deadlock");
    {
        rz::CompressionPool pool(4);
        for (size_t i = 0; i < pool.limits().slots; ++i) pool.submit(job(i, 32768));
        rz::interrupted.store(SIGTERM);
        failed = false;
        try { (void)pool.take(); } catch (const std::runtime_error&) { failed = true; }
        require(failed, "cancellation must wake ordered waits");
    }
    rz::interrupted.store(0);
    // Destruction with abandoned queued/results must join workers before freeing jobs.
    { rz::CompressionPool pool(4); for (size_t i = 0; i < 8; ++i) pool.submit(job(i, 65536)); }
}
void packing() {
    auto root = rz::fs::temp_directory_path() / ("rz-thread-test-" + rz::hex(rz::hash(rz::random_uuid().data(), 16)));
    struct Cleanup { rz::fs::path path; ~Cleanup() { std::error_code error; rz::fs::remove_all(path, error); } } cleanup{root};
    rz::fs::create_directories(root / "source" / "empty-dir");
    auto source = root / "source";
    for (size_t i = 0; i < 25; ++i) {
        rz::File file(source / ("file-" + std::to_string(i)), rz::File::Mode::New);
        file.append(bytes(i == 0 ? rz::FrameSize * 3 + 57 : i == 1 ? 0 : 71 + i, static_cast<uint32_t>(i)));
    }
    auto plan = rz::directory_inputs(source, root / "unused-output");
    for (uint32_t count : {1U, 4U, 0U}) {
        auto spool_path = root / ("spool-" + std::to_string(count));
        rz::Manifest manifest;
        rz::pack(source, plan.paths, spool_path, manifest, nullptr, count);
        rz::File spool(spool_path); uint64_t expected_offset = 0;
        require(manifest.entries.size() == plan.paths.size(), "all entries preserved");
        for (const auto& entry : manifest.entries) {
            if (entry.directory) continue;
            rz::File input(source / entry.path); rz::Bytes original(input.size());
            require(input.read(0, original.data(), original.size()), "read test input");
            require(entry.digest == rz::hash(original), "file hash must use original byte order");
            size_t offset = 0;
            for (const auto& frame : entry.frames) {
                const size_t size = std::min<size_t>(rz::FrameSize, original.size() - offset);
                rz::Bytes plain(original.begin() + offset, original.begin() + offset + size);
                auto expected = rz::compress_frame(plain); rz::Bytes actual(frame.stored);
                require(frame.offset == expected_offset && frame.plain == size, "continuous ordered frame mapping");
                require(spool.read(frame.offset, actual.data(), actual.size()) && actual == expected, "packed stream compatibility");
                offset += size; expected_offset += expected.size();
            }
            require(offset == original.size(), "all file bytes accounted for");
        }
        require(manifest.stream_size == expected_offset && spool.size() == expected_offset, "no trailing or missing frames");
    }
    bool failed = false;
    try {
        rz::File spool(root / "encoder-failure", rz::File::Mode::New); rz::Manifest manifest; size_t frames = 0;
        rz::pack_contents(source, plan.paths, spool, manifest,
            [&](const rz::Bytes& compressed, uint64_t, uint32_t) {
                if (++frames == 2) throw std::runtime_error("injected encoder failure");
                return compressed;
            }, 0, nullptr, 4);
    } catch (const std::runtime_error& error) { failed = std::string(error.what()) == "injected encoder failure"; }
    require(failed, "writer failure must safely abandon outstanding compression jobs");
}
}
int main() {
    try { queues(); packing(); std::cout << "Ordered compression, bounded admission, compatibility, worker/writer failure and cancellation passed\n"; }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
