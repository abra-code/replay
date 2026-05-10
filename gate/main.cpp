//
//  main.cpp
//  gate
//
//  Incremental task execution tool.
//  Wraps a command with input/output fingerprinting to skip unchanged work.
//

#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <unordered_set>
#include <algorithm>
#include <ctime>
#include <cstdio>

#include <getopt.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdlib.h>

#include "fingerprint.h"
#include "env_var_expand.h"
#include "gate_cache.h"
#include "FileHelpers.h"
#include "GlobOverlap.h"
#include "blake3.h"
#include "replay_version.h"
#include "SandboxProfile.h"


// Globals required by fingerprint.cpp (declared extern there)
FileHashAlgorithm g_hash = FileHashAlgorithm::CRC32C;
XattrMode g_xattr_mode = XattrMode::On;
bool g_verbose = false;
double g_traversal_time = 0.0;

extern char **environ;

static void print_usage(std::ostream& stream)
{
    stream << "\n";
    stream << "Usage: gate [OPTIONS] -- COMMAND [ARGS...]\n";
    stream << "Execute COMMAND only if inputs have changed or outputs are missing.\n";
    stream << "\n";
    stream << "OPTIONS:\n";
    stream << "  -i, --input=PATH       Input file (repeatable, supports ${VAR}/$(VAR))\n";
    stream << "  -o, --output=PATH      Output file (repeatable, supports ${VAR}/$(VAR))\n";
    stream << "  -I, --input-list=FILE  Read input paths from FILE (repeatable)\n";
    stream << "                         Supports Xcode .xcfilelist with ${VAR}/$(VAR)\n";
    stream << "  -O, --output-list=FILE Read output paths from FILE (repeatable)\n";
    stream << "                         Supports Xcode .xcfilelist with ${VAR}/$(VAR)\n";
    stream << "  -e, --exclude-input=PATH  Exclude PATH from inputs (repeatable, CLI only, supports ${VAR}/$(VAR))\n";
    stream << "                         Three accepted shapes (relative paths resolve against the current directory):\n";
    stream << "                           - literal file or dir   : exact match or whole subtree pruned\n";
    stream << "                           - glob with '/'         : matched against absolute file paths\n";
    stream << "                           - glob without '/'      : gitignore-style, matches basename at any depth\n";
    stream << "                         Excludes contribute to the task signature. A warning is printed if an\n";
    stream << "                         exclude does not fall under any input root.\n";
    stream << "  -E, --env-list=FILE    Fingerprint env vars listed in FILE (repeatable)\n";
    stream << "                         Each line is expanded (${VAR}/$(VAR)) and the\n";
    stream << "                         result is included in the input fingerprint.\n";
    stream << "  -S, --signature-key=STR  Additional string for task signature (repeatable)\n";
    stream << "                         Use to distinguish build configurations, e.g.\n";
    stream << "                         -S \"${CONFIGURATION}\" -S \"${ARCHS}\"\n";
    stream << "  -c, --cache-dir=DIR    Cache directory (default: .gate-cache)\n";
    stream << "  -C, --cache-format=FMT Cache format: plist (default) or json\n";
    stream << "  -H, --hash=ALGO       Hash algorithm: crc32c (default) or blake3\n";
    stream << "  -f, --force            Force execution, ignore cache (still update cache after)\n";
    stream << "  --dry-run              Report hit/miss without executing\n";
    stream << "  --sandbox             Enable hard sandbox. Use --allow-read, --allow-write, --sandbox-profile\n";
    stream << "                         for additional paths. The wrapped command (after --) must use an\n";
    stream << "                         absolute path (e.g. /usr/bin/clang), not a bare name — $PATH lookup\n";
    stream << "                         happens after the sandbox is active. Violations return EPERM to\n";
    stream << "                         the caller; to discover path requirements, use\n";
    stream << "                         sandbox/sandbox-discover.py. To stream violations in real time run:\n";
    stream << "                           log stream --style compact --predicate 'subsystem == \"com.apple.sandbox\" || sender == \"Sandbox\"'\n";
    stream << "  --sandbox-profile=FILE  JSON sandbox spec; merged with --allow-read/--allow-write.\n";
    stream << "                         Implicitly enables --sandbox.\n";
    stream << "  --allow-read=PATH      Allow read-only access to PATH (repeatable). Implicitly enables --sandbox.\n";
    stream << "  --allow-write=PATH     Allow read+write access to PATH (repeatable). Implicitly enables --sandbox.\n";
    stream << "  --deny-network         With sandbox active, deny outbound network (allowed by default).\n";
    stream << "  -v, --verbose          Verbose output\n";
    stream << "  -h, --help             Print this help message\n";
    stream << "  -V, --version          Display version\n";
    stream << "\n";
    stream << "Exit codes:\n";
    stream << "  0        Cache hit (skipped) or command succeeded\n";
    stream << "  non-zero Command's exit code on failure\n";
    stream << "  2        Gate error (bad arguments, missing inputs, etc.)\n";
    stream << "\n";
    stream << "Sandbox profile JSON schema (--sandbox-profile=FILE):\n";
    stream << "\n";
    stream << "  All fields are optional. Defaults shown.\n";
    stream << "\n";
    stream << "  {\n";
    stream << "    \"import_baseline\": true,        // include bsd.sb (covers dyld, /tmp reads, Mach IPC)\n";
    stream << "    \"read_only\":  [\"/path\", ...],   // recursive file-read* access\n";
    stream << "    \"read_write\": [\"/path\", ...],   // recursive file-read* + file-write* access\n";
    stream << "    \"allow_network\": true,           // set false to deny all network connections\n";
    stream << "    \"allow_exec\":    true,           // set false to deny process-exec*\n";
    stream << "    \"allow_fork\":    true,           // set false to deny process-fork\n";
    stream << "    \"extra_rules\": [\"(allow ...)\"]  // raw SBPL rules appended verbatim\n";
    stream << "  }\n";
    stream << "\n";
    stream << "  System binaries (/bin, /usr/bin) do not need an explicit read_only entry;\n";
    stream << "  process-exec* covers launching them and bsd.sb covers their system dylibs.\n";
    stream << "  Third-party tools (Homebrew, Python frameworks) need their prefix in read_only\n";
    stream << "  because dyld must open their framework or library files at startup.\n";
    stream << "\n";
}

