#pragma once
#include "io.hpp"
#include <chrono>
#include <iostream>
#include <map>

namespace rz {
// Optional CLI telemetry, independent of the archive format. No paths or
// passwords are emitted, including for encrypted archives.
class CompressionProgress {
public:
    CompressionProgress(const fs::path& root, const std::map<std::string, bool>& paths, bool enabled)
        : enabled_(enabled) {
        if (!enabled_) return;
        for (const auto& [path, directory] : paths) {
            check_cancel();
            if (!directory) { total_ += fs::file_size(root / path); ++files_; }
        }
    }
    void start() {
        start_ = Clock::now(); last_ = start_;
        emit("compressing");
    }
    void advance(uint64_t input, uint64_t output) {
        processed_ += input; packed_ += output;
        update();
    }
    void file_completed() { ++completed_; update(); }
    void phase(const char* name) { emit(name); }
    void finish_compression() { update(); }
    uint64_t compression_microseconds() const { return elapsed_us_; }
private:
    using Clock = std::chrono::steady_clock;
    bool enabled_;
    uint64_t total_ = 0, files_ = 0, processed_ = 0, packed_ = 0, completed_ = 0, elapsed_ = 0;
    uint64_t elapsed_us_ = 0;
    Clock::time_point start_ = Clock::now(), last_ = start_;
    void update() {
        auto now = Clock::now();
        elapsed_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now - start_).count());
        elapsed_ = elapsed_us_ / 1000;
        if (now - last_ >= std::chrono::milliseconds(200)) { emit("compressing"); last_ = now; }
    }
    void emit(const char* phase) {
        if (!enabled_) return;
        std::cerr << "RZPROGRESS1\t" << phase << '\t' << processed_ << '\t' << total_ << '\t'
            << completed_ << '\t' << files_ << '\t' << packed_ << '\t' << elapsed_ << '\n' << std::flush;
    }
};
}
