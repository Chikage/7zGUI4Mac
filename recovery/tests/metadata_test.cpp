#include "metadata.hpp"
#include "io.hpp"
#include <sys/stat.h>
#include <unistd.h>
#include <iostream>

static void require(bool test, const char* what) { if (!test) throw std::runtime_error(what); }
int main() {
    try {
        auto root = rz::fs::temp_directory_path() / ("rz-metadata-" + rz::hex(rz::hash(rz::random_uuid().data(), 16)));
        rz::fs::create_directory(root);
        struct Cleanup { rz::fs::path root; ~Cleanup() { std::error_code ec; rz::fs::remove_all(root, ec); } } cleanup{root};
        auto source = root / "source", target = root / "target";
        { rz::File f(source, rz::File::Mode::New); f.append("data", 4); }
        { rz::File f(target, rz::File::Mode::New); f.append("data", 4); }
        auto metadata = rz::capture_metadata(source); rz::validate_metadata(metadata);
        // Restore mode 0000, then reset the unpublished file for cancellation cleanup.
        for (size_t i = 12; i < 16; ++i) metadata[i] = 0;
        rz::ExtractionReport report; rz::restore_metadata(target, "target", false, metadata, report);
        struct stat s{}; require(lstat(target.c_str(), &s) == 0 && (s.st_mode & 0777) == 0, "Mode 0000 not restored");
        rz::Entry entry; entry.path = "target";
        rz::reset_metadata_for_cleanup(root, {entry});
        require(lstat(target.c_str(), &s) == 0 && (s.st_mode & 0777) == 0600, "Cleanup could not reset permissions");
        for (size_t n = 0; n < metadata.size(); ++n) {
            bool rejected = false;
            try { rz::validate_metadata(rz::Bytes(metadata.begin(), metadata.begin() + n)); } catch (const std::runtime_error&) { rejected = true; }
            require(rejected, "Truncated metadata accepted");
        }
        std::cout << "Metadata validation, restrictive mode restoration and cleanup passed\n"; return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
