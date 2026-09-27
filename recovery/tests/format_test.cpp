#include "format.hpp"
#include <functional>
#include <iostream>
#include <random>
#include <stdexcept>

static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void rejects(const std::function<void()>& action) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Malformed metadata was accepted");
}
int main() {
    try {
        rz::Manifest m;
        rz::Group g; g.stripes = 1; g.hashes.resize(rz::N); m.groups.push_back(g);
        rz::Entry e; e.path = "empty"; e.digest = rz::hash(nullptr, 0); m.entries.push_back(e);
        auto valid = rz::serialize(m);
        require(rz::serialize(rz::parse_manifest(valid)) == valid, "Metadata round-trip");
        // Every truncation of a valid manifest must fail, even with a valid outer checksum.
        for (size_t n = 0; n < valid.size(); ++n) {
            rz::Bytes cut(valid.begin(), valid.begin() + n);
            rejects([&] { (void)rz::parse_manifest(cut); });
        }
        for (const std::string path : {"../escape", "/absolute", "a/../b", "a//b", "a/", "a\\b", "a:b", "a\nb", "a/./b"}) {
            auto bad = m; bad.entries[0].path = path;
            rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        }
        for (const std::string path : {std::string("x\0y", 3), std::string("\xc0\xaf", 2), std::string("\xed\xa0\x80", 3)})
            rejects([&] { rz::validate_path(path); });
        auto bad = m; bad.entries.push_back(e);
        rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        bad = m; bad.entries[0].path = "absent/child";
        rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        bad = m; e.path = "empty/child"; bad.entries.push_back(e);
        rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        bad = m; bad.entries[0].size = UINT64_MAX;
        rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        bad = m; bad.groups[0].valid = 1;
        rejects([&] { (void)rz::parse_manifest(rz::serialize(bad)); });
        auto huge_count = valid;
        for (int i = 52; i < 56; ++i) huge_count[i] = 255;
        rejects([&] { (void)rz::parse_manifest(huge_count); });
        auto trailing = valid; trailing.push_back(0);
        rejects([&] { (void)rz::parse_manifest(trailing); });
        std::mt19937 rng(1917);
        for (int i = 0; i < 5000; ++i) {
            auto bytes = valid;
            for (int j = 0; j < 1 + i % 5; ++j) bytes[rng() % bytes.size()] ^= static_cast<uint8_t>(rng());
            try { (void)rz::parse_manifest(bytes); } catch (const std::runtime_error&) {}
        }
        rz::Header h{m.uuid, 0, 0, valid.size(), rz::BlockSize, rz::hash(valid)};
        for (bool footer : {false, true}) {
            auto bytes = rz::make_header(h, footer);
            require(rz::parse_header(bytes, footer).manifest_hash == h.manifest_hash, "Header round-trip");
            for (size_t i = 0; i < bytes.size(); ++i) {
                auto changed = bytes; changed[i] ^= 1;
                rejects([&] { (void)rz::parse_header(changed, footer); });
            }
        }
        std::cout << "Metadata bounds, traversal, duplicate paths, all truncations, header bit flips, 5000 mutations passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
