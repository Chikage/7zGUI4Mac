#include "paged.hpp"
#include "compression_pool.hpp"
#include "read_progress.hpp"
#include <charconv>
#include <iostream>
#include <set>
#include <optional>
#include <stdexcept>

namespace {
void signal_handler(int signal) { rz::interrupted.store(signal, std::memory_order_relaxed); }
void usage() {
    std::cout << "rz 0.8.0 — recoverable single-file containers with protected paginated indexes\n"
        "  rz --capabilities\n"
        "  rz create INPUT_DIRECTORY OUTPUT.rz [OPTIONS]\n"
        "  rz create-selected OUTPUT.rz [OPTIONS] -- INPUT...\n"
        "  rz list ARCHIVE [--json] [--password-stdin]\n"
        "  rz verify ARCHIVE [--password-stdin] [--progress]\n"
        "  rz repair ARCHIVE NEW_OUTPUT.rz [--directory]\n"
        "  rz extract ARCHIVE NEW_OUTPUT_DIRECTORY [--password-stdin] [--no-attributes] [--json] [--progress]\n"
        "OPTIONS: --data-volumes K --recovery-volumes M (1 <= M <= K <= 100)\n"
        "         Exactly K+M equal-sized volumes; any M missing volumes are recoverable.\n"
        "         --encrypt --password-stdin (content, names and attributes encrypted)\n"
        "      OR --generate-key-file (creates sibling NAME.rzkey; defaults to dual encryption)\n"
        "         --encryption standard|dual (default standard; dual adds AES-256-GCM)\n"
        "         --no-metadata (omit file attributes; default preserves them)\n"
        "         --directory (create/repair: write legacy loose volumes instead of a container)\n"
        "         --progress (create/verify/extract; stderr)\n"
        "         --threads auto|N (1..64 workers per compression/recovery phase; each capped at 256 MiB)\n"
        "         --profile 5 (default; 10+2 volumes; paginated protected index; 1 TiB content limit)\n"
        "READ:    --key-file FILE | --auto-key-file (find matching sibling .rzkey by archive ID)\n"
        "ARCHIVE accepts a container file or a legacy volume directory.\n"
        "Encrypted archives can be repaired without a password.\n"
        "verify without a password checks ciphertext storage only.\n"
        "Exit: 0 success, 2 repairable, 3 unrecoverable, 4 password required/incorrect,\n"
        "      5 extracted with metadata warnings, 6 matching key file required; other errors: 1.\n";
}
uint32_t parse_count(const std::string& value, uint32_t maximum) {
    uint32_t count;
    const char* end = value.data() + value.size();
    const auto result = std::from_chars(value.data(), end, count);
    if (result.ec != std::errc{} || result.ptr != end || count < 1 || count > maximum)
        throw std::runtime_error("Expected an integer from 1 to " + std::to_string(maximum));
    return count;
}
struct CreateOptions {
    rz::RecoveryOptions recovery;
    uint32_t crypto_suite = rz::CryptoProfile;
    bool encrypt = false, metadata = true, metadata_explicit = false, password_stdin = false;
    bool progress = false, directory_output = false;
    bool generate_key_file = false;
    uint32_t threads = 0;
};
CreateOptions parse_options(int argc, char** argv, int& position) {
    CreateOptions out; std::set<std::string> seen;
    while (position < argc && std::string(argv[position]) != "--") {
        std::string flag = argv[position++];
        if (!seen.insert(flag).second) throw std::runtime_error("Duplicate option");
        if (flag == "--progress") { out.progress = true; continue; }
        if (flag == "--directory") { out.directory_output = true; continue; }
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
            if (value != "auto") out.threads = parse_count(value, rz::MaxCompressionThreads);
        } else if (flag == "--data-volumes") {
            out.recovery.data_volumes = parse_count(value, rz::MaxDataShards);
        } else if (flag == "--recovery-volumes") {
            out.recovery.recovery_volumes = parse_count(value, rz::MaxDataShards);
        } else if (flag == "--profile") {
            if (value != "5") throw std::runtime_error("Unsupported RZ profile (only profile 5 is supported)");
        } else throw std::runtime_error("Unknown option: " + flag);
    }
    if (seen.contains("--data-volumes") != seen.contains("--recovery-volumes"))
        throw std::runtime_error("Specify both --data-volumes and --recovery-volumes");
    rz::validate_volume_counts(out.recovery.data_volumes, out.recovery.recovery_volumes);
    if (out.generate_key_file && out.password_stdin) throw std::runtime_error("Choose a password OR a generated key file");
    if (out.generate_key_file && !seen.contains("--encryption")) out.crypto_suite = rz::DualCryptoProfile;
    if (seen.contains("--encryption") && !out.encrypt) throw std::runtime_error("Encryption suite requires --encrypt and --password-stdin");
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
void json_listing(const rz::ArchiveManifest& m) {
    const auto& options = m.options;
    std::cout << "{\"version\":1"
        << ",\"encrypted\":" << (m.security.encrypted ? "true" : "false")
        << ",\"locked\":" << (m.security.encrypted && !m.unlocked ? "true" : "false")
        << ",\"directoryUnavailable\":" << (m.directory_damaged ? "true" : "false")
        << ",\"preservesMetadata\":" << (m.security.metadata ? "true" : "false")
        << ",\"encryptionSuite\":" << (m.security.encrypted ? m.security.key_slot.suite : 0)
        << ",\"requiresKeyFile\":" << (m.security.key_slot.key_file ? "true" : "false")
        << ",\"recovery\":{\"profile\":" << rz::FormatVersion
        << ",\"dataBytes\":" << m.data_bytes_per_volume * options.data_volumes
        << ",\"payloadBytes\":" << m.data_bytes_per_volume * options.recovery_volumes
        << ",\"dataVolumes\":" << options.data_volumes << ",\"recoveryVolumes\":" << options.recovery_volumes
        << ",\"volumeLimitBytes\":0,\"requestedMode\":2,\"requestedValue\":0"
        << ",\"volumeSizeBytes\":" << m.metadata_bytes_per_volume + m.data_bytes_per_volume
        << ",\"toleratedVolumeLosses\":" << options.recovery_volumes
        << ",\"metadataBytesPerVolume\":" << m.metadata_bytes_per_volume
        << ",\"contentLimitBytes\":" << rz::MaxOutput << '}';
    std::cout << ",\"entries\":["; bool first = true;
    for (const auto& e : m.entries) {
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
    if (!options.auto_key_file) return std::nullopt;
    auto manifest = rz::list_paged_archive(archive);
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
        if ((command == "create" && argc >= 4) || (command == "create-selected" && argc >= 5)) {
            const bool selected = command == "create-selected";
            const char* output = selected ? argv[2] : argv[3];
            int i = selected ? 3 : 4;
            auto options = parse_options(argc, argv, i);
            rz::InputPlan plan;
            if (selected) {
                if (i == argc || std::string(argv[i++]) != "--" || i == argc) throw std::runtime_error("Expected -- INPUT...");
                std::vector<rz::fs::path> inputs(argv + i, argv + argc);
                plan = rz::selected_inputs(inputs, output);
            } else {
                if (i != argc) throw std::runtime_error("Unexpected positional argument");
                plan = rz::directory_inputs(argv[2], output);
            }
            std::optional<rz::Password> password;
            if (options.password_stdin) password.emplace(rz::read_password());
            if (options.generate_key_file) password.emplace(rz::generate_recovery_key());
            rz::SecurityOptions security{options.encrypt, options.metadata, password ? &*password : nullptr, options.crypto_suite, options.generate_key_file};
            rz::create_paged_archive(plan, output, options.recovery, security, options.progress, options.threads, options.directory_output);
            std::cout << "Created " << output << '\n';
        } else if (command == "list" && argc >= 3) {
            auto options = read_options(argc, argv, 3, true, false, true);
            auto password = read_credential(options, argv[2], false);
            auto m = rz::list_paged_archive(argv[2], password ? &*password : nullptr);
            if (options.json) json_listing(m);
            else {
                std::cout << "profile=" << rz::FormatVersion << " encrypted=" << m.security.encrypted << " locked=" << (m.security.encrypted && !m.unlocked)
                    << " encryption_suite=" << (m.security.encrypted ? m.security.key_slot.suite : 0)
                    << " directory_unavailable=" << m.directory_damaged
                    << " data_volumes=" << m.options.data_volumes << " recovery_volumes=" << m.options.recovery_volumes
                    << " volume_limit=0 recovery_payload=" << m.data_bytes_per_volume * m.options.recovery_volumes << '\n';
                for (const auto& e : m.entries) std::cout << (e.directory ? "dir " : "file ") << e.size << '\t' << e.path << '\n';
            }
        } else if (command == "verify" && argc >= 3) {
            auto options = read_options(argc, argv, 3, false, false, false, true);
            rz::ReadProgress reporter; auto progress = options.progress ? &reporter : nullptr;
            if (progress) progress->phase("preparing");
            auto password = read_credential(options, argv[2], true);
            auto result = rz::verify_paged_archive(argv[2], password ? &*password : nullptr, progress);
            if (progress && result.exit_code() == 0) progress->phase("completed");
            std::cout << "bad_blocks=" << result.bad_blocks << " bad_data_blocks=" << result.bad_data_blocks
                << " unrecoverable_stripes=" << result.unrecoverable_stripes << " metadata_issues=" << result.metadata_issues
                << " password_authentication=" << (options.password_stdin ? "requested" : "not_requested")
                << " key_file_authentication=" << (password && password->from_key_file ? "requested" : "not_requested") << '\n';
            return result.exit_code();
        } else if (command == "repair" && (argc == 4 || (argc == 5 && std::string(argv[4]) == "--directory"))) {
            rz::repair_paged_archive(argv[2], argv[3], argc == 5);
            std::cout << "Reconstructed and storage-checked " << argv[3] << "; encrypted content authentication requires its password or key file.\n";
        } else if (command == "extract" && argc >= 4) {
            auto options = read_options(argc, argv, 4, true, true, true, true);
            rz::ReadProgress reporter; auto progress = options.progress ? &reporter : nullptr;
            if (progress) progress->phase("preparing");
            auto password = read_credential(options, argv[2], true);
            auto report = rz::extract_paged_archive(argv[2], argv[3], password ? &*password : nullptr, options.attributes, progress);
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
