#include "container.hpp"
#include "binary.hpp"
#include <algorithm>

namespace rz {
namespace {
ContainerHeader geometry(const PagedBootstrap& b, size_t encoded_size) {
    ContainerHeader h;
    h.uuid = b.manifest.uuid; h.data_volumes = b.manifest.options.data_volumes; h.recovery_volumes = b.manifest.options.recovery_volumes;
    h.bootstrap_size = encoded_size;
    h.volume_size = 2 * HeaderSize + 2 * encoded_size + (b.layout.data_stripes + b.layout.index_stripes) * PagedRecordSize;
    h.total_size = 2 * ContainerHeaderSize + encoded_size + 32 + (h.data_volumes + h.recovery_volumes) * h.volume_size;
    return h;
}
Bytes encode(const ContainerHeader& h) {
    binary::Writer w;
    w.raw("RZCNT001", 8); w.u32(1); w.u32(h.data_volumes); w.u32(h.recovery_volumes); w.u32(0);
    w.raw(h.uuid.data(), h.uuid.size()); w.u64(h.bootstrap_size); w.u64(h.volume_size); w.u64(h.total_size);
    w.b.resize(ContainerHeaderSize - 32, 0); const auto digest = hash(w.b); w.raw(digest.data(), digest.size());
    return w.b;
}
std::optional<ContainerHeader> decode(const File& file, uint64_t offset) {
    Bytes bytes(ContainerHeaderSize);
    if (!file.read(offset, bytes.data(), bytes.size())) return std::nullopt;
    const auto digest = hash(bytes.data(), ContainerHeaderSize - 32);
    if (!std::equal(digest.begin(), digest.end(), bytes.end() - 32)) return std::nullopt;
    try {
        binary::Reader r{bytes}; r.magic("RZCNT001");
        if (r.u32() != 1) return std::nullopt;
        ContainerHeader h; h.data_volumes = r.u32(); h.recovery_volumes = r.u32();
        validate_volume_counts(h.data_volumes, h.recovery_volumes);
        if (r.u32() != 0) return std::nullopt;
        r.raw(h.uuid.data(), h.uuid.size()); h.bootstrap_size = r.u64(); h.volume_size = r.u64(); h.total_size = r.u64();
        if (h.bootstrap_size < 144 || h.bootstrap_size > MaxBootstrap ||
            h.volume_size < 2 * HeaderSize + 2 * h.bootstrap_size + 2 * PagedRecordSize || h.volume_size > 2 * MaxStream ||
            (h.volume_size - 2 * HeaderSize - 2 * h.bootstrap_size) % PagedRecordSize != 0 ||
            h.total_size != 2 * ContainerHeaderSize + h.bootstrap_size + 32 + (h.data_volumes + h.recovery_volumes) * h.volume_size ||
            std::any_of(bytes.begin() + 64, bytes.begin() + 96, [](uint8_t v) { return v != 0; })) return std::nullopt;
        return h;
    } catch (const std::runtime_error&) { return std::nullopt; }
}
}
ArchiveStorage::ArchiveStorage(const fs::path& path) {
    const auto status = fs::symlink_status(path);
    if (fs::is_directory(status)) { path_ = fs::canonical(path); return; }
    // File rejects symlinks and non-regular files before canonicalizing the path.
    container_ = std::make_shared<File>(path); path_ = fs::canonical(path);
    const auto size = container_->size();
    auto front = decode(*container_, 0);
    auto back = size >= 2 * ContainerHeaderSize ? decode(*container_, size - ContainerHeaderSize) : std::nullopt;
    if (back && back->total_size != size) back.reset();
    if (!front && !back) throw std::runtime_error("No valid RZ container header remains");
    if (front && back && encode(*front) != encode(*back)) throw std::runtime_error("Conflicting RZ container headers");
    header_ = front ? *front : *back;
    metadata_issues_ = !front + !back + (header_.total_size != size);
}
std::vector<fs::path> ArchiveStorage::volumes() const {
    std::vector<fs::path> names;
    if (container_) {
        for (bool parity : {false, true}) for (uint32_t v = 0; v < (parity ? header_.recovery_volumes : header_.data_volumes); ++v)
            names.emplace_back(volume_name(parity, v));
    } else {
        for (const auto& entry : fs::directory_iterator(path_)) {
            if (entry.path().extension() != ".rzv" && entry.path().extension() != ".rzr") continue;
            if (names.size() == 200) throw std::runtime_error("Too many profile 5 volumes");
            names.push_back(entry.path().filename());
        }
    }
    return names;
}
std::unique_ptr<File> ArchiveStorage::open(const fs::path& name, File::Mode mode, bool optional) const {
    if (!container_) return std::make_unique<File>(path_ / name, mode, optional);
    if (mode != File::Mode::Read) throw std::runtime_error("RZ containers are read-only; repair to a new file");
    const auto manifest_size = header_.bootstrap_size + 32;
    if (name == "manifest.rzm") return std::make_unique<File>(*container_, ContainerHeaderSize, manifest_size);
    const auto k = header_.data_volumes;
    for (uint32_t column = 0; column < k + header_.recovery_volumes; ++column)
        if (name == volume_name(column >= k, column >= k ? column - k : column))
            return std::make_unique<File>(*container_, ContainerHeaderSize + manifest_size + column * header_.volume_size, header_.volume_size);
    throw std::runtime_error("Unexpected RZ container member");
}
void ArchiveStorage::validate(const PagedBootstrap& b, size_t encoded_size) const {
    if (container_ && encode(header_) != encode(geometry(b, encoded_size)))
        throw std::runtime_error("RZ container geometry conflicts with profile 5 bootstrap");
}
fs::path pack_container(const fs::path& stage, const PagedBootstrap& bootstrap, size_t encoded_size) {
    const auto h = geometry(bootstrap, encoded_size); const auto header = encode(h);
    const auto path = stage / "archive.tmp"; File output(path, File::Mode::New); output.append(header);
    Bytes buffer(1024 * 1024);
    auto copy = [&](const fs::path& name, uint64_t expected) {
        {
            File input(stage / name);
            if (input.size() != expected) throw std::runtime_error("Staged RZ member size changed");
            for (uint64_t offset = 0; offset < expected;) {
                const auto count = static_cast<size_t>(std::min<uint64_t>(buffer.size(), expected - offset));
                if (!input.read(offset, buffer.data(), count)) throw std::runtime_error("Cannot read staged RZ member");
                output.append(buffer.data(), count); offset += count;
            }
        }
        fs::remove(stage / name);
    };
    copy("manifest.rzm", h.bootstrap_size + 32);
    for (bool parity : {false, true}) for (uint32_t v = 0; v < bootstrap.manifest.options.volume_count(parity); ++v)
        copy(volume_name(parity, v), h.volume_size);
    output.append(header);
    if (output.size() != h.total_size) throw std::runtime_error("RZ container size changed");
    output.sync(); return path;
}
}
