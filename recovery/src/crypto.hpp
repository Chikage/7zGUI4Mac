#pragma once
#include "codec.hpp"
#include <memory>
#include <stdexcept>
#include <filesystem>

namespace rz {
constexpr uint32_t CryptoProfile = 1;
constexpr uint32_t DualCryptoProfile = 2;
constexpr uint64_t PasswordOps = 3, PasswordMemory = 64 * 1024 * 1024;
constexpr uint32_t RecordOverhead = 40;
enum class RecordKind : uint32_t { Content = 1, Metadata = 2, Index = 3 };
class PasswordError : public std::runtime_error {
public: PasswordError() : std::runtime_error("Password required or incorrect") {}
};
class KeyFileError : public std::runtime_error {
public: KeyFileError() : std::runtime_error("Matching recovery key file required or invalid") {}
};
class SecretBytes {
public:
    explicit SecretBytes(size_t size);
    ~SecretBytes();
    SecretBytes(const SecretBytes&) = delete;
    SecretBytes& operator=(const SecretBytes&) = delete;
    SecretBytes(SecretBytes&& other) noexcept;
    SecretBytes& operator=(SecretBytes&& other) noexcept;
    unsigned char* data() const { return bytes_; }
private:
    unsigned char* bytes_ = nullptr;
};
struct Password {
    SecretBytes bytes{1025};
    size_t size = 0;
    bool from_key_file = false;
    UUID archive_uuid{};
};
Password read_password();
Password generate_recovery_key();
Password read_key_file(const std::filesystem::path& path);
void write_key_file(const std::filesystem::path& path, const UUID& uuid, const Password& key);
bool aes_available();
void validate_crypto_suite(uint32_t suite);
struct KeySlot {
    uint32_t suite = CryptoProfile;
    bool key_file = false;
    std::array<uint8_t, 16> salt{};
    std::array<uint8_t, 24> nonce{};
    std::array<uint8_t, 12> aes_nonce{};
    Bytes wrapped_key = Bytes(48);
};
class ArchiveKeys {
public:
    explicit ArchiveKeys(const unsigned char* master, uint32_t suite = CryptoProfile, bool writable = true);
    Bytes seal(const UUID& uuid, RecordKind kind, uint64_t offset, uint32_t plain_size, const Bytes& compressed);
    Bytes open(const UUID& uuid, RecordKind kind, uint64_t offset, uint32_t plain_size, const Bytes& record) const;
    Digest manifest_mac(const Bytes& manifest_with_zero_mac) const;
private:
    SecretBytes keys_{224};
    uint32_t suite_;
    bool writable_;
    uint64_t next_offset_ = 0;
};
ArchiveKeys create_keys(const UUID& uuid, const Password& password, KeySlot& slot);
ArchiveKeys unlock_keys(const UUID& uuid, const Password& password, const KeySlot& slot);
bool secure_equal(const Digest& a, const Digest& b);
void wipe(Bytes& bytes);
class WipeOnExit {
public:
    explicit WipeOnExit(Bytes& bytes, bool enabled = true) : bytes_(bytes), enabled_(enabled) {}
    ~WipeOnExit() { if (enabled_) wipe(bytes_); }
    WipeOnExit(const WipeOnExit&) = delete;
    WipeOnExit& operator=(const WipeOnExit&) = delete;
private:
    Bytes& bytes_;
    bool enabled_;
};
}
