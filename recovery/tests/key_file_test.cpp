#include "protected.hpp"
#include <cstring>
#include <iostream>

static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class F> static void rejects(F action) {
    bool failed = false; try { action(); } catch (const std::runtime_error&) { failed = true; }
    require(failed, "Invalid recovery credential accepted");
}
int main() {
    auto root = rz::fs::temp_directory_path() / ("rz-key-codec-" + rz::hex(rz::hash(rz::random_uuid().data(), 16)));
    try {
        rz::fs::create_directory(root);
        for (uint32_t suite : {rz::CryptoProfile, rz::DualCryptoProfile}) {
            if (suite == rz::DualCryptoProfile && !rz::aes_available()) continue;
            auto uuid = rz::random_uuid(); auto secret = rz::generate_recovery_key();
            rz::KeySlot slot; slot.suite = suite; slot.key_file = true;
            auto keys = rz::create_keys(uuid, secret, slot);
            auto file = root / (std::to_string(suite) + ".rzkey"); rz::write_key_file(file, uuid, secret);
            auto read = rz::read_key_file(file);
            require(read.archive_uuid == uuid && read.size == 32, "Recovery key identity roundtrip");
            auto unlocked = rz::unlock_keys(uuid, read, slot);
            rz::Bytes bytes{1,2,3,4}; auto record = keys.seal(uuid, rz::RecordKind::Content, 0, 4, bytes);
            require(unlocked.open(uuid, rz::RecordKind::Content, 0, 4, record) == bytes, "Recovery key unwrap");
            read.bytes.data()[0] ^= 1;
            rejects([&] { (void)rz::unlock_keys(uuid, read, slot); });
            read.bytes.data()[0] ^= 1; read.archive_uuid[0] ^= 1;
            rejects([&] { (void)rz::unlock_keys(uuid, read, slot); });
            read.archive_uuid[0] ^= 1;
            rz::Password password; password.size = 32; std::memcpy(password.bytes.data(), read.bytes.data(), 32);
            rejects([&] { (void)rz::unlock_keys(uuid, password, slot); });
            auto downgraded = slot; downgraded.key_file = false;
            rejects([&] { (void)rz::unlock_keys(uuid, read, downgraded); });
        }
        rz::fs::remove_all(root);
        std::cout << "Key-file wrapping, credential domains, UUID binding passed\n";
        return 0;
    } catch (const std::exception& e) {
        std::error_code error; rz::fs::remove_all(root, error); std::cerr << e.what() << '\n'; return 1;
    }
}
