#pragma once
#include "format.hpp"
#include <csignal>
#include <atomic>

namespace rz {
// Lock-free atomic operations are safe in the signal handler and across workers.
static_assert(std::atomic<sig_atomic_t>::is_always_lock_free);
extern std::atomic<sig_atomic_t> interrupted;
void check_cancel();
class File {
public:
    enum class Mode { Read, New, Append, Update };
    explicit File(const fs::path& path, Mode mode = Mode::Read, bool optional = false);
    ~File();
    File(const File&) = delete;
    File& operator=(const File&) = delete;
    bool exists() const { return fd_ >= 0; }
    uint64_t size() const;
    bool read(uint64_t offset, void* data, size_t size) const;
    void append(const void* data, size_t size);
    void append(const Bytes& b) { append(b.data(), b.size()); }
    void write(uint64_t offset, const void* data, size_t size);
    void write(uint64_t offset, const Bytes& b) { write(offset, b.data(), b.size()); }
    void resize(uint64_t size);
    void sync();
private:
    int fd_ = -1;
};
class Staging {
public:
    explicit Staging(const fs::path& destination);
    ~Staging();
    fs::path path;
    void commit(bool directories_already_synced = false);
    void commit_with_key(const fs::path& key_file);
private:
    fs::path destination_;
    bool committed_ = false;
};
UUID random_uuid();
void require_directory(const fs::path& path);
bool within(const fs::path& child, const fs::path& parent);
void copy_file_contents(const File& source, File& destination, uint64_t size);
fs::path recovery_key_path(const fs::path& archive);
}
