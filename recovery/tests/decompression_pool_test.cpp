#include "decompression_pool.hpp"
#include "protected.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <map>
#include <random>
#include <thread>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class Action> void rejects(Action action, const char* message) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, message);
}
rz::Bytes bytes(size_t size, size_t seed) {
    std::mt19937 random(static_cast<uint32_t>(seed)); rz::Bytes result(size);
    for (auto& byte : result) byte = static_cast<uint8_t>(random());
    return result;
}
size_t size_for(size_t id) { return id == 0 ? rz::FrameSize : id % 5 == 0 ? rz::FrameSize / 2 : 73 + id; }
std::unique_ptr<rz::DecompressionJob> job(size_t id, const rz::UUID& uuid, rz::ArchiveKeys* writer = nullptr) {
    auto result = std::make_unique<rz::DecompressionJob>(writer != nullptr);
    result->entry = id; result->offset = id * (rz::FrameSize + 65536ULL);
    result->plain_size = static_cast<uint32_t>(size_for(id));
    result->kind = static_cast<rz::RecordKind>(1 + id % 3);
    auto compressed = rz::compress_frame(bytes(result->plain_size, id));
    rz::WipeOnExit cleanup(compressed, writer != nullptr);
    result->record = writer ? writer->seal(uuid, result->kind, result->offset, result->plain_size, compressed) : std::move(compressed);
    return result;
}
void queues(uint32_t suite, uint32_t threads) {
    rz::UUID uuid{}; uuid[0] = 73;
    std::array<unsigned char, 64> master{}; master[0] = 51;
    std::optional<rz::ArchiveKeys> writer, reader;
    if (suite) { writer.emplace(master.data(), suite); reader.emplace(master.data(), suite, false); }
    rz::DecompressionPool pool(uuid, reader ? &*reader : nullptr, threads);
    require(pool.limits().estimated_bytes <= rz::DecompressionMemoryBudget, "decoder admission exceeds memory budget");
    const auto slots = pool.limits().slots;
    for (size_t i = 0; i < slots; ++i) pool.submit(job(i, uuid, writer ? &*writer : nullptr));
    require(pool.full(), "completed output still occupies admission slots");
    rejects([&] { pool.submit(job(slots + 100, uuid)); }, "unbounded decoder admission accepted");
    for (size_t i = 0; i < slots * 2; ++i) {
        auto result = pool.take();
        require(result->entry == i, "decoder must return results in submission order");
        require(result->record.empty(), "input record remains resident after decoding");
        require(result->plain == bytes(size_for(i), i), "authenticated decoded content differs");
        result.reset();
        if (i < slots) pool.submit(job(i + slots, uuid, writer ? &*writer : nullptr));
    }
    require(pool.empty(), "decoder did not drain");
}
void failures() {
    rz::UUID uuid{};
    rejects([&] { rz::DecompressionPool pool(uuid, nullptr, 65); }, "invalid worker count accepted");
    // Authentication errors and invalid independent Zstd frames must propagate
    // while other jobs may still be running, without hangs or leaked workers.
    std::array<unsigned char, 64> master{};
    for (uint32_t suite : {0U, rz::CryptoProfile, rz::DualCryptoProfile}) {
        if (suite == rz::DualCryptoProfile && !rz::aes_available()) continue;
        for (uint32_t failure = 0; failure < (suite ? 4U : 1U); ++failure) {
            std::optional<rz::ArchiveKeys> writer, reader;
            if (suite) { writer.emplace(master.data(), suite); reader.emplace(master.data(), suite, false); }
            rejects([&] {
                rz::DecompressionPool pool(uuid, reader ? &*reader : nullptr, 4);
                pool.submit(job(0, uuid, writer ? &*writer : nullptr));
                auto broken = job(1, uuid, writer ? &*writer : nullptr);
                if (!suite) broken->record = {1, 2, 3, 4};
                else if (failure == 0) broken->record.back() ^= 1;
                else if (failure == 1) ++broken->offset;
                else if (failure == 2) ++broken->plain_size;
                else broken->kind = rz::RecordKind::Content;
                pool.submit(std::move(broken));
                while (!pool.empty()) (void)pool.take();
            }, "corrupt or misbound record accepted");
        }
    }
    {
        rz::ArchiveKeys reader(master.data(), rz::CryptoProfile, false);
        rz::DecompressionPool pool(uuid, &reader, 4);
        rejects([&] { pool.submit(job(1, uuid)); }, "encrypted output can escape sensitive lifetime tracking");
    }
    {
        rz::DecompressionPool pool(uuid, nullptr, 4);
        for (size_t i = 0; i < pool.limits().slots; ++i) pool.submit(job(i, uuid));
        rz::interrupted.store(SIGTERM);
        rejects([&] { (void)pool.take(); }, "cancellation did not interrupt decoder wait");
    }
    rz::interrupted.store(0);
    // Caller abandonment also joins workers before freeing their jobs.
    { rz::DecompressionPool pool(uuid, nullptr, 4); for (size_t i = 0; i < 5; ++i) pool.submit(job(i, uuid)); }
    rz::FrameDecoder decoder;
    auto plain = bytes(16384, 9); auto compressed = rz::compress_frame(plain);
    auto trailing = compressed; trailing.push_back(0);
    rejects([&] { (void)decoder.decode(trailing, plain.size()); }, "trailing data accepted as an independent frame");
    rejects([&] { (void)decoder.decode(compressed, plain.size() - 1); }, "incorrect expanded size accepted");
    require(decoder.decode(compressed, plain.size()) == plain, "decoder context cannot be reused after rejected input");
}
void cleanup() {
    rz::Bytes secret(8192, 93);
    rejects([&] { rz::WipeOnExit guard(secret); throw std::runtime_error("injected error"); }, "injected failure absent");
    require(std::all_of(secret.begin(), secret.end(), [](auto byte) { return byte == 0; }), "exception did not wipe plaintext");
    secret.assign(8192, 73);
    { rz::WipeOnExit guard(secret); guard.release(); }
    require(secret.front() == 73 && secret.back() == 73, "successful ownership transfer wiped returned data");
    blake3_hasher state; std::array<uint8_t, 32> key{};
    {
        rz::WipeMemoryOnExit guard(&state, sizeof state);
        blake3_hasher_init_keyed(&state, key.data());
        blake3_hasher_update(&state, secret.data(), secret.size());
    }
    const auto* raw = reinterpret_cast<const unsigned char*>(&state);
    require(std::all_of(raw, raw + sizeof state, [](auto byte) { return byte == 0; }), "keyed hash state not wiped");
}
void verification() {
    rz::ConfigurableManifest manifest; manifest.profile = 3;
    std::array<unsigned char, 64> master{};
    rz::ArchiveKeys writer(master.data()), reader(master.data(), rz::CryptoProfile, false);
    manifest.security.encrypted = true;
    rz::Entry entry; entry.path = "content"; blake3_hasher digest; blake3_hasher_init(&digest);
    std::map<uint64_t, rz::Bytes> records;
    uint64_t offset = 0;
    for (size_t i = 0; i < 5; ++i) {
        auto plain = bytes(i == 4 ? 57 : rz::FrameSize, i);
        blake3_hasher_update(&digest, plain.data(), plain.size());
        auto compressed = rz::compress_frame(plain);
        auto record = writer.seal(manifest.uuid, rz::RecordKind::Content, offset, plain.size(), compressed);
        entry.frames.push_back({offset, static_cast<uint32_t>(record.size()), static_cast<uint32_t>(plain.size())});
        entry.size += plain.size(); offset += record.size(); records.emplace(entry.frames.back().offset, std::move(record));
    }
    blake3_hasher_finalize(&digest, entry.digest.data(), entry.digest.size());
    manifest.entries.push_back(entry);
    rz::Entry empty; empty.digest = rz::hash(nullptr, 0); manifest.entries.push_back(empty);
    const auto coordinator = std::this_thread::get_id();
    rz::RecordReader read = [&](uint64_t position, uint32_t size) {
        require(std::this_thread::get_id() == coordinator, "record reader called from worker thread");
        const auto& record = records.at(position); require(record.size() == size, "record mapping changed"); return record;
    };
    rz::verify_private_records(manifest, read, &reader, 4);
    manifest.entries.front().digest[0] ^= 1;
    rejects([&] { rz::verify_private_records(manifest, read, &reader, 4); }, "whole-file digest mismatch accepted");
}
void output_limits() {
    if (!rz::aes_available()) return;
    std::array<unsigned char, 64> master{}; rz::UUID uuid{};
    auto compressed = rz::compress_frame(rz::Bytes(32, 73));
    const auto offset = rz::MaxOutput + rz::MaxOutput / 100 + 1;
    rz::ArchiveKeys legacy(master.data(), rz::DualCryptoProfile);
    rejects([&] { (void)legacy.seal(uuid, rz::RecordKind::Content, offset, 32, compressed); }, "legacy encrypted stream limit removed");
    rz::ArchiveKeys paged(master.data(), rz::DualCryptoProfile, true, rz::MaxPagedOutput);
    rz::ArchiveKeys reader(master.data(), rz::DualCryptoProfile, false);
    auto record = paged.seal(uuid, rz::RecordKind::Content, offset, 32, compressed);
    require(reader.open(uuid, rz::RecordKind::Content, offset, 32, record) == compressed, "large-offset encrypted record cannot roundtrip");
    rejects([&] { (void)paged.seal(uuid, rz::RecordKind::Content, offset, 32, compressed); }, "large-offset nonce reuse accepted");
    rejects([&] { rz::ArchiveKeys invalid(master.data(), rz::DualCryptoProfile, true, UINT64_MAX); }, "overflowing encrypted stream limit accepted");
}
}
int main() {
    try {
        for (auto threads : {1U, 4U, 64U, 0U}) queues(0, threads);
        for (auto suite : {rz::CryptoProfile, rz::DualCryptoProfile}) {
            if (suite == rz::DualCryptoProfile && !rz::aes_available()) continue;
            for (auto threads : {1U, 4U}) queues(suite, threads);
        }
        failures(); cleanup(); verification(); output_limits();
        std::cout << "Ordered bounded decoding, both encryption suites, authentication, cancellation, cleanup and output limits passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
