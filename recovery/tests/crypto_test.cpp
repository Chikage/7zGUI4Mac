#include "protected.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <fstream>
#include <set>
#include <sodium.h>

static void require(bool condition, const char* text) { if (!condition) throw std::runtime_error(text); }
template<class F> static void rejects(F action) {
    bool rejected = false; try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Unauthenticated input was accepted");
}
static rz::Password password(const char* value) {
    rz::Password result; result.size = std::strlen(value); std::memcpy(result.bytes.data(), value, result.size); return result;
}
int main(int argc, char** argv) {
    try {
        auto pass = password("correct test password"); auto wrong = password("incorrect test password");
        require(argc == 2, "Missing upstream crypto vector fixture");
        std::ifstream fixture(argv[1]); std::string json((std::istreambuf_iterator<char>(fixture)), {});
        auto field = [&](const char* name) {
            std::string prefix = std::string("\"") + name + "\": \"";
            auto p = json.find(prefix); require(p != std::string::npos, "Missing vector field"); p += prefix.size();
            return json.substr(p, json.find('"', p) - p);
        };
        auto hex_cipher = field("ciphertext"); rz::Bytes cipher;
        for (size_t i = 0; i < hex_cipher.size(); i += 2) cipher.push_back(static_cast<uint8_t>(std::stoul(hex_cipher.substr(i, 2), nullptr, 16)));
        std::array<uint8_t, 32> vector_key{}; for (size_t i = 0; i < 32; ++i) vector_key[i] = static_cast<uint8_t>(0x80 + i);
        std::array<uint8_t, 24> vector_nonce{7,0,0,0}; for (size_t i = 4; i < 24; ++i) vector_nonce[i] = static_cast<uint8_t>(0x40 + i - 4);
        std::array<uint8_t, 12> vector_ad{0x50,0x51,0x52,0x53,0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7};
        rz::Bytes vector_plain(cipher.size()); unsigned long long plain_size = 0;
        require(crypto_aead_xchacha20poly1305_ietf_decrypt(vector_plain.data(), &plain_size, nullptr, cipher.data(), cipher.size(),
            vector_ad.data(), vector_ad.size(), vector_nonce.data(), vector_key.data()) == 0, "Upstream AEAD vector failed");
        rz::Digest sha{}; crypto_hash_sha256(sha.data(), vector_plain.data(), plain_size);
        require(rz::hex(sha) == field("plaintext_sha256"), "Upstream AEAD vector plaintext mismatch");
        rz::UUID uuid{}; uuid[0] = 42; rz::KeySlot slot;
        auto keys = rz::create_keys(uuid, pass, slot);
        auto unlocked = rz::unlock_keys(uuid, pass, slot);
        rejects([&] { (void)rz::unlock_keys(uuid, wrong, slot); });
        rz::Bytes plain(65536); for (size_t i = 0; i < plain.size(); ++i) plain[i] = static_cast<uint8_t>(i * 73);
        auto compressed = rz::compress_frame(plain); std::set<rz::Bytes> nonces;
        for (auto kind : {rz::RecordKind::Content, rz::RecordKind::Metadata, rz::RecordKind::Index}) {
            auto record = keys.seal(uuid, kind, 123, plain.size(), compressed);
            require(rz::decompress_frame(unlocked.open(uuid, kind, 123, plain.size(), record), plain.size()) == plain, "Encrypted record roundtrip");
            for (size_t offset : {size_t(0), size_t(24), record.size() - 1}) {
                auto changed = record; changed[offset] ^= 1;
                rejects([&] { (void)keys.open(uuid, kind, 123, plain.size(), changed); });
            }
            rejects([&] { (void)keys.open(uuid, kind, 124, plain.size(), record); });
            rejects([&] { (void)keys.open(uuid, kind, 123, plain.size() + 1, record); });
            auto another = uuid; another[1] ^= 1;
            rejects([&] { (void)keys.open(another, kind, 123, plain.size(), record); });
            auto other_kind = kind == rz::RecordKind::Content ? rz::RecordKind::Metadata : rz::RecordKind::Content;
            rejects([&] { (void)keys.open(uuid, other_kind, 123, plain.size(), record); });
        }
        for (int i = 0; i < 64; ++i) {
            auto record = keys.seal(uuid, rz::RecordKind::Content, 123, plain.size(), compressed);
            require(nonces.emplace(record.begin(), record.begin() + 24).second, "Nonce repeated");
        }
        rz::Manifest packed; packed.uuid = uuid; packed.stream_size = 80;
        rz::SecurityInfo security; security.encrypted = true; security.key_slot = slot;
        security.index_plain_size = 24; security.index_frames.push_back({0, 80, 24});
        auto manifest = rz::configure(packed, {}, &security); rz::sign_manifest(manifest, keys);
        require(rz::authenticate_manifest(manifest, &pass).has_value(), "Public manifest authentication");
        auto changed = manifest; changed.options.value = 2500;
        rejects([&] { (void)rz::authenticate_manifest(changed, &pass); });
        auto encoded = rz::serialize(manifest);
        require(rz::serialize(rz::parse_configurable_manifest(encoded)) == encoded, "Profile 3 public encoding roundtrip");
        auto excessive = encoded; excessive[excessive.size() - 128] ^= 255;
        rejects([&] { (void)rz::parse_configurable_manifest(excessive); });
        for (size_t i = 0; i < encoded.size(); ++i) {
            rz::Bytes truncated(encoded.begin(), encoded.begin() + i);
            rejects([&] { (void)rz::parse_configurable_manifest(truncated); });
        }
        std::cout << "Key wrapping, nonce uniqueness, independent AEAD records, AAD binding, manifest authentication and KDF bounds passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