// Build a single command string from argv for display and cache key
static std::string build_command_string(char* const* argv, int count)
{
    std::string cmd;
    for (int i = 0; i < count; ++i)
    {
        if (i > 0) cmd += ' ';
        cmd += argv[i];
    }
    return cmd;
}

// Execute a command via posix_spawn. Returns the exit code.
static int execute_command(char* const* argv)
{
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], nullptr, nullptr, argv, environ);
    if (status != 0)
    {
        std::cerr << "error: posix_spawn failed: " << strerror(status) << '\n';
        return 2;
    }

    if (waitpid(pid, &status, 0) == -1)
    {
        std::cerr << "error: waitpid failed\n";
        return 2;
    }

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);

    return 2;
}

// Get current timestamp as ISO string
static std::string current_timestamp()
{
    time_t now = time(nullptr);
    struct tm tm;
    localtime_r(&now, &tm);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tm);
    return std::string(buf);
}

// Fingerprint a list of files using the fingerprint class infrastructure.
// Handles find_and_process_globbed_paths -> wait -> sort_and_compute -> reset cycle.
// Optional excludes filter out files/dirs matching literal absolute paths or globs.
static uint64_t fingerprint_files(const std::vector<std::string>& paths,
                                  const std::vector<std::string>& excludes = {})
{
    if (paths.empty()) return 0;

    std::unordered_set<std::string> path_set(paths.begin(), paths.end());
    std::unordered_set<std::string> exclude_set(excludes.begin(), excludes.end());

    int result = fingerprint::find_and_process_globbed_paths(path_set, exclude_set);
    if (result != EXIT_SUCCESS)
    {
        fingerprint::reset();
        return 0;
    }

    fingerprint::wait_for_all_tasks();

    result = fingerprint::get_result();
    if (result != EXIT_SUCCESS)
    {
        fingerprint::reset();
        return 0;
    }

    uint64_t fp = fingerprint::sort_and_compute_fingerprint(FingerprintOptions::HashRelativePaths);
    fingerprint::reset();
    return fp;
}

