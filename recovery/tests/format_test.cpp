#include "binary.hpp"
#include <functional>
#include <iostream>
#include <random>
#include <stdexcept>

static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void rejects(const std::function<void()>& action) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Malformed entry index was accepted");
}
static rz::Bytes encode(const std::vector<rz::Entry>& entries) {
    rz::binary::Writer writer;
    rz::binary::write_entries(writer, entries);
    return writer.b;
}
static std::vector<rz::Entry> decode(const rz::Bytes& bytes) {
    rz::binary::Reader reader{bytes};
    auto entries = rz::binary::read_entries(reader, 0);
    reader.end();
    return entries;
}
int main() {
    try {
        rz::Entry entry; entry.path = "empty"; entry.digest = rz::hash(nullptr, 0);
        const auto valid = encode({entry});
        require(encode(decode(valid)) == valid, "Entry round-trip");
        for (size_t n = 0; n < valid.size(); ++n) {
            rz::Bytes cut(valid.begin(), valid.begin() + n);
            rejects([&] { (void)decode(cut); });
        }
        for (const std::string path : {"../escape", "/absolute", "a/../b", "a//b", "a/", "a\\b", "a:b", "a\nb", "a/./b", "absent/child"}) {
            auto bad = entry; bad.path = path;
            rejects([&] { (void)decode(encode({bad})); });
        }
        for (const std::string path : {std::string("x\0y", 3), std::string("\xc0\xaf", 2), std::string("\xed\xa0\x80", 3)})
            rejects([&] { rz::validate_path(path); });
        rejects([&] { (void)decode(encode({entry, entry})); });
        auto child = entry; child.path = "empty/child";
        rejects([&] { (void)decode(encode({entry, child})); });
        auto large = entry; large.size = rz::MaxOutput + 1;
        rejects([&] { (void)decode(encode({large})); });
        auto trailing = valid; trailing.push_back(0);
        rejects([&] { (void)decode(trailing); });
        std::mt19937 rng(1917);
        for (int i = 0; i < 5000; ++i) {
            auto bytes = valid;
            for (int j = 0; j < 1 + i % 5; ++j) bytes[rng() % bytes.size()] ^= static_cast<uint8_t>(rng());
            try { (void)decode(bytes); } catch (const std::runtime_error&) {}
        }
        std::cout << "Entry bounds, paths, truncations and 5000 mutations passed\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
