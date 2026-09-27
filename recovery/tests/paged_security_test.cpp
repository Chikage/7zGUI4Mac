#include "paged.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <map>
#include <random>

namespace {
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class Action> void rejects(Action action, const char* message) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, message);
}
struct Workspace {
    rz::fs::path root;
    Workspace() {
        const auto uuid = rz::random_uuid();
        root = rz::fs::temp_directory_path() / ("rz-paged-security-" + rz::hex(rz::hash(uuid.data(), uuid.size())));
        require(rz::fs::create_directory(root), "cannot create test workspace");
    }
    ~Workspace() { std::error_code error; rz::fs::remove_all(root, error); }
};
rz::Bytes read_file(const rz::fs::path& path) {
    rz::File file(path); require(file.size() <= 8 * 1024 * 1024, "test unexpectedly requested a large fixture");
    rz::Bytes bytes(file.size()); require(file.read(0, bytes.data(), bytes.size()), "cannot read test file"); return bytes;
}
using Snapshot = std::map<std::string, rz::Bytes>;
Snapshot snapshot(const rz::fs::path& directory) {
    Snapshot result;
    for (const auto& entry : rz::fs::directory_iterator(directory)) {
        require(entry.is_regular_file(), "unexpected directory in archive fixture");
        result.emplace(entry.path().filename().string(), read_file(entry.path()));
    }
    return result;
}
rz::PagedBootstrap read_bootstrap(const rz::fs::path& directory) {
    auto bytes = read_file(directory / "manifest.rzm");
    require(bytes.size() > 32, "missing bootstrap checksum"); bytes.resize(bytes.size() - 32);
    return rz::parse_bootstrap(bytes);
}
rz::fs::path volume_path(const rz::fs::path& directory, const rz::PagedBootstrap& b, uint32_t column) {
    const auto k = b.manifest.options.data_volumes;
    return directory / rz::configurable_volume_name(column >= k, column >= k ? column - k : column);
}
uint64_t index_offset(const rz::PagedBootstrap& b, uint32_t stripe) {
    require(stripe < b.layout.index_stripes, "invalid test index stripe");
    return rz::HeaderSize + rz::serialize_bootstrap(b).size() + (b.layout.data_stripes + stripe) * rz::PagedRecordSize;
}
// Deliberately produce a self-consistent local checksum. Only the authenticated
// per-volume index aggregate can identify a forged parity/padding record.
void forge_index(const rz::fs::path& directory, const rz::PagedBootstrap& b, uint32_t stripe, uint32_t column) {
    const auto path = volume_path(directory, b, column); const auto offset = index_offset(b, stripe);
    rz::Bytes block(rz::BlockSize);
    { rz::File source(path); require(source.read(offset, block.data(), block.size()), "cannot read index record"); }
    block[17] ^= 0x53;
    const auto digest = rz::index_block_hash(b.manifest.uuid, stripe, column, block);
    rz::File file(path, rz::File::Mode::Update);
    file.write(offset, block); file.write(offset + rz::BlockSize, digest.data(), digest.size()); file.sync();
}
void break_local_checksum(const rz::fs::path& directory, const rz::PagedBootstrap& b, uint32_t stripe, uint32_t column) {
    const auto path = volume_path(directory, b, column); const auto offset = index_offset(b, stripe) + rz::BlockSize;
    uint8_t byte = 0;
    { rz::File source(path); require(source.read(offset, &byte, 1), "cannot read index checksum"); }
    byte ^= 0x3d; rz::File file(path, rz::File::Mode::Update); file.write(offset, &byte, 1); file.sync();
}
void no_staging(const rz::fs::path& root) {
    for (const auto& entry : rz::fs::directory_iterator(root))
        require(!entry.path().filename().string().starts_with(".rz-stage-"), "failed operation left staging output behind");
}
void check_extraction(const rz::fs::path& archive, const rz::fs::path& output, const rz::Password* password, const rz::Bytes& expected) {
    require(rz::extract_paged_archive(archive, output, password, false).warning_count == 0, "unexpected extraction warning");
    require(read_file(output / "content") == expected, "repaired encrypted content differs");
    require(read_file(output / "empty").empty(), "empty source file changed");
}
void suite(const rz::fs::path& root, uint32_t crypto) {
    rz::fs::create_directory(root); const auto source = root / "source"; rz::fs::create_directory(source);
    rz::Bytes content(300000); std::mt19937 random(73); for (auto& byte : content) byte = static_cast<uint8_t>(random());
    { rz::File file(source / "content", rz::File::Mode::New); file.append(content); }
    { rz::File file(source / "empty", rz::File::Mode::New); }
    rz::Password password; constexpr char text[] = "paged-security-password";
    password.size = sizeof(text) - 1; std::memcpy(password.bytes.data(), text, password.size);
    const auto* credential = crypto ? &password : nullptr;
    rz::SecurityOptions security; security.metadata = false; security.encrypt = crypto != 0;
    security.crypto_suite = crypto ? crypto : rz::CryptoProfile; security.password = credential;
    rz::RecoveryOptions options; options.profile = 5; options.mode = rz::RecoveryMode::Volumes;
    options.volume_size = 0; options.value = 0; options.data_volumes = 2; options.recovery_volumes = 2;
    const auto original = root / "original";
    rz::create_paged_archive(rz::directory_inputs(source, original), original, options, security, false, 2);
    const auto pristine = snapshot(original); const auto b = read_bootstrap(original);
    require(b.layout.hash_pages == 1 && b.layout.index_stripes == 1, "unexpected leaf/root fixture layout");
    require(rz::verify_paged_archive(original, credential).exit_code() == 0, "pristine archive failed full verification");

    // At this geometry data column0 contains the leaf hash page, column1 the
    // root plus padding, and columns2/3 the index recovery blocks.
    size_t number = 0;
    for (const auto& columns : {std::vector<uint32_t>{0}, std::vector<uint32_t>{1}, std::vector<uint32_t>{2},
                               std::vector<uint32_t>{1, 2}, std::vector<uint32_t>{2, 3}, std::vector<uint32_t>{0, 1, 2}}) {
        const auto name = std::to_string(number++); const auto attacked = root / ("attack-" + name);
        const auto repaired = root / ("repair-" + name);
        rz::fs::copy(original, attacked, rz::fs::copy_options::recursive);
        for (auto column : columns) forge_index(attacked, b, 0, column);
        const auto damaged = snapshot(attacked);
        require(damaged != pristine, "forgery did not change index records");
        require(damaged.at("manifest.rzm") == pristine.at("manifest.rzm"), "attack changed authenticated bootstrap");
        const auto result = rz::verify_paged_archive(attacked, credential);
        require(result.bad_blocks >= columns.size(), "locally self-consistent forged index was not detected");
        if (columns.size() <= options.recovery_volumes) {
            require(result.exit_code() == 2 && result.unrecoverable_stripes == 0, "recoverable forged columns rejected");
            rz::repair_paged_archive(attacked, repaired);
            require(snapshot(repaired) == pristine, "repair did not restore exact original index and volumes");
            require(rz::verify_paged_archive(repaired, credential).exit_code() == 0, "repaired archive failed authentication");
            check_extraction(repaired, root / ("output-" + name), credential, content);
        } else {
            require(result.exit_code() == 3 && result.unrecoverable_stripes != 0, "excess forged columns not marked unrecoverable");
            rejects([&] { rz::repair_paged_archive(attacked, repaired); }, "unrecoverable forged index published repaired output");
            require(!rz::fs::exists(repaired), "failed repair published partial output");
        }
        require(snapshot(attacked) == damaged, "repair modified damaged source records");
        require(snapshot(original) == pristine, "repair modified pristine source archive");
        no_staging(root);
    }

    // A normal checksum failure in one stripe must not mask a self-consistent
    // forgery in another stripe of the same recoverable index volume.
    options.data_volumes = options.recovery_volumes = 1;
    const auto narrow = root / "narrow-original";
    rz::create_paged_archive(rz::directory_inputs(source, narrow), narrow, options, security, false, 2);
    const auto narrow_pristine = snapshot(narrow); const auto narrow_b = read_bootstrap(narrow);
    require(narrow_b.layout.index_stripes >= 2, "mixed corruption needs multiple index stripes");
    const auto mixed = root / "mixed-corruption", mixed_repaired = root / "mixed-repair";
    rz::fs::copy(narrow, mixed, rz::fs::copy_options::recursive);
    forge_index(mixed, narrow_b, 0, 1); break_local_checksum(mixed, narrow_b, 1, 1);
    const auto mixed_snapshot = snapshot(mixed);
    require(rz::verify_paged_archive(mixed, credential).exit_code() == 2, "mixed corruption was not recoverable");
    rz::repair_paged_archive(mixed, mixed_repaired);
    require(snapshot(mixed_repaired) == narrow_pristine, "local checksum error masked same-volume index forgery");
    require(snapshot(mixed) == mixed_snapshot && snapshot(narrow) == narrow_pristine, "mixed repair modified source records");
    no_staging(root);
}
}
int main() {
    try {
        Workspace workspace; suite(workspace.root / "plain", 0); suite(workspace.root / "standard", rz::CryptoProfile);
        if (rz::aes_available()) suite(workspace.root / "dual", rz::DualCryptoProfile);
        std::cout << "Profile 5 forged leaf/root/parity indexes detected, bounded repair byte-identical, over-capacity output rejected\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
