#include "archive.hpp"
#include "configurable.hpp"
#include "io.hpp"
#include "compression_pool.hpp"
#include "protected.hpp"
#include "read_progress.hpp"
#include <iostream>
#include <set>
#include <optional>
#include <stdexcept>

namespace {
void signal_handler(int signal) { rz::interrupted.store(signal, std::memory_order_relaxed); }
void usage() {
    std::cout << "rz 0.7.0 — recoverable volumes with protected paginated indexes\n"
        "  rz --capabilities\n"
        "  rz create INPUT_DIRECTORY OUTPUT_SET [OPTIONS]\n"
        "  rz create-selected OUTPUT_SET [OPTIONS] -- INPUT...\n"
        "  rz list SET_DIRECTORY [--json] [--password-stdin]\n"
        "  rz verify SET_DIRECTORY [--password-stdin] [--progress]\n"
        "  rz repair SET_DIRECTORY NEW_SET_DIRECTORY\n"
        "  rz extract SET_DIRECTORY NEW_OUTPUT_DIRECTORY [--password-stdin] [--no-attributes] [--json] [--progress]\n"
        "OPTIONS: --data-volumes K --recovery-volumes M (profile 4 or 5; 1 <= M <= K <= 100)\n"
        "         Exactly K+M equal-sized volumes; any M missing volumes are recoverable.\n"
        "LEGACY:  --volume-size 64MiB (1MiB..16GiB, decimal sizes accepted)\n"
        "         --recovery-percent 20 (1..100, up to 2 decimal places)\n"
        "      OR --recovery-bytes 500MiB (64KiB rounding; 1 block/group minimum; up to 100%)\n"
        "         --encrypt --password-stdin (content, names and attributes encrypted)\n"
        "      OR --generate-key-file (creates sibling NAME.rzkey; defaults to dual encryption)\n"
        "READ:    --key-file FILE | --auto-key-file (find matching sibling .rzkey by archive ID)\n"
        "         --encryption standard|dual (default standard; dual adds AES-256-GCM)\n"
        "         --no-metadata (omit file attributes; default preserves them)\n"
        "         --progress (create: profile 2/3/4/5; verify/extract: all profiles; stderr)\n"
        "         --threads auto|N (1..64 workers per compression/recovery phase; each capped at 256 MiB)\n"
        "         --profile 5 (10+2 default; paginated protected index; 1 TiB content limit)\n"
        "         --profile 4 (10+2 default); --profile 1|2|3 for legacy layout\n"
        "CLI defaults remain profile 3 without counts and profile 4 with counts.\n"
        "Encrypted sets can be repaired without a password.\n"
        "verify without a password checks ciphertext storage only.\n"
        "Exit: 0 success, 2 repairable, 3 unrecoverable, 4 password required/incorrect,\n"
        "      5 extracted with metadata warnings, 6 matching key file required; other errors: 1.\n";
}
uint64_t scaled_decimal(const std::string& text, uint64_t scale, unsigned precision, uint64_t maximum) {
    if (text.empty() || text.size() > 24 || text.find_first_not_of("0123456789.") != std::string::npos)
        throw std::runtime_error("Invalid numeric value");
    auto point = text.find('.'); auto whole = text.substr(0, point);
    auto fraction = point == std::string::npos ? std::string() : text.substr(point + 1);
    if (whole.empty() || fraction.size() > precision || (point != std::string::npos && fraction.empty()) || fraction.find('.') != std::string::npos)
        throw std::runtime_error("Invalid numeric precision");
    uint64_t n = std::stoull(whole), f = fraction.empty() ? 0 : std::stoull(fraction), divisor = 1;
    for (size_t i = 0; i < fraction.size(); ++i) divisor *= 10;
    if (n > maximum / scale) throw std::runtime_error("Numeric value exceeds supported limit");
    auto value = n * scale + f * scale / divisor;
    if (value > maximum) throw std::runtime_error("Numeric value exceeds supported limit");
    return value;
}
uint64_t parse_size(std::string value) {
    uint64_t scale = 1;
    for (const auto& [suffix, multiplier] : {std::pair<std::string, uint64_t>{"KiB", 1024}, {"MiB", 1024 * 1024}, {"GiB", 1024ULL * 1024 * 1024}, {"B", 1}}) {
        if (value.size() > suffix.size() && value.ends_with(suffix)) {
            scale = multiplier; value.resize(value.size() - suffix.size()); break;
        }
    }
    return scaled_decimal(value, scale, 3, rz::MaxOutput);
}
struct CreateOptions {
    rz::RecoveryOptions recovery;
    uint32_t profile = 3;
    uint32_t crypto_suite = rz::CryptoProfile;
    bool custom_recovery = false, encrypt = false, metadata = true, metadata_explicit = false, password_stdin = false;
    bool progress = false;
    bool generate_key_file = false;
    uint32_t threads = 0;
};
CreateOptions parse_options(int argc, char** argv, int& position) {
    CreateOptions out; std::set<std::string> seen;
    while (position < argc && std::string(argv[position]) != "--") {
        std::string flag = argv[position++];
        if (!seen.insert(flag).second) throw std::runtime_error("Duplicate option");
        if (flag == "--progress") { out.progress = true; continue; }
        if (flag == "--encrypt") { out.encrypt = true; continue; }
        if (flag == "--generate-key-file") { out.generate_key_file = true; out.encrypt = true; continue; }
        if (flag == "--password-stdin") { out.password_stdin = true; continue; }
        if (flag == "--metadata" || flag == "--no-metadata") {
            if (out.metadata_explicit) throw std::runtime_error("Conflicting metadata options");
            out.metadata_explicit = true; out.metadata = flag == "--metadata"; continue;
        }
        if (position == argc) throw std::runtime_error("Missing option value");
        std::string value = argv[position++];
        if (flag == "--encryption") {
            if (value != "standard" && value != "dual") throw std::runtime_error("Unknown encryption suite");
            out.crypto_suite = value == "dual" ? rz::DualCryptoProfile : rz::CryptoProfile;
        } else if (flag == "--threads") {
            if (value != "auto") {
                auto count = scaled_decimal(value, 1, 0, rz::MaxCompressionThreads);
                if (!count) throw std::runtime_error("Compression threads must be auto or 1..64");
                out.threads = static_cast<uint32_t>(count);
            }
        } else if (flag == "--volume-size") out.recovery.volume_size = parse_size(value);
        else if (flag == "--data-volumes" || flag == "--recovery-volumes") {
            auto count = static_cast<uint32_t>(scaled_decimal(value, 1, 0, rz::MaxDataShards));
            if (flag == "--data-volumes") out.recovery.data_volumes = count;
            else out.recovery.recovery_volumes = count;
        }
        else if (flag == "--profile") {
            if (value != "1" && value != "2" && value != "3" && value != "4" && value != "5") throw std::runtime_error("Unknown profile");
            out.profile = static_cast<uint32_t>(value[0] - '0');
        } else if (flag == "--recovery-percent" || flag == "--recovery-bytes") {
            if (out.custom_recovery) throw std::runtime_error("Choose recovery percent OR recovery bytes");
            out.custom_recovery = true;
            out.recovery.mode = flag == "--recovery-percent" ? rz::RecoveryMode::Percent : rz::RecoveryMode::Bytes;
            out.recovery.value = flag == "--recovery-percent" ? scaled_decimal(value, 100, 2, 10000) : parse_size(value);
        } else throw std::runtime_error("Unknown option: " + flag);
    }
    if (seen.contains("--data-volumes") != seen.contains("--recovery-volumes"))
        throw std::runtime_error("Specify both --data-volumes and --recovery-volumes");
    if (seen.contains("--data-volumes")) {
        if (seen.contains("--profile") && out.profile != 4 && out.profile != 5)
            throw std::runtime_error("Volume counts require profile 4 or 5");
        if (!seen.contains("--profile")) out.profile = 4;
    }
    if (out.profile == 4 || out.profile == 5) {
        if (seen.contains("--volume-size") || out.custom_recovery)
            throw std::runtime_error("Volume counts cannot be combined with size or recovery budget");
        out.recovery.mode = rz::RecoveryMode::Volumes; out.recovery.value = 0; out.recovery.volume_size = 0;
    }
    out.recovery.profile = out.profile;
    rz::validate_options(out.recovery);
    if (out.generate_key_file && out.password_stdin) throw std::runtime_error("Choose a password OR a generated key file");
    if (out.generate_key_file && !seen.contains("--encryption")) out.crypto_suite = rz::DualCryptoProfile;
    if (seen.contains("--encryption") && !out.encrypt) throw std::runtime_error("Encryption suite requires --encrypt and --password-stdin");
    if (out.progress && out.profile == 1) throw std::runtime_error("Progress requires profile 2, 3, 4 or 5");
    if (out.profile == 1 && (out.custom_recovery || out.recovery.volume_size > rz::MaxVolume))
        throw std::runtime_error("Legacy profile requires fixed recovery and volume size up to 1 GiB");
    if (out.profile < 3 && (out.encrypt || out.password_stdin || (out.metadata_explicit && out.metadata)))
        throw std::runtime_error("Encryption and file metadata require profile 3, 4 or 5");
    if (out.encrypt != (out.password_stdin || out.generate_key_file)) throw std::runtime_error("Use --encrypt with --password-stdin; never place passwords in arguments");
    return out;
}
void json_string(const std::string& text) {
    std::cout << '"';
    constexpr char digits[] = "0123456789abcdef";
    for (unsigned char c : text) {
        if (c < 32) { std::cout << "\\u00" << digits[c >> 4] << digits[c & 15]; continue; }
        if (c == '"' || c == '\\') std::cout << '\\';
        std::cout << c;
    }
    std::cout << '"';
}
void json_listing(const std::vector<rz::Entry>& entries, const rz::ConfigurableManifest* m = nullptr) {
    std::cout << "{\"version\":1";
    std::cout << ",\"encrypted\":" << (m && m->security.encrypted ? "true" : "false")
        << ",\"locked\":" << (m && m->security.encrypted && !m->unlocked ? "true" : "false")
        << ",\"directoryUnavailable\":" << (m && m->directory_damaged ? "true" : "false")
        << ",\"preservesMetadata\":" << (m && m->security.metadata ? "true" : "false");
    std::cout << ",\"encryptionSuite\":" << (m && m->security.encrypted ? m->security.key_slot.suite : 0);
    std::cout << ",\"requiresKeyFile\":" << (m && m->security.key_slot.key_file ? "true" : "false");
    if (m) {
        std::cout << ",\"recovery\":{\"profile\":" << m->profile << ",\"dataBytes\":" << m->data_blocks * rz::BlockSize
            << ",\"payloadBytes\":" << m->recovery_blocks * rz::BlockSize << ",\"volumeLimitBytes\":" << m->options.volume_size
            << ",\"dataVolumes\":" << m->volume_count(false) << ",\"recoveryVolumes\":" << m->volume_count(true)
            << ",\"requestedMode\":" << static_cast<uint32_t>(m->options.mode) << ",\"requestedValue\":" << m->options.value;
        if (m->profile == 4 || m->profile == 5) {
            auto metadata_size = m->profile == 5 ? m->metadata_bytes_per_volume : 2 * rz::HeaderSize + 2 * rz::serialize(*m).size();
            std::cout << ",\"volumeSizeBytes\":" << metadata_size + m->payload_size(false, 0)
                << ",\"toleratedVolumeLosses\":" << m->options.recovery_volumes;
            if (m->profile == 5)
                std::cout << ",\"metadataBytesPerVolume\":" << metadata_size
                    << ",\"contentLimitBytes\":" << m->content_limit;
        }
        std::cout << '}';
    }
    std::cout << ",\"entries\":["; bool first = true;
    for (const auto& e : entries) {
        if (!first) std::cout << ',';
        first = false;
        std::cout << "{\"path\":"; json_string(e.path);
        std::cout << ",\"size\":" << e.size << ",\"isDirectory\":" << (e.directory ? "true" : "false") << '}';
    }
    std::cout << "]}\n";
}
struct ReadOptions { bool progress = false, json = false, password_stdin = false, attributes = true, auto_key_file = false; rz::fs::path key_file; };
ReadOptions read_options(int argc, char** argv, int start, bool allow_json, bool allow_attributes, bool automatic = false, bool allow_progress = false) {
    ReadOptions result; std::set<std::string> seen;
    result.auto_key_file = automatic;
    for (int i = start; i < argc; ++i) {
        std::string flag = argv[i];
        if (!seen.insert(flag).second) throw std::runtime_error("Duplicate option");
        if (flag == "--progress" && allow_progress) result.progress = true;
        else if (flag == "--json" && allow_json) result.json = true;
        else if (flag == "--password-stdin") result.password_stdin = true;
        else if (flag == "--auto-key-file") result.auto_key_file = true;
        else if (flag == "--no-auto-key-file") result.auto_key_file = false;
        else if (flag == "--key-file" && i + 1 < argc) result.key_file = argv[++i];
        else if (flag == "--no-attributes" && allow_attributes) result.attributes = false;
        else throw std::runtime_error("Unknown option: " + flag);
    }
    if (int(result.password_stdin) + int(seen.contains("--auto-key-file")) + int(!result.key_file.empty()) > 1 ||
        (seen.contains("--auto-key-file") && seen.contains("--no-auto-key-file")))
        throw std::runtime_error("Choose exactly one credential source");
    if (result.password_stdin || !result.key_file.empty()) result.auto_key_file = false;
    return result;
}
std::optional<rz::Password> read_credential(const ReadOptions& options, const rz::fs::path& archive, bool require_authentication) {
    if (options.password_stdin) return rz::read_password();
    if (!options.key_file.empty()) return rz::read_key_file(options.key_file);
    if (!options.auto_key_file || !rz::uses_configurable_profile(archive)) return std::nullopt;
    auto manifest = rz::list_configurable_archive(archive);
    if (!manifest.security.key_slot.key_file) return std::nullopt;
    if (manifest.security.key_slot.suite == rz::DualCryptoProfile && !rz::aes_available() && !require_authentication)
        return std::nullopt;
    auto try_key = [&](const rz::fs::path& file) -> std::optional<rz::Password> {
        try {
            auto key = rz::read_key_file(file);
            if (key.archive_uuid != manifest.uuid) return std::nullopt;
            (void)rz::authenticate_manifest(manifest, &key);
            return key;
        } catch (const rz::KeyFileError&) { return std::nullopt; }
    };
    auto archive_path = rz::fs::canonical(archive);
    auto preferred = archive_path; preferred.replace_extension(".rzkey");
    if (auto key = try_key(preferred)) return key;
    size_t candidates = 0, inspected = 0;
    // Filename changes and repaired copies retain UUID, so only the UUID is used
    // as identity. Keys are read through O_NOFOLLOW and never printed or copied.
    for (const auto& entry : rz::fs::directory_iterator(archive_path.parent_path())) {
        rz::check_cancel();
        if (++inspected > 65536) break;
        auto extension = entry.path().extension().string();
        for (auto& c : extension) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (entry.path() == preferred || extension != ".rzkey") continue;
        if (++candidates > 512) break;
        if (auto key = try_key(entry.path())) return key;
    }
    if (require_authentication) throw rz::KeyFileError();
    return std::nullopt;
}
}
int main(int argc, char** argv) {
    std::signal(SIGINT, signal_handler); std::signal(SIGTERM, signal_handler);
    try {
        if (argc == 2 && std::string(argv[1]) == "--help") { usage(); return 0; }
        if (argc == 2 && std::string(argv[1]) == "--capabilities") {
            std::cout << "{\"version\":1,\"aes256gcm\":" << (rz::aes_available() ? "true" : "false") << "}\n"; return 0;
        }
        if (argc < 3) { usage(); return 1; }
        std::string command = argv[1];
        if (command == "create" && argc >= 4) {
            int i = 4; auto options = parse_options(argc, argv, i);
            if (i != argc) throw std::runtime_error("Unexpected positional argument");
            std::optional<rz::Password> password; if (options.password_stdin) password.emplace(rz::read_password());
            if (options.generate_key_file) password.emplace(rz::generate_recovery_key());
            rz::SecurityOptions security{options.encrypt, options.metadata, password ? &*password : nullptr, options.crypto_suite, options.generate_key_file};
            if (options.profile == 1) rz::create_archive(argv[2], argv[3], options.recovery.volume_size, options.threads);
            else rz::create_configurable_archive(rz::directory_inputs(argv[2], argv[3]), argv[3], options.recovery, options.profile >= 3 ? &security : nullptr, options.progress, options.threads);
            std::cout << "Created " << argv[3] << '\n';
        } else if (command == "create-selected" && argc >= 5) {
            int i = 3; auto options = parse_options(argc, argv, i);
            if (i == argc || std::string(argv[i++]) != "--" || i == argc) throw std::runtime_error("Expected -- INPUT...");
            std::vector<rz::fs::path> inputs;
            for (; i < argc; ++i) inputs.emplace_back(argv[i]);
            std::optional<rz::Password> password; if (options.password_stdin) password.emplace(rz::read_password());
            if (options.generate_key_file) password.emplace(rz::generate_recovery_key());
            rz::SecurityOptions security{options.encrypt, options.metadata, password ? &*password : nullptr, options.crypto_suite, options.generate_key_file};
            if (options.profile == 1) rz::create_selected_archive(inputs, argv[2], options.recovery.volume_size, options.threads);
            else rz::create_configurable_archive(rz::selected_inputs(inputs, argv[2]), argv[2], options.recovery, options.profile >= 3 ? &security : nullptr, options.progress, options.threads);
            std::cout << "Created " << argv[2] << '\n';
        } else if (command == "list" && argc >= 3) {
            auto options = read_options(argc, argv, 3, true, false, true);
            auto password = read_credential(options, argv[2], false);
            if (rz::uses_configurable_profile(argv[2])) {
                auto m = rz::list_configurable_archive(argv[2], password ? &*password : nullptr);
                if (options.json) json_listing(m.entries, &m);
                else {
                    std::cout << "profile=" << m.profile << " encrypted=" << m.security.encrypted << " locked=" << (m.security.encrypted && !m.unlocked)
                        << " encryption_suite=" << (m.security.encrypted ? m.security.key_slot.suite : 0)
                        << " directory_unavailable=" << m.directory_damaged
                        << " data_volumes=" << m.volume_count(false) << " recovery_volumes=" << m.volume_count(true)
                        << " volume_limit=" << m.options.volume_size << " recovery_payload=" << m.recovery_blocks * rz::BlockSize << '\n';
                    for (const auto& e : m.entries) std::cout << (e.directory ? "dir " : "file ") << e.size << '\t' << e.path << '\n';
                }
            } else {
                auto m = rz::list_archive(argv[2]);
                if (options.json) json_listing(m.entries);
                else {
                    std::cout << "profile=1 rs=10+2 block=65536 frame=4194304 groups=" << m.groups.size() << '\n';
                    for (const auto& e : m.entries) std::cout << (e.directory ? "dir " : "file ") << e.size << '\t' << e.path << '\n';
                }
            }
        } else if (command == "verify" && argc >= 3) {
            auto options = read_options(argc, argv, 3, false, false, false, true);
            rz::ReadProgress reporter; auto progress = options.progress ? &reporter : nullptr;
            if (progress) progress->phase("preparing");
            auto password = read_credential(options, argv[2], true);
            auto result = rz::uses_configurable_profile(argv[2]) ? rz::verify_configurable_archive(argv[2], password ? &*password : nullptr, progress) : rz::verify_archive(argv[2], progress);
            if (progress && result.exit_code() == 0) progress->phase("completed");
            std::cout << "bad_blocks=" << result.bad_blocks << " bad_data_blocks=" << result.bad_data_blocks
                << " unrecoverable_stripes=" << result.unrecoverable_stripes << " metadata_issues=" << result.metadata_issues
                << " password_authentication=" << (options.password_stdin ? "requested" : "not_requested")
                << " key_file_authentication=" << (password && password->from_key_file ? "requested" : "not_requested") << '\n';
            return result.exit_code();
        } else if (command == "repair" && argc == 4) {
            if (rz::uses_configurable_profile(argv[2])) rz::repair_configurable_archive(argv[2], argv[3]);
            else rz::repair_archive(argv[2], argv[3]);
            std::cout << "Reconstructed and storage-checked " << argv[3] << "; encrypted content authentication requires its password or key file.\n";
        } else if (command == "extract" && argc >= 4) {
            auto options = read_options(argc, argv, 4, true, true, true, true);
            rz::ReadProgress reporter; auto progress = options.progress ? &reporter : nullptr;
            if (progress) progress->phase("preparing");
            auto password = read_credential(options, argv[2], true);
            rz::ExtractionReport report;
            if (rz::uses_configurable_profile(argv[2])) report = rz::extract_configurable_archive(argv[2], argv[3], password ? &*password : nullptr, options.attributes, progress);
            else rz::extract_archive(argv[2], argv[3], progress);
            if (progress) progress->phase("completed");
            if (options.json) {
                std::cout << "{\"outputPublished\":true,\"warningCount\":" << report.warning_count << ",\"metadataWarnings\":[";
                for (size_t i = 0; i < report.warnings.size(); ++i) { if (i) std::cout << ','; json_string(report.warnings[i]); }
                std::cout << "]}\n";
            } else {
                std::cout << "Extracted and verified " << argv[3] << '\n';
                if (report.warning_count) {
                    std::cerr << "Metadata warnings: " << report.warning_count << '\n';
                    for (const auto& warning : report.warnings) std::cerr << warning << '\n';
                }
            }
            if (report.warning_count) return 5;
        } else { usage(); return 1; }
        return 0;
    } catch (const rz::KeyFileError& e) { std::cerr << "rz: " << e.what() << '\n'; return 6; }
    catch (const rz::PasswordError& e) { std::cerr << "rz: " << e.what() << '\n'; return 4; }
    catch (const std::exception& e) { std::cerr << "rz: " << e.what() << '\n'; return 1; }
}
