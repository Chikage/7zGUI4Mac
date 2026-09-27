#include "crypto.hpp"
#include "binary.hpp"
#include "io.hpp"
#include <cstdio>
#include <sodium.h>
#include <utility>

static_assert(crypto_aead_xchacha20poly1305_ietf_KEYBYTES == 32);
static_assert(crypto_aead_xchacha20poly1305_ietf_NPUBBYTES == 24);
static_assert(crypto_aead_xchacha20poly1305_ietf_ABYTES == 16);
static_assert(crypto_pwhash_SALTBYTES == 16);
static_assert(crypto_aead_aes256gcm_KEYBYTES == 32);
static_assert(crypto_aead_aes256gcm_NPUBBYTES == 12);
static_assert(crypto_aead_aes256gcm_ABYTES == 16);

namespace rz {
namespace {
void initialize() {
    static const int status = sodium_init();
    if (status < 0) throw std::runtime_error("Cryptographic initialization failed");
}
Bytes slot_aad(const UUID& uuid, const KeySlot& slot, uint32_t layer = 0) {
    binary::Writer w; w.raw("rz3-keyslot", 11); w.raw(uuid.data(), uuid.size());
    w.u32(slot.suite); w.u64(slot.key_file ? 0 : PasswordOps); w.u64(slot.key_file ? 0 : PasswordMemory); w.raw(slot.salt.data(), slot.salt.size());
    if (slot.suite == DualCryptoProfile) w.u32(layer);
    if (slot.key_file) w.raw("rz-keyfile-v1", 13);
    return w.b;
}
Bytes record_aad(const UUID& uuid, RecordKind kind, uint64_t offset, uint32_t size, uint32_t suite, uint32_t layer) {
    binary::Writer w; w.raw("rz3-record", 10); w.raw(uuid.data(), uuid.size());
    w.u32(static_cast<uint32_t>(kind)); w.u64(offset); w.u32(size);
    if (suite == DualCryptoProfile) { w.u32(suite); w.u32(layer); }
    return w.b;
}
SecretBytes derive(const unsigned char* master, uint64_t id, const char* context) {
    SecretBytes key(32);
    if (crypto_kdf_blake2b_derive_from_key(key.data(), 32, id, context, master) != 0)
        throw std::runtime_error("Archive subkey derivation failed");
    return key;
}
void require_aes() {
    if (!aes_available()) throw std::runtime_error("AES-256-GCM is unavailable on this CPU");
}
Digest key_file_checksum(const void* data, size_t size) {
    blake3_hasher hasher; blake3_hasher_init(&hasher); blake3_hasher_update(&hasher, data, size);
    Digest digest{}; blake3_hasher_finalize(&hasher, digest.data(), digest.size());
    sodium_memzero(&hasher, sizeof hasher); return digest;
}
SecretBytes password_key(const Password& password, const KeySlot& slot, const UUID& uuid) {
    check_cancel();
    if (slot.key_file) {
        if (!password.from_key_file || password.size != 32) throw KeyFileError();
        SecretBytes key(32); binary::Writer context;
        context.raw("rz-keyfile-kek-v1", 17); context.raw(uuid.data(), uuid.size()); context.raw(slot.salt.data(), slot.salt.size());
        if (crypto_generichash_blake2b(key.data(), 32, context.b.data(), context.b.size(), password.bytes.data(), 32) != 0)
            throw std::runtime_error("Recovery key derivation failed");
        return key;
    }
    if (password.from_key_file) throw PasswordError();
    if (!password.size) throw PasswordError();
    SecretBytes key(32);
    if (crypto_pwhash(key.data(), 32, reinterpret_cast<const char*>(password.bytes.data()), password.size,
                     slot.salt.data(), PasswordOps, PasswordMemory, crypto_pwhash_ALG_ARGON2ID13) != 0)
        throw std::runtime_error("Password derivation failed (memory unavailable)");
    check_cancel(); return key;
}
}
bool aes_available() {
    initialize();
#ifdef RZ_TEST_WITHOUT_AES
    return false; // Exercise unsupported hardware in the dedicated test executable.
#else
    return crypto_aead_aes256gcm_is_available() == 1;
#endif
}
void validate_crypto_suite(uint32_t suite) {
    if (suite != CryptoProfile && suite != DualCryptoProfile) throw std::runtime_error("Unsupported encryption suite");
}
SecretBytes::SecretBytes(size_t size) {
    initialize(); bytes_ = static_cast<unsigned char*>(sodium_malloc(size));
    if (!bytes_) throw std::bad_alloc();
    sodium_memzero(bytes_, size);
}
SecretBytes::~SecretBytes() { sodium_free(bytes_); }
SecretBytes::SecretBytes(SecretBytes&& other) noexcept : bytes_(std::exchange(other.bytes_, nullptr)) {}
SecretBytes& SecretBytes::operator=(SecretBytes&& other) noexcept {
    if (this != &other) { sodium_free(bytes_); bytes_ = std::exchange(other.bytes_, nullptr); }
    return *this;
}
Password read_password() {
    Password password;
    for (;;) {
        int c = std::getchar();
        if (c == '\n' || c == EOF) break;
        if (c < 32 || c == 127 || password.size == 1024) throw std::runtime_error("Password must be a single line of at most 1024 UTF-8 bytes");
        password.bytes.data()[password.size++] = static_cast<unsigned char>(c);
    }
    if (!password.size) throw PasswordError();
    return password;
}
Password generate_recovery_key() {
    Password key; key.size = 32; key.from_key_file = true;
    randombytes_buf(key.bytes.data(), key.size); return key;
}
Password read_key_file(const fs::path& path) {
    try {
        File file(path); if (file.size() != 88) throw KeyFileError();
        Bytes bytes(88); WipeOnExit cleanup(bytes);
        if (!file.read(0, bytes.data(), bytes.size()) || std::memcmp(bytes.data(), "RZKEY001", 8) != 0) throw KeyFileError();
        auto checksum = key_file_checksum(bytes.data(), 56);
        if (sodium_memcmp(checksum.data(), bytes.data() + 56, 32) != 0) throw KeyFileError();
        Password key; key.size = 32; key.from_key_file = true;
        std::memcpy(key.archive_uuid.data(), bytes.data() + 8, 16); std::memcpy(key.bytes.data(), bytes.data() + 24, 32);
        return key;
    } catch (const std::runtime_error&) { check_cancel(); throw KeyFileError(); }
}
void write_key_file(const fs::path& path, const UUID& uuid, const Password& key) {
    if (!key.from_key_file || key.size != 32) throw KeyFileError();
    binary::Writer w; w.b.reserve(88); WipeOnExit cleanup(w.b);
    w.raw("RZKEY001", 8); w.raw(uuid.data(), 16); w.raw(key.bytes.data(), 32);
    auto checksum = key_file_checksum(w.b.data(), w.b.size()); w.raw(checksum.data(), 32);
    File file(path, File::Mode::New); file.append(w.b); file.sync();
}
ArchiveKeys::ArchiveKeys(const unsigned char* master, uint32_t suite, bool writable, uint64_t max_output)
    : suite_(suite), writable_(writable), max_record_offset_(max_output) {
    if (max_output > UINT64_MAX - max_output / 100) throw std::runtime_error("Invalid encrypted stream limit");
    max_record_offset_ += max_output / 100;
    validate_crypto_suite(suite);
    for (uint64_t id = 1; id <= 4; ++id)
        if (crypto_kdf_blake2b_derive_from_key(keys_.data() + (id - 1) * 32, 32, id,
            suite == CryptoProfile ? "RZ3KEYS!" : "RZ3DUAL!", master) != 0)
            throw std::runtime_error("Archive subkey derivation failed");
    if (suite == DualCryptoProfile) {
        require_aes();
        for (uint64_t id = 1; id <= 3; ++id) {
            auto key = derive(master + 32, id, "RZ3AES2!");
            std::memcpy(keys_.data() + 128 + (id - 1) * 32, key.data(), 32);
        }
        constexpr unsigned char domain[] = "rz3-dual-manifest-key";
        if (crypto_generichash_blake2b(keys_.data() + 96, 32, domain, sizeof(domain) - 1, master, 64) != 0)
            throw std::runtime_error("Archive manifest key derivation failed");
    }
}
ArchiveKeys create_keys(const UUID& uuid, const Password& password, KeySlot& slot, uint64_t max_output) {
    validate_crypto_suite(slot.suite); bool dual = slot.suite == DualCryptoProfile;
    if (dual) require_aes();
    initialize(); randombytes_buf(slot.salt.data(), slot.salt.size()); randombytes_buf(slot.nonce.data(), slot.nonce.size());
    const size_t master_size = dual ? 64 : 32;
    SecretBytes master(master_size); randombytes_buf(master.data(), master_size);
    auto key = password_key(password, slot, uuid);
    auto inner_key = dual ? derive(key.data(), 1, "RZ3WRAP!") : SecretBytes(32);
    if (!dual) std::memcpy(inner_key.data(), key.data(), 32);
    auto aad = slot_aad(uuid, slot, 1); unsigned long long size = 0;
    Bytes wrapped(master_size + 16); WipeOnExit wipe_wrapped(wrapped);
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(wrapped.data(), &size, master.data(), master_size,
        aad.data(), aad.size(), nullptr, slot.nonce.data(), inner_key.data()) != 0 || size != wrapped.size())
        throw std::runtime_error("Key wrapping failed");
    if (dual) {
        auto outer_key = derive(key.data(), 2, "RZ3WRAP!"); auto outer_aad = slot_aad(uuid, slot, 2);
        randombytes_buf(slot.aes_nonce.data(), slot.aes_nonce.size()); slot.wrapped_key.resize(wrapped.size() + 16);
        if (crypto_aead_aes256gcm_encrypt(slot.wrapped_key.data(), &size, wrapped.data(), wrapped.size(),
            outer_aad.data(), outer_aad.size(), nullptr, slot.aes_nonce.data(), outer_key.data()) != 0 || size != slot.wrapped_key.size())
            throw std::runtime_error("Key wrapping failed");
    } else slot.wrapped_key = std::move(wrapped);
    return ArchiveKeys(master.data(), slot.suite, true, max_output);
}
ArchiveKeys unlock_keys(const UUID& uuid, const Password& password, const KeySlot& slot) {
    validate_crypto_suite(slot.suite); bool dual = slot.suite == DualCryptoProfile;
    if (slot.wrapped_key.size() != (dual ? 96 : 48)) throw std::runtime_error("Invalid wrapped key size");
    if (dual) require_aes();
    if (slot.key_file && (!password.from_key_file || password.archive_uuid != uuid)) throw KeyFileError();
    auto key = password_key(password, slot, uuid);
    auto inner_key = dual ? derive(key.data(), 1, "RZ3WRAP!") : SecretBytes(32);
    if (!dual) std::memcpy(inner_key.data(), key.data(), 32);
    auto aad = slot_aad(uuid, slot, 1); SecretBytes master(dual ? 64 : 32); unsigned long long size = 0;
    Bytes wrapped = slot.wrapped_key; WipeOnExit wipe_wrapped(wrapped);
    if (dual) {
        auto outer_key = derive(key.data(), 2, "RZ3WRAP!"); auto outer_aad = slot_aad(uuid, slot, 2);
        wrapped.resize(80);
        if (crypto_aead_aes256gcm_decrypt(wrapped.data(), &size, nullptr, slot.wrapped_key.data(), slot.wrapped_key.size(),
            outer_aad.data(), outer_aad.size(), slot.aes_nonce.data(), outer_key.data()) != 0 || size != 80)
            { if (slot.key_file) throw KeyFileError(); throw PasswordError(); }
    }
    auto status = crypto_aead_xchacha20poly1305_ietf_decrypt(master.data(), &size, nullptr, wrapped.data(), wrapped.size(),
        aad.data(), aad.size(), slot.nonce.data(), inner_key.data());
    if (status != 0 || size != (dual ? 64U : 32U)) { if (slot.key_file) throw KeyFileError(); throw PasswordError(); }
    return ArchiveKeys(master.data(), slot.suite, false);
}
Bytes ArchiveKeys::seal(const UUID& uuid, RecordKind kind, uint64_t offset, uint32_t plain_size, const Bytes& compressed) {
    auto id = static_cast<uint32_t>(kind); bool dual = suite_ == DualCryptoProfile;
    if (!writable_ || id < 1 || id > 3 || plain_size > FrameSize || compressed.size() > FrameSize + FrameSize / 100 - 68)
        throw std::runtime_error("Invalid encrypted record input");
    if (dual && (offset < next_offset_ || offset > max_record_offset_ || offset > UINT64_MAX - compressed.size() - 68))
        throw std::runtime_error("Encrypted record positions must advance; refusing nonce reuse");
    Bytes out(compressed.size() + RecordOverhead); randombytes_buf(out.data(), 24);
    auto aad = record_aad(uuid, kind, offset, plain_size, suite_, 1); unsigned long long size = 0;
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(out.data() + 24, &size, compressed.data(), compressed.size(),
        aad.data(), aad.size(), nullptr, out.data(), keys_.data() + (id - 1) * 32) != 0 || size + 24 != out.size())
        throw std::runtime_error("Record encryption failed");
    if (dual) {
        // A fresh per-record AES key bounds GCM use to one <=4 MiB compressed frame.
        auto aes_key = derive(keys_.data() + 128 + (id - 1) * 32, offset, "RZ3REC2!");
        auto outer_aad = record_aad(uuid, kind, offset, plain_size, suite_, 2);
        binary::Writer nonce; nonce.u32(id); nonce.u64(offset);
        Bytes outer(out.size() + 28); std::copy(nonce.b.begin(), nonce.b.end(), outer.begin());
        if (crypto_aead_aes256gcm_encrypt(outer.data() + 12, &size, out.data(), out.size(), outer_aad.data(), outer_aad.size(),
            nullptr, outer.data(), aes_key.data()) != 0 || size + 12 != outer.size()) throw std::runtime_error("Record encryption failed");
        wipe(out); out = std::move(outer); next_offset_ = offset + out.size();
    }
    return out;
}
Bytes ArchiveKeys::open(const UUID& uuid, RecordKind kind, uint64_t offset, uint32_t plain_size, const Bytes& record) const {
    auto id = static_cast<uint32_t>(kind); bool dual = suite_ == DualCryptoProfile;
    if (id < 1 || id > 3 || record.size() < RecordOverhead + (dual ? 28 : 0) || record.size() > FrameSize + FrameSize / 100)
        throw std::runtime_error("Invalid encrypted record size");
    Bytes inner; WipeOnExit wipe_inner(inner); const Bytes* source = &record; unsigned long long size = 0;
    if (dual) {
        auto aes_key = derive(keys_.data() + 128 + (id - 1) * 32, offset, "RZ3REC2!");
        auto outer_aad = record_aad(uuid, kind, offset, plain_size, suite_, 2);
        binary::Writer nonce; nonce.u32(id); nonce.u64(offset);
        if (sodium_memcmp(record.data(), nonce.b.data(), 12) != 0) throw std::runtime_error("Archive authentication failed");
        inner.resize(record.size() - 28);
        if (crypto_aead_aes256gcm_decrypt(inner.data(), &size, nullptr, record.data() + 12, record.size() - 12,
            outer_aad.data(), outer_aad.size(), record.data(), aes_key.data()) != 0 || size != inner.size())
            throw std::runtime_error("Archive authentication failed");
        source = &inner;
    }
    Bytes out(source->size() - RecordOverhead); WipeOnExit wipe_out(out);
    auto aad = record_aad(uuid, kind, offset, plain_size, suite_, 1);
    auto status = crypto_aead_xchacha20poly1305_ietf_decrypt(out.data(), &size, nullptr, source->data() + 24, source->size() - 24,
        aad.data(), aad.size(), source->data(), keys_.data() + (id - 1) * 32);
    if (status != 0 || size != out.size())
        throw std::runtime_error("Archive authentication failed");
    wipe_out.release(); return out;
}
Digest ArchiveKeys::manifest_mac(const Bytes& bytes) const {
    blake3_hasher h; blake3_hasher_init_keyed(&h, keys_.data() + 96);
    WipeMemoryOnExit wipe_hasher(&h, sizeof h);
    constexpr char domain[] = "rz3-public-index";
    blake3_hasher_update(&h, domain, sizeof(domain) - 1); blake3_hasher_update(&h, bytes.data(), bytes.size());
    Digest out{}; blake3_hasher_finalize(&h, out.data(), out.size()); return out;
}
bool secure_equal(const Digest& a, const Digest& b) { return sodium_memcmp(a.data(), b.data(), a.size()) == 0; }
void wipe(void* data, size_t size) noexcept { if (size) sodium_memzero(data, size); }
void wipe(Bytes& bytes) noexcept { wipe(bytes.data(), bytes.size()); }
}
