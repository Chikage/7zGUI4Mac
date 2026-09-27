#include "io.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/random.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif
#ifdef __linux__
#include <sys/syscall.h>
#include <linux/fs.h>
#endif

namespace rz {
std::atomic<sig_atomic_t> interrupted{0};
void check_cancel() { if (interrupted.load(std::memory_order_relaxed)) throw std::runtime_error("Operation cancelled"); }
static void io_error(const std::string& action) { throw std::runtime_error(action + ": " + std::strerror(errno)); }
File::File(const fs::path& path, Mode mode, bool optional) {
    check_cancel();
    int flags = O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
    flags |= mode == Mode::New ? O_WRONLY | O_CREAT | O_EXCL : mode == Mode::Append ? O_WRONLY | O_APPEND : O_RDONLY;
    fd_ = ::open(path.c_str(), flags, 0600);
    if (fd_ < 0) {
        if (optional && errno == ENOENT) return;
        io_error("Cannot open " + path.string());
    }
    struct stat s{};
    if (::fstat(fd_, &s) || !S_ISREG(s.st_mode)) {
        ::close(fd_); fd_ = -1; throw std::runtime_error("Expected a regular file: " + path.string());
    }
}
File::~File() { if (fd_ >= 0) ::close(fd_); }
uint64_t File::size() const {
    struct stat s{};
    if (fd_ < 0 || ::fstat(fd_, &s)) throw std::runtime_error("Cannot stat file");
    return static_cast<uint64_t>(s.st_size);
}
bool File::read(uint64_t offset, void* data, size_t size) const {
    if (fd_ < 0) return false;
    auto* p = static_cast<uint8_t*>(data);
    while (size) {
        check_cancel();
        auto n = ::pread(fd_, p, size, static_cast<off_t>(offset));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n); offset += static_cast<uint64_t>(n);
    }
    return true;
}
void File::append(const void* data, size_t size) {
    auto* p = static_cast<const uint8_t*>(data);
    while (size) {
        check_cancel();
        auto n = ::write(fd_, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) io_error("Write failed");
        p += n; size -= static_cast<size_t>(n);
    }
}
void File::sync() { if (::fsync(fd_) != 0) io_error("File sync failed"); }
void require_directory(const fs::path& path) {
    if (!fs::is_directory(fs::symlink_status(path))) throw std::runtime_error("Expected a directory, not a symlink: " + path.string());
}
bool within(const fs::path& child, const fs::path& parent) {
    auto c = child.begin();
    for (auto p = parent.begin(); p != parent.end(); ++p, ++c)
        if (c == child.end() || *c != *p) return false;
    return true;
}
static void sync_directory(const fs::path& path) {
    int fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) io_error("Cannot open directory for sync");
    int result = ::fsync(fd), error = errno;
    ::close(fd); errno = error;
    if (result != 0) io_error("Directory sync failed");
}
Staging::Staging(const fs::path& destination) {
    auto absolute = fs::absolute(destination).lexically_normal();
    if (absolute.filename().empty() || absolute.filename() == "." || absolute.filename() == "..")
        throw std::runtime_error("Invalid destination");
    auto parent = fs::canonical(absolute.parent_path()); require_directory(parent);
    destination_ = parent / absolute.filename();
    if (fs::exists(fs::symlink_status(destination_))) throw std::runtime_error("Destination already exists");
    auto pattern = (parent / ".rz-stage-XXXXXX").string();
    if (!::mkdtemp(pattern.data())) io_error("Cannot create staging directory");
    path = pattern;
#ifdef __APPLE__
    // A 0700 mode alone does not suppress inherited macOS allow ACLs.
    auto acl = acl_init(0);
    bool private_acl = acl && acl_set_link_np(path.c_str(), ACL_TYPE_EXTENDED, acl) == 0;
    if (acl) acl_free(acl);
    if (!private_acl) {
        std::error_code error; fs::remove(path, error);
        throw std::runtime_error("Cannot secure temporary directory ACL");
    }
#endif
}
Staging::~Staging() { if (!committed_) { std::error_code ec; fs::remove_all(path, ec); } }
void Staging::commit(bool directories_already_synced) {
    check_cancel();
    std::vector<fs::path> directories{path};
    if (!directories_already_synced) {
        for (const auto& e : fs::recursive_directory_iterator(path))
            if (e.is_directory()) directories.push_back(e.path());
    }
    for (auto i = directories.rbegin(); i != directories.rend(); ++i) sync_directory(*i);
#ifdef __APPLE__
    int result = ::renameatx_np(AT_FDCWD, path.c_str(), AT_FDCWD, destination_.c_str(), RENAME_EXCL);
#elif defined(__linux__)
    int result = static_cast<int>(::syscall(SYS_renameat2, AT_FDCWD, path.c_str(), AT_FDCWD, destination_.c_str(), RENAME_NOREPLACE));
#else
#error Atomic no-replace directory publication requires macOS or Linux.
#endif
    if (result != 0) io_error("Cannot publish output (destination must not exist)");
    committed_ = true;
    sync_directory(destination_.parent_path());
}
UUID random_uuid() {
    UUID id{};
    if (::getentropy(id.data(), id.size()) != 0) io_error("Cannot obtain random archive ID");
    return id;
}
fs::path recovery_key_path(const fs::path& archive) {
    auto key = archive; key.replace_extension(".rzkey");
    if (key == archive) throw std::runtime_error("Archive and key file paths must differ");
    return key;
}
void Staging::commit_with_key(const fs::path& key_file) {
    auto destination = recovery_key_path(destination_);
    struct stat original{};
    if (::lstat(key_file.c_str(), &original) || !S_ISREG(original.st_mode) || (original.st_mode & 0777) != 0600)
        throw std::runtime_error("Cannot secure recovery key file");
    check_cancel();
    // Publish the key first, exclusively. A crash may leave an orphan key, never
    // a newly published archive whose only key was still in a temporary directory.
    if (::link(key_file.c_str(), destination.c_str()) != 0) io_error("Cannot publish recovery key file (destination must not exist)");
    try {
        sync_directory(destination_.parent_path());
        fs::remove(key_file);
        commit();
    } catch (...) {
        struct stat current{};
        if (!committed_ && ::lstat(destination.c_str(), &current) == 0 && current.st_dev == original.st_dev && current.st_ino == original.st_ino)
            (void)::unlink(destination.c_str());
        throw;
    }
}
void copy_file_contents(const File& source, File& dest, uint64_t size) {
    Bytes block(BlockSize);
    for (uint64_t offset = 0; offset < size;) {
        auto n = static_cast<size_t>(std::min<uint64_t>(block.size(), size - offset));
        if (!source.read(offset, block.data(), n)) throw std::runtime_error("Truncated source during copy");
        dest.append(block.data(), n); offset += n;
    }
}
}
