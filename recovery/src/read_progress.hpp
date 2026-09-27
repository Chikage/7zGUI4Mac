#pragma once
#include "format.hpp"
#include <chrono>
#include <iostream>
#include <mutex>

namespace rz {
// Optional, path-free CLI telemetry. A phase owns its byte/file totals;
// storage workers may advance concurrently, while phase changes happen after join.
class ReadProgress {
public:
    void start(const char* phase, uint64_t bytes, uint64_t files = 0) {
        std::lock_guard lock(mutex_);
        phase_ = phase; total_ = bytes; files_ = files; processed_ = completed_ = 0;
        start_ = last_ = Clock::now(); emit();
    }
    void contents(const char* phase, const std::vector<Entry>& entries) {
        uint64_t bytes = 0, files = 0;
        for (const auto& entry : entries) if (!entry.directory) { bytes += entry.size; ++files; }
        start(phase, bytes, files);
    }
    void advance(uint64_t bytes) {
        std::lock_guard lock(mutex_);
        const bool first = processed_ == 0;
        processed_ += bytes; update(first);
    }
    void file_completed() {
        std::lock_guard lock(mutex_); ++completed_; update(false);
    }
    void phase(const char* name) {
        std::lock_guard lock(mutex_); phase_ = name; emit();
    }
private:
    using Clock = std::chrono::steady_clock;
    std::mutex mutex_;
    const char* phase_ = "preparing";
    uint64_t total_ = 0, files_ = 0, processed_ = 0, completed_ = 0;
    Clock::time_point start_ = Clock::now(), last_ = start_;
    void update(bool force) {
        if (force || Clock::now() - last_ >= std::chrono::milliseconds(200)) emit();
    }
    void emit() {
        last_ = Clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(last_ - start_).count();
        std::cerr << "RZREADPROGRESS1\t" << phase_ << '\t' << processed_ << '\t' << total_ << '\t'
            << completed_ << '\t' << files_ << '\t' << elapsed << '\n' << std::flush;
    }
};
}