// Combine a file fingerprint with env text hash into a single fingerprint.
// If env_text is empty, returns file_fp unchanged.
static uint64_t combine_with_env(uint64_t file_fp, const std::string& env_text)
{
    if (env_text.empty()) return file_fp;

    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, &file_fp, sizeof(file_fp));
    blake3_hasher_update(&hasher, env_text.data(), env_text.size());

    uint64_t combined = 0;
    blake3_hasher_finalize(&hasher, (uint8_t*)&combined, sizeof(combined));
    return combined;
}

// Read env list files and expand all variables, returning concatenated text.
static std::string build_env_text(const std::vector<std::string>& env_list_files)
{
    if (env_list_files.empty()) return {};

    std::string result;
    for (const auto& env_file : env_list_files)
    {
        std::ifstream file(env_file);
        if (!file.is_open())
        {
            std::cerr << "error: cannot open env-list file: " << env_file << '\n';
            continue;
        }

        std::string line;
        while (std::getline(file, line))
        {
            if (line.empty() || line[0] == '#')
                continue;
            result += expand_env_variables(line);
            result += '\n';
        }
    }
    return result;
}

int main(int argc, char* argv[])
{
    // Long-only sandbox option codes; pick values >= 256 to avoid collision
    // with the short option letters.
    enum {
        kOptSandbox = 256,
        kOptSandboxProfile,
        kOptAllowRead,
        kOptAllowWrite,
        kOptDenyNetwork,
    };

    static const struct option long_options[] = {
        { "input",          required_argument, nullptr, 'i' },
        { "output",         required_argument, nullptr, 'o' },
        { "input-list",     required_argument, nullptr, 'I' },
        { "output-list",    required_argument, nullptr, 'O' },
        { "exclude-input",  required_argument, nullptr, 'e' },
        { "env-list",       required_argument, nullptr, 'E' },
        { "signature-key",  required_argument, nullptr, 'S' },
        { "cache-dir",      required_argument, nullptr, 'c' },
        { "cache-format",   required_argument, nullptr, 'C' },
        { "hash",           required_argument, nullptr, 'H' },
        { "force",          no_argument,       nullptr, 'f' },
        { "dry-run",        no_argument,       nullptr, 'd' },
        { "sandbox",                no_argument,       nullptr, kOptSandbox },
        { "sandbox-profile",        required_argument, nullptr, kOptSandboxProfile },
        { "allow-read",             required_argument, nullptr, kOptAllowRead },
        { "allow-write",            required_argument, nullptr, kOptAllowWrite },
        { "deny-network",           no_argument,       nullptr, kOptDenyNetwork },
        { "verbose",        no_argument,       nullptr, 'v' },
        { "help",           no_argument,       nullptr, 'h' },
        { "version",        no_argument,       nullptr, 'V' },
        { nullptr, 0, nullptr, 0 }
    };

    std::vector<std::string> inputs;
    std::vector<std::string> outputs;
    std::vector<std::string> exclude_inputs;
    std::vector<std::string> env_list_files;
    std::vector<std::string> signature_keys;
    std::string cache_dir = ".gate-cache";
    std::string cache_format_str = "plist";
    std::string hash_type = "crc32c";
    bool force = false;
    bool dry_run = false;

    bool sandbox_requested = false;
    std::string sandbox_profile_path;
    std::vector<std::string> sandbox_allow_read;
    std::vector<std::string> sandbox_allow_write;
    bool sandbox_deny_network = false;

    int opt;
    while ((opt = getopt_long(argc, argv, "i:o:I:O:e:E:S:c:C:H:fvhV", long_options, nullptr)) != -1)
    {
        switch (opt)
        {
            case 'i': inputs.push_back(expand_env_variables(optarg)); break;
            case 'o': outputs.push_back(expand_env_variables(optarg)); break;

            case 'I':
            {
                auto list = read_input_file_list(optarg);
                inputs.insert(inputs.end(), list.begin(), list.end());
            }
            break;

            case 'O':
            {
                auto list = read_input_file_list(optarg);
                outputs.insert(outputs.end(), list.begin(), list.end());
            }
            break;

            case 'e': exclude_inputs.push_back(expand_env_variables(optarg)); break;
            case 'E': env_list_files.push_back(optarg); break;
            case 'S': signature_keys.push_back(optarg); break;
            case 'c': cache_dir = optarg; break;
            case 'C': cache_format_str = optarg; break;
            case 'H': hash_type = optarg; break;
            case 'f': force = true; break;
            case 'd': dry_run = true; break;
            case 'v': g_verbose = true; break;

            case kOptSandbox:
                sandbox_requested = true;
                break;
            case kOptAllowRead:
                sandbox_requested = true;
                sandbox_allow_read.emplace_back(expand_env_variables(optarg));
                break;
            case kOptAllowWrite:
                sandbox_requested = true;
                sandbox_allow_write.emplace_back(expand_env_variables(optarg));
                break;
            case kOptSandboxProfile:
                sandbox_requested = true;
                sandbox_profile_path = expand_env_variables(optarg);
                break;
            case kOptDenyNetwork:
                sandbox_requested = true;
                sandbox_deny_network = true;
                break;

            case 'h':
                print_usage(std::cout);
                return 0;

            case 'V':
                printf("gate %s\n", STRINGIFY_VALUE(REPLAY_VERSION));
                return 0;

            default:
                print_usage(std::cerr);
                return 2;
        }
    }

    // Everything after "--" is the command
    if (optind >= argc)
    {
        std::cerr << "error: no command specified after --\n";
        print_usage(std::cerr);
        return 2;
    }

    int cmd_argc = argc - optind;
    char** cmd_argv = argv + optind;

    // Collect Xcode "Run Script Phase" inputs/outputs from environment
    auto collect_xcode_files = [](const char* count_var, const char* prefix,
                                  std::vector<std::string>& dest)
    {
        const char* count_str = getenv(count_var);
        if (count_str == nullptr)
            return;
        int count = atoi(count_str);
        for (int i = 0; i < count; ++i)
        {
            std::string var = std::string(prefix) + std::to_string(i);
            const char* val = getenv(var.c_str());
            if (val != nullptr && val[0] != '\0')
                dest.emplace_back(val);
        }
    };

    auto collect_xcode_file_lists = [](const char* count_var, const char* prefix,
                                       std::vector<std::string>& dest)
    {
        const char* count_str = getenv(count_var);
        if (count_str == nullptr)
            return;
        int count = atoi(count_str);
        for (int i = 0; i < count; ++i)
        {
            std::string var = std::string(prefix) + std::to_string(i);
            const char* val = getenv(var.c_str());
            if (val != nullptr && val[0] != '\0')
            {
                auto list = read_input_file_list(val);
                dest.insert(dest.end(), list.begin(), list.end());
            }
        }
    };

    collect_xcode_files("SCRIPT_INPUT_FILE_COUNT", "SCRIPT_INPUT_FILE_", inputs);
    collect_xcode_file_lists("SCRIPT_INPUT_FILE_LIST_COUNT", "SCRIPT_INPUT_FILE_LIST_", inputs);
    collect_xcode_files("SCRIPT_OUTPUT_FILE_COUNT", "SCRIPT_OUTPUT_FILE_", outputs);
    collect_xcode_file_lists("SCRIPT_OUTPUT_FILE_LIST_COUNT", "SCRIPT_OUTPUT_FILE_LIST_", outputs);

    // Configure hash algorithm
    std::transform(hash_type.begin(), hash_type.end(), hash_type.begin(), ::tolower);
    if (hash_type == "crc32c")
        g_hash = FileHashAlgorithm::CRC32C;
    else if (hash_type == "blake3")
        g_hash = FileHashAlgorithm::BLAKE3;
    else
    {
        std::cerr << "error: invalid --hash value: " << hash_type << '\n';
        return 2;
    }

    // Configure cache format
    CacheFormat cache_format;
    std::transform(cache_format_str.begin(), cache_format_str.end(), cache_format_str.begin(), ::tolower);
    if (cache_format_str == "plist")
        cache_format = CacheFormat::Plist;
    else if (cache_format_str == "json")
        cache_format = CacheFormat::Json;
    else
    {
        std::cerr << "error: invalid --cache-format value: " << cache_format_str
                  << " (expected plist or json)\n";
        return 2;
    }

    // Resolve all paths to absolute before sandbox is applied.
// file_helpers::resolve_path() handles glob patterns by resolving only the literal directory prefix.

    std::string cache_dir_abs = file_helpers::resolve_path(cache_dir);

    for (auto& p : inputs)         p = file_helpers::resolve_path(p);

    for (auto& p : outputs)        p = file_helpers::resolve_path(p);

    for (auto& p : exclude_inputs) p = file_helpers::resolve_path(p);

    // Expand env list files into text (hashed in memory, no temp file).
    // Read env files BEFORE sandbox init so gate can access them without restrictions.
    std::string env_text = build_env_text(env_list_files);

    // Build command string for display and caching purposes.
    std::string command_str = build_command_string(cmd_argv, cmd_argc);

    // Apply sandbox before any I/O-heavy work. Once applied, the policy is
    // kernel-enforced on this process and inherited by the spawned command.
    if (sandbox_requested)
    {
        // Add current working directory for getcwd() and path resolution
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) != nullptr)
            sandbox_allow_read.push_back(cwd);

        // Auto-discover paths: inputs are read, outputs and cache are read-write
        if (!cache_dir_abs.empty())
            sandbox_allow_write.push_back(cache_dir_abs);

        for (const auto& p : inputs)
        {
            if (p.empty()) continue;
            std::string sp = globoverlap::glob_concrete_prefix(p);
            if (!sp.empty())
                sandbox_allow_read.push_back(sp);
        }
        for (const auto& p : outputs)
        {
            if (p.empty()) continue;
            std::string sp = globoverlap::glob_concrete_prefix(p);
            if (!sp.empty())
                sandbox_allow_write.push_back(sp);
        }
        // Excludes are paths the user marked as excluded from input fingerprinting.
        // The typical case is generated artifacts that live inside an input tree
        // and must be writable so the wrapped command can rebuild them — hence
        // read-write rather than read-only. (Pure "ignore-me" excludes get the
        // same access; harmless because the command will not touch them.)
        for (const auto& p : exclude_inputs)
        {
            if (p.empty()) continue;
            std::string sp = globoverlap::glob_concrete_prefix(p);
            if (!sp.empty())
                sandbox_allow_write.push_back(sp);
        }

        // Allow read access to the child tool being executed.
        // Tool path must be absolute when --sandbox is used: $PATH lookup happens
        // inside posix_spawn after the sandbox is active, so a bare name like
        // "clang" cannot be turned into a real allowlist entry here. Bare names
        // still happen to work for /bin and /usr/bin tools because bsd.sb covers
        // those, but anything else (Homebrew, Python venvs, custom installs)
        // requires the absolute path.
        if (cmd_argc > 0 && cmd_argv[0] != nullptr)
        {
            std::string tool_path = file_helpers::resolve_path(cmd_argv[0]);
            if (!tool_path.empty())
                sandbox_allow_read.push_back(tool_path);
        }

        if (!sandbox::InitializeSandbox(sandbox_profile_path, sandbox_allow_read, sandbox_allow_write, !sandbox_deny_network, g_verbose))
            return 2;
    }

    // Warn when an exclude can't possibly match any input root. Helps catch
    // typos and stale excludes (e.g. left over after refactoring inputs).
    // Basename-style excludes ("*.gen.h", no '/') match at any depth and are
    // skipped — they have no anchor to compare against.
    {
        auto literal_prefix = [](const std::string& p) -> std::string {
            return globoverlap::glob_concrete_prefix(p);
        };
        auto is_under = [](const std::string& path, const std::string& root) {
            if (root.empty()) return false;
            if (path == root) return true;
            return path.size() > root.size()
                && std::memcmp(path.data(), root.data(), root.size()) == 0
                && path[root.size()] == '/';
        };
        for (size_t i = 0; i < exclude_inputs.size(); ++i)
        {
            const std::string& e = exclude_inputs[i];
            if (e.find('/') == std::string::npos) continue;  // basename shortcut
            std::string e_prefix = literal_prefix(e);
            if (e_prefix.empty()) continue;
            bool covered = false;
            for (const auto& in : inputs)
            {
                if (is_under(e_prefix, literal_prefix(in))) { covered = true; break; }
            }
            if (!covered)
            {
                std::cerr << "warning: -e '" << e << "' does not fall under any input root\n";
            }
        }
    }

    // All existence / glob logic is now inside find_and_process_globbed_paths()

    std::string task_signature = compute_task_signature(inputs, outputs, exclude_inputs, command_str, hash_type, signature_keys);

    // Fingerprint inputs before execution (combined with env text)
    uint64_t input_fingerprint = fingerprint_files(inputs, exclude_inputs);
    input_fingerprint = combine_with_env(input_fingerprint, env_text);
    if (!inputs.empty() && input_fingerprint == 0)
    {
        std::cerr << "error: failed to fingerprint inputs\n";
        return 2;
    }

    // Check cache (unless forced)
    if (!force)
    {
        CacheEntry cached;
        if (cache_lookup(cache_dir, cache_format, task_signature, cached))
        {
            if (g_verbose)
                std::cerr << "gate: cache entry found, verifying...\n";

            // Fingerprint current inputs (combined with env text)
            if (input_fingerprint != 0 && input_fingerprint == cached.input_fingerprint)
            {
                // Fingerprint current outputs
                uint64_t current_output_fingerprint = outputs.empty() ? cached.output_fingerprint
                                                             : fingerprint_files(outputs);

                if ((outputs.empty() || current_output_fingerprint != 0) &&
                    current_output_fingerprint == cached.output_fingerprint)
                {
                    // Cache hit
                    if (dry_run || g_verbose)
                        std::cerr << "gate: cache hit, skipping: " << command_str << '\n';
                    return 0;
                }
                else if (g_verbose)
                {
                    std::cerr << "gate: output fingerprint changed\n";
                }
            }
            else if (g_verbose)
            {
                std::cerr << "gate: input fingerprint changed\n";
            }
        }
        else if (g_verbose)
        {
            std::cerr << "gate: no cache entry found\n";
        }
    }

    // Cache miss (or forced)
    if (dry_run)
    {
        std::cerr << "gate: cache miss, would execute: " << command_str << '\n';
        return 0;
    }

    if (g_verbose)
        std::cerr << "gate: executing: " << command_str << '\n';

    // Execute the command
    int exit_code = execute_command(cmd_argv);

    if (exit_code != 0)
    {
        if (g_verbose)
            std::cerr << "gate: command failed with exit code " << exit_code << '\n';
        return exit_code;
    }

    // Fingerprint outputs after execution
    uint64_t output_fingerprint = outputs.empty() ? 0 : fingerprint_files(outputs);
    if (!outputs.empty() && output_fingerprint == 0)
    {
        std::cerr << "error: failed to fingerprint outputs\n";
        return 2;
    }

    // Store in cache
    CacheEntry entry;
    entry.command = command_str;
    entry.inputs = inputs;
    entry.outputs = outputs;
    entry.exclude_inputs = exclude_inputs;
    entry.input_fingerprint = input_fingerprint;
    entry.output_fingerprint = output_fingerprint;
    entry.hash_algorithm = hash_type;
    entry.timestamp = current_timestamp();

    if (!cache_store(cache_dir, cache_format, task_signature, entry))
    {
        std::cerr << "warning: failed to update cache\n";
    }

    return 0;
}
