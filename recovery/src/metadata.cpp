#include "metadata.hpp"
#include "binary.hpp"
#include "io.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <set>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/acl.h>
#include <sys/attr.h>
#include <membership.h>
#endif

namespace rz {
namespace {
class Descriptor {
public:
    int fd = -1;
    explicit Descriptor(const fs::path& path) {
        fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat s{};
        if (fd < 0 || ::fstat(fd, &s) || (!S_ISREG(s.st_mode) && !S_ISDIR(s.st_mode))) {
            if (fd >= 0) ::close(fd);
            throw std::runtime_error("Cannot open file metadata: " + path.string());
        }
    }
    ~Descriptor() { ::close(fd); }
};
struct Attributes {
    uint32_t platform = 0, mode = 0, uid = 0, gid = 0, flags = 0;
    timespec access{}, modified{}, birth{};
    bool has_birth = false, has_acl = false;
    std::string acl;
    std::vector<std::pair<std::string, Bytes>> xattrs;
};
void put_time(binary::Writer& w, const timespec& time) { w.u64(static_cast<uint64_t>(time.tv_sec)); w.u32(static_cast<uint32_t>(time.tv_nsec)); }
timespec get_time(binary::Reader& r) {
    auto seconds = static_cast<int64_t>(r.u64()); auto nanos = r.u32();
    if (nanos >= 1000000000 || seconds < -62135596800LL || seconds > 253402300799LL) throw std::runtime_error("Invalid metadata timestamp");
    return {static_cast<time_t>(seconds), static_cast<long>(nanos)};
}
bool storage_attribute(const std::string& name) {
    return name == "com.apple.decmpfs" || name == "com.apple.system.cprotect" || name == "com.apple.system.Security";
}
bool privileged_attribute(const std::string& name) {
    return name.starts_with("security.") || name.starts_with("trusted.") || name == "com.apple.rootless" || name == "com.apple.macl";
}
std::string attribute_label(const std::string& name) {
    std::string label; constexpr char digits[] = "0123456789abcdef";
    for (unsigned char c : name) {
        if (c >= 32 && c < 127) label += static_cast<char>(c);
        else { label += "\\x"; label += digits[c >> 4]; label += digits[c & 15]; }
    }
    return label;
}
ssize_t list_attributes(int fd, char* buffer, size_t size) {
#ifdef __APPLE__
    return flistxattr(fd, buffer, size, 0);
#else
    return flistxattr(fd, buffer, size);
#endif
}
ssize_t get_attribute(int fd, const char* name, void* buffer, size_t size) {
#ifdef __APPLE__
    return fgetxattr(fd, name, buffer, size, 0, 0);
#else
    return fgetxattr(fd, name, buffer, size);
#endif
}
int set_attribute(int fd, const char* name, const Bytes& bytes) {
#ifdef __APPLE__
    return fsetxattr(fd, name, bytes.data(), bytes.size(), 0, 0);
#else
    return fsetxattr(fd, name, bytes.data(), bytes.size(), 0);
#endif
}
Attributes parse(const Bytes& bytes) {
    if (bytes.size() > MaxMetadata) throw std::runtime_error("Metadata exceeds 64 MiB per-entry limit");
    binary::Reader r{bytes}; Attributes a; r.magic("RZMET001");
    a.platform = r.u32(); a.mode = r.u32(); a.uid = r.u32(); a.gid = r.u32();
    if ((a.platform != 1 && a.platform != 2) || (a.mode & ~07777U)) throw std::runtime_error("Invalid metadata mode/platform");
    a.access = get_time(r); a.modified = get_time(r);
    auto birth = r.u32(); if (birth > 1) throw std::runtime_error("Invalid birth time flag");
    a.has_birth = birth == 1; if (a.has_birth) a.birth = get_time(r);
    a.flags = r.u32(); auto acl = r.u32(); if (acl > 1) throw std::runtime_error("Invalid ACL flag"); a.has_acl = acl == 1;
    auto length = r.u32();
    if (length > 1024 * 1024 || (!a.has_acl && length)) throw std::runtime_error("Invalid ACL size");
    a.acl.resize(length); if (length) r.raw(a.acl.data(), length);
    if (a.acl.find('\0') != std::string::npos) throw std::runtime_error("Invalid ACL text");
    auto count = r.u32(); if (count > 4096) throw std::runtime_error("Too many extended attributes");
    std::set<std::string> names;
    for (uint32_t i = 0; i < count; ++i) {
        auto n = r.u32(); if (n == 0 || n > 1024) throw std::runtime_error("Invalid extended attribute name");
        std::string name(n, '\0'); r.raw(name.data(), n);
        if (name.find('\0') != std::string::npos || !names.insert(name).second) throw std::runtime_error("Invalid or duplicate extended attribute");
        auto size = r.u64(); if (size > MaxMetadata || size > bytes.size() - r.p) throw std::runtime_error("Invalid extended attribute size");
        Bytes value(static_cast<size_t>(size)); if (size) r.raw(value.data(), value.size());
        a.xattrs.emplace_back(std::move(name), std::move(value));
    }
    r.end(); return a;
}
}
void ExtractionReport::warn(const std::string& path, const std::string& detail) {
    ++warning_count;
    if (warnings.size() < 16) warnings.push_back(path + ": " + detail);
}
Bytes capture_metadata(const fs::path& path) {
    check_cancel(); Descriptor file(path); struct stat s{};
    if (fstat(file.fd, &s)) throw std::runtime_error("Cannot read file attributes");
    binary::Writer w; w.limit = MaxMetadata; w.raw("RZMET001", 8);
#ifdef __APPLE__
    w.u32(1);
#else
    w.u32(2);
#endif
    w.u32(static_cast<uint32_t>(s.st_mode & 07777)); w.u32(s.st_uid); w.u32(s.st_gid);
#ifdef __APPLE__
    put_time(w, s.st_atimespec); put_time(w, s.st_mtimespec); w.u32(1); put_time(w, s.st_birthtimespec); w.u32(s.st_flags);
    errno = 0; auto acl = acl_get_fd_np(file.fd, ACL_TYPE_EXTENDED);
    if (acl) {
        ssize_t length = 0; char* text = acl_to_text(acl, &length); acl_free(acl);
        if (!text || length < 0 || length > 1024 * 1024) { if (text) acl_free(text); throw std::runtime_error("Cannot serialize ACL"); }
        w.u32(1); w.u32(static_cast<uint32_t>(length)); w.raw(text, static_cast<size_t>(length)); acl_free(text);
    } else {
        if (errno != ENOENT && errno != ENOTSUP && errno != 0) throw std::runtime_error("Cannot read ACL");
        w.u32(0); w.u32(0);
    }
#else
    put_time(w, s.st_atim); put_time(w, s.st_mtim); w.u32(0); w.u32(0); w.u32(0); w.u32(0);
#endif
    auto names_size = list_attributes(file.fd, nullptr, 0);
    if (names_size < 0 && errno != ENOTSUP) throw std::runtime_error("Cannot enumerate extended attributes");
    if (names_size > 1024 * 1024) throw std::runtime_error("Extended attribute names exceed limit");
    std::vector<std::pair<std::string, Bytes>> attributes;
    if (names_size > 0) {
        Bytes names(static_cast<size_t>(names_size));
        if (list_attributes(file.fd, reinterpret_cast<char*>(names.data()), names.size()) != names_size) throw std::runtime_error("Extended attributes changed during capture");
        uint64_t total = w.b.size();
        for (size_t offset = 0; offset < names.size();) {
            auto end = std::find(names.begin() + static_cast<ptrdiff_t>(offset), names.end(), 0);
            if (end == names.end()) throw std::runtime_error("Invalid filesystem attribute list");
            std::string name(reinterpret_cast<const char*>(names.data() + offset), static_cast<size_t>(end - names.begin()) - offset);
            offset = static_cast<size_t>(end - names.begin()) + 1;
            if (storage_attribute(name)) continue; // physical storage/security representation is not a logical xattr
            auto size = get_attribute(file.fd, name.c_str(), nullptr, 0);
            if (size < 0) throw std::runtime_error("Cannot read extended attribute");
            total += static_cast<uint64_t>(size) + name.size() + 12;
            if (total > MaxMetadata || attributes.size() >= 4096) throw std::runtime_error("Metadata exceeds 64 MiB per-entry limit");
            Bytes value(static_cast<size_t>(size));
            if (get_attribute(file.fd, name.c_str(), value.data(), value.size()) != size) throw std::runtime_error("Extended attribute changed during capture");
            attributes.emplace_back(std::move(name), std::move(value));
        }
    }
    std::sort(attributes.begin(), attributes.end()); w.u32(static_cast<uint32_t>(attributes.size()));
    for (const auto& [name, value] : attributes) {
        w.u32(static_cast<uint32_t>(name.size())); w.raw(name.data(), name.size()); w.u64(value.size()); w.raw(value.data(), value.size());
    }
    validate_metadata(w.b); return w.b;
}
void validate_metadata(const Bytes& bytes) {
    auto attributes = parse(bytes);
#ifdef __APPLE__
    if (attributes.platform == 1 && attributes.has_acl) {
        auto acl = attributes.acl.empty() ? acl_init(0) : acl_from_text(attributes.acl.c_str());
        if (!acl) throw std::runtime_error("Invalid macOS ACL record");
        acl_free(acl);
    }
#endif
}
void restore_metadata(const fs::path& path, const std::string& relative, bool directory, const Bytes& bytes, ExtractionReport& report) {
    auto a = parse(bytes); Descriptor file(path); struct stat s{};
    if (fstat(file.fd, &s) || (directory ? !S_ISDIR(s.st_mode) : !S_ISREG(s.st_mode))) throw std::runtime_error("Metadata target type mismatch");
    auto warn = [&](const std::string& what) { report.warn(relative, what + " (" + std::strerror(errno) + ")"); };
    if (a.uid != s.st_uid) report.warn(relative, "Original owner was retained in the archive but not restored");
    if (a.gid != s.st_gid && fchown(file.fd, static_cast<uid_t>(-1), a.gid)) warn("Group could not be restored");
    if (a.mode & 07000) report.warn(relative, "Special permission bits were not restored");
    for (const auto& [name, value] : a.xattrs) {
        check_cancel();
        if (storage_attribute(name) || privileged_attribute(name)) { report.warn(relative, "Privileged/system extended attribute was not restored: " + attribute_label(name)); continue; }
        if (set_attribute(file.fd, name.c_str(), value)) warn("Extended attribute could not be restored: " + attribute_label(name));
    }
    if (fchmod(file.fd, a.mode & 0777)) warn("Permissions could not be restored");
#ifdef __APPLE__
    if (a.platform == 1) {
        constexpr uint32_t safe_flags = UF_HIDDEN | UF_NODUMP;
        if (a.flags & (UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)) report.warn(relative, "Immutable/append-only flags were not restored");
        if (fchflags(file.fd, a.flags & safe_flags)) warn("Finder flags could not be restored");
    }
    if (a.has_birth) {
        struct attrlist attributes{}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT; attributes.commonattr = ATTR_CMN_CRTIME;
        if (fsetattrlist(file.fd, &attributes, &a.birth, sizeof(a.birth), 0)) warn("Creation time could not be restored");
    }
#else
    if (a.has_birth || a.flags) report.warn(relative, "macOS creation time/flags are unavailable on this platform");
#endif
    timespec times[2] = {a.access, a.modified};
    if (futimens(file.fd, times)) warn("File times could not be restored");
#ifdef __APPLE__
    if (a.platform == 1) {
        auto acl = a.acl.empty() ? acl_init(0) : acl_from_text(a.acl.c_str());
        if (!acl) throw std::runtime_error("Invalid macOS ACL record");
        acl_entry_t entry{}; int selector = ACL_FIRST_ENTRY;
        while (acl_get_entry(acl, selector, &entry) == 0) {
            selector = ACL_NEXT_ENTRY;
            auto* principal = static_cast<unsigned char*>(acl_get_qualifier(entry));
            if (principal) {
                id_t identifier = 0; int type = 0;
                if (mbr_uuid_to_id(principal, &identifier, &type) != 0)
                    report.warn(relative, "ACL identity is unavailable on this machine");
                acl_free(principal);
            }
        }
        if (acl_set_fd_np(file.fd, acl, ACL_TYPE_EXTENDED)) warn("ACL could not be restored");
        acl_free(acl);
    } else if (a.has_acl) report.warn(relative, "ACL platform does not match destination");
#else
    if (a.has_acl) report.warn(relative, "macOS ACL is unavailable on this platform");
#endif
    if (fsync(file.fd)) throw std::runtime_error("Metadata sync failed");
}
void reset_metadata_for_cleanup(const fs::path& root, const std::vector<Entry>& entries) noexcept {
    for (const auto& entry : entries) {
        auto path = root / entry.path;
#ifdef __APPLE__
        if (auto empty = acl_init(0)) {
            (void)acl_set_link_np(path.c_str(), ACL_TYPE_EXTENDED, empty); acl_free(empty);
        }
        (void)lchflags(path.c_str(), 0);
#endif
        (void)fchmodat(AT_FDCWD, path.c_str(), entry.directory ? 0700 : 0600, AT_SYMLINK_NOFOLLOW);
    }
}
}
