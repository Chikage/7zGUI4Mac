#include "container.hpp"
#include <algorithm>
#include <iostream>
#include <limits>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class Action> void rejects(Action action) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "invalid container accepted");
}
void put(rz::Bytes& bytes, size_t offset, uint64_t value, size_t width) {
    for (size_t i = 0; i < width; ++i) bytes[offset + i] = static_cast<uint8_t>(value >> (8 * i));
}
}
int main() {
    try {
        const auto uuid = rz::random_uuid();
        rz::Staging workspace(rz::fs::temp_directory_path() / ("rz-container-unit-" + rz::hex(rz::hash(uuid.data(), uuid.size()))));
        const auto source = workspace.path / "source", archive = workspace.path / "archive.rz";
        rz::fs::create_directory(source);
        { rz::File file(source / "file", rz::File::Mode::New); file.append("test", 4); }
        rz::create_paged_archive(rz::directory_inputs(source, archive), archive, {2, 1}, {false, false});
        rz::File file(archive); rz::Bytes original(file.size());
        require(file.read(0, original.data(), original.size()), "cannot read fixture");
        rz::ArchiveStorage storage(archive);
        auto member = storage.open("d000000.rzv");
        rz::Bytes tail(8);
        require(member->read(member->size() - 8, tail.data(), 8), "slice tail is unreadable");
        require(!member->read(member->size() - 7, tail.data(), 8), "read crossed member boundary");
        require(!member->read(std::numeric_limits<uint64_t>::max(), tail.data(), 1), "read offset overflow accepted");
        rejects([&] { member->write(0, tail); });
        rejects([&] { member->resize(0); });
        rejects([&] { member->append(tail); });
        rejects([&] { (void)storage.open("../escape"); });
        // The open storage keeps the original inode if its pathname is replaced.
        const auto moved = workspace.path / "moved.rz";
        rz::fs::rename(archive, moved);
        { rz::File replacement(archive, rz::File::Mode::New); replacement.append("other", 5); }
        auto pinned = storage.open("d000000.rzv");
        rz::Bytes check(8);
        require(pinned->read(pinned->size() - 8, check.data(), 8) && check == tail, "container inode changed");
        rz::fs::remove(archive);
        // Every mutation has a valid BLAKE3 checksum in BOTH copies. Reject based
        // on geometry/version/reserved fields or the authenticated bootstrap.
        auto invalid = [&](size_t offset, uint64_t value, size_t width) {
            auto bytes = original; put(bytes, offset, value, width);
            const auto digest = rz::hash(bytes.data(), 96);
            std::copy(digest.begin(), digest.end(), bytes.begin() + 96);
            std::copy_n(bytes.begin(), 128, bytes.end() - 128);
            { rz::File bad(archive, rz::File::Mode::New); bad.append(bytes); }
            rejects([&] { (void)rz::list_paged_archive(archive); });
            rz::fs::remove(archive);
        };
        invalid(8, 2, 4); invalid(12, 0, 4); invalid(12, 101, 4); invalid(16, 3, 4);
        invalid(20, 1, 4); invalid(40, 0, 8); invalid(40, 8193, 8); invalid(48, UINT64_MAX, 8);
        invalid(56, UINT64_MAX, 8); invalid(64, 1, 8); invalid(24, original[24] ^ 1, 1);
        // Positional IO stays 64-bit, and a truncated backing file cannot make a
        // bounded view read bytes belonging to a later logical member.
        const auto sparse = workspace.path / "sparse";
        constexpr uint64_t base = (uint64_t(1) << 32) + 17;
        { rz::File large(sparse, rz::File::Mode::New); large.resize(base + 16); large.write(base, "large-offset", 12); }
        rz::File large(sparse); rz::File view(large, base, 12); rz::Bytes data(12);
        require(view.size() == 12 && view.read(0, data.data(), data.size()) && std::string(data.begin(), data.end()) == "large-offset", "64-bit slice failed");
        { rz::File truncate(sparse, rz::File::Mode::Update); truncate.resize(base + 3); }
        require(view.size() == 3 && !view.read(0, data.data(), data.size()), "truncated slice accepted");
        std::cout << "Container geometry, bounds, pinned inode and 64-bit offsets passed\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
