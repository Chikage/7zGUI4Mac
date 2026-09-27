#include "protected.hpp"
#include "binary.hpp"
#include <sodium.h>
#include <iostream>
#include <cstring>

static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class F> static void rejects(F action) {
    bool rejected = false; try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Invalid dual encryption input accepted");
}
static rz::Password password(const char* text) {
    rz::Password p; p.size = std::strlen(text); std::memcpy(p.bytes.data(), text, p.size); return p;
}
static void derive(unsigned char* out, const unsigned char* key, uint64_t id, const char* context) {
    require(crypto_kdf_blake2b_derive_from_key(out, 32, id, context, key) == 0, "Test key derivation failed");
}
int main() {
    try {
        if (!rz::aes_available()) { std::cout << "AES hardware unavailable; dual crypto skipped\n"; return 77; }
        // NIST AES-256-GCM known-answer case: zero key, 96-bit IV, 16 zero plaintext bytes, empty AAD.
        std::array<uint8_t, 32> key{}; std::array<uint8_t, 12> nonce{}; std::array<uint8_t, 16> plain{};
        rz::Digest encrypted{}; unsigned long long size = 0;
        require(crypto_aead_aes256gcm_encrypt(encrypted.data(), &size, plain.data(), plain.size(), nullptr, 0,
            nullptr, nonce.data(), key.data()) == 0 && size == 32, "AES vector encryption failed");
        require(rz::hex(encrypted) == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919", "NIST AES-256-GCM vector mismatch");

        auto pass = password("dual-test-password"), wrong = password("wrong"); rz::UUID uuid{}; uuid[3] = 73;
        rz::KeySlot slot; slot.suite = rz::DualCryptoProfile;
        auto wrapped_keys = rz::create_keys(uuid, pass, slot), unwrapped = rz::unlock_keys(uuid, pass, slot);
        require(slot.wrapped_key.size() == 96, "Dual key slot size");
        auto compressed = rz::compress_frame(rz::Bytes(65536, 73));
        auto wrapped_record = wrapped_keys.seal(uuid, rz::RecordKind::Content, 0, 65536, compressed);
        require(unwrapped.open(uuid, rz::RecordKind::Content, 0, 65536, wrapped_record) == compressed, "Dual key wrapping roundtrip");
        rejects([&] { (void)unwrapped.seal(uuid, rz::RecordKind::Content, 0, 65536, compressed); });
        rejects([&] { (void)rz::unlock_keys(uuid, wrong, slot); });
        for (int field = 0; field < 5; ++field) {
            auto changed = slot;
            if (field == 0) changed.salt[0] ^= 1;
            if (field == 1) changed.nonce[0] ^= 1;
            if (field == 2) changed.aes_nonce[0] ^= 1;
            if (field == 3) changed.wrapped_key[0] ^= 1;
            if (field == 4) changed.wrapped_key.back() ^= 1;
            rejects([&] { (void)rz::unlock_keys(uuid, pass, changed); });
        }
        // Verify that a valid outer wrap cannot bypass the inner key-wrap tag.
        rz::SecretBytes kek(32), outer_kek(32);
        require(crypto_pwhash(kek.data(), 32, reinterpret_cast<const char*>(pass.bytes.data()), pass.size,
            slot.salt.data(), rz::PasswordOps, rz::PasswordMemory, crypto_pwhash_ALG_ARGON2ID13) == 0, "Test password derivation");
        derive(outer_kek.data(), kek.data(), 2, "RZ3WRAP!");
        rz::binary::Writer wrap_ad; wrap_ad.raw("rz3-keyslot", 11); wrap_ad.raw(uuid.data(), 16);
        wrap_ad.u32(2); wrap_ad.u64(rz::PasswordOps); wrap_ad.u64(rz::PasswordMemory); wrap_ad.raw(slot.salt.data(), 16); wrap_ad.u32(2);
        rz::Bytes inner_wrap(80);
        require(crypto_aead_aes256gcm_decrypt(inner_wrap.data(), &size, nullptr, slot.wrapped_key.data(), 96,
            wrap_ad.b.data(), wrap_ad.b.size(), slot.aes_nonce.data(), outer_kek.data()) == 0, "Outer key wrap vector");
        inner_wrap.back() ^= 1; auto forged_slot = slot;
        require(crypto_aead_aes256gcm_encrypt(forged_slot.wrapped_key.data(), &size, inner_wrap.data(), inner_wrap.size(),
            wrap_ad.b.data(), wrap_ad.b.size(), nullptr, slot.aes_nonce.data(), outer_kek.data()) == 0, "Test rewrap");
        rejects([&] { (void)rz::unlock_keys(uuid, pass, forged_slot); });

        std::array<uint8_t, 64> master{}; for (size_t i = 0; i < master.size(); ++i) master[i] = static_cast<uint8_t>(i + 11);
        rz::ArchiveKeys writer(master.data(), 2), reader(master.data(), 2, false); uint64_t offset = 123;
        for (auto kind : {rz::RecordKind::Content, rz::RecordKind::Metadata, rz::RecordKind::Index}) {
            auto record = writer.seal(uuid, kind, offset, 65536, compressed);
            require(record.size() == compressed.size() + 68, "Dual record overhead");
            require(reader.open(uuid, kind, offset, 65536, record) == compressed, "Dual record roundtrip");
            for (auto position : {size_t(0), size_t(12), record.size() - 1}) {
                auto changed = record; changed[position] ^= 1;
                rejects([&] { (void)reader.open(uuid, kind, offset, 65536, changed); });
            }
            rejects([&] { (void)writer.seal(uuid, kind, offset, 65536, compressed); });
            rejects([&] { (void)writer.seal(uuid, kind, offset + record.size() - 1, 65536, compressed); });
            rejects([&] { (void)reader.open(uuid, kind, offset + 1, 65536, record); });
            rejects([&] { (void)reader.open(uuid, kind, offset, 65535, record); });
            auto other_uuid = uuid; other_uuid[0] ^= 1;
            rejects([&] { (void)reader.open(other_uuid, kind, offset, 65536, record); });
            auto other_kind = kind == rz::RecordKind::Content ? rz::RecordKind::Metadata : rz::RecordKind::Content;
            rejects([&] { (void)reader.open(uuid, other_kind, offset, 65536, record); });
            for (size_t length = 0; length < record.size(); ++length) {
                rz::Bytes truncated(record.begin(), record.begin() + length);
                rejects([&] { (void)reader.open(uuid, kind, offset, 65536, truncated); });
            }
            // Independently peel/reseal AES and corrupt the inner nonce, ciphertext or tag.
            std::array<uint8_t, 32> root{}, aes_key{};
            derive(root.data(), master.data() + 32, static_cast<uint32_t>(kind), "RZ3AES2!");
            derive(aes_key.data(), root.data(), offset, "RZ3REC2!");
            rz::binary::Writer ad; ad.raw("rz3-record", 10); ad.raw(uuid.data(), 16);
            ad.u32(static_cast<uint32_t>(kind)); ad.u64(offset); ad.u32(65536); ad.u32(2); ad.u32(2);
            rz::Bytes inner(record.size() - 28);
            require(crypto_aead_aes256gcm_decrypt(inner.data(), &size, nullptr, record.data() + 12, record.size() - 12,
                ad.b.data(), ad.b.size(), record.data(), aes_key.data()) == 0, "Outer layer interoperable decrypt");
            for (size_t position : {size_t(0), size_t(24), inner.size() - 1}) {
                auto changed = inner; changed[position] ^= 1; auto forged = record;
                require(crypto_aead_aes256gcm_encrypt(forged.data() + 12, &size, changed.data(), changed.size(),
                    ad.b.data(), ad.b.size(), nullptr, forged.data(), aes_key.data()) == 0, "Test reseal");
                rejects([&] { (void)reader.open(uuid, kind, offset, 65536, forged); });
            }
            offset += record.size();
        }
        rz::Manifest packed; packed.uuid = uuid; packed.stream_size = 128;
        rz::SecurityInfo info; info.encrypted = true; info.key_slot = slot;
        info.index_plain_size = 24; info.index_frames.push_back({0, 128, 24});
        auto manifest = rz::configure(packed, {}, &info); rz::sign_manifest(manifest, wrapped_keys);
        auto bytes = rz::serialize(manifest);
        require(rz::serialize(rz::parse_configurable_manifest(bytes)) == bytes, "Dual manifest roundtrip");
        require(rz::authenticate_manifest(manifest, &pass).has_value(), "Dual manifest MAC");
        auto changed = manifest; changed.security.public_mac[0] ^= 1;
        rejects([&] { (void)rz::authenticate_manifest(changed, &pass); });
        changed = manifest; changed.security.key_slot.suite = 1; changed.security.key_slot.wrapped_key.resize(48);
        rejects([&] { (void)rz::authenticate_manifest(changed, &pass); });
        auto unknown = bytes; unknown[unknown.size() - 200] = 99;
        rejects([&] { (void)rz::parse_configurable_manifest(unknown); });
        auto excessive = bytes; excessive[excessive.size() - 196] ^= 255;
        rejects([&] { (void)rz::parse_configurable_manifest(excessive); });
        for (size_t i = 0; i < bytes.size(); ++i) {
            rz::Bytes truncated(bytes.begin(), bytes.begin() + i);
            rejects([&] { (void)rz::parse_configurable_manifest(truncated); });
        }
        std::cout << "AES vector, dual wrapping, both record tags, nonce reuse guard, suite binding and manifest authentication passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
