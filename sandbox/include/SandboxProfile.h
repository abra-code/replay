//
//  SandboxProfile.h
//  shared sandbox module for replay/gate (and other tools)
//
//  Self-sandbox a process at startup by translating a simple, static JSON
//  spec (or CLI-supplied directory lists) into Apple's SBPL profile language
//  and applying it via the private (but linkable) sandbox_init_with_parameters
//  function. Once applied, the policy is kernel-enforced and inherited by
//  every child process.
//
//  Typical usage:
//
//      sandbox::Config cfg;
//      cfg.read_write.push_back("/tmp");
//      cfg.read_only.push_back("/usr/lib");
//      if (!sandbox::ApplyConfig(cfg)) {
//          fprintf(stderr, "sandbox apply failed\n");
//          return EXIT_FAILURE;
//      }
//
//  Or load a JSON profile from disk and merge in extra dirs from argv:
//
//      sandbox::Config cfg;
//      sandbox::LoadConfigFromJsonFile("/path/to/profile.json", cfg);
//      cfg.read_write.push_back("/extra/dir");
//      sandbox::ApplyConfig(cfg);
//
//  JSON schema (all fields optional; defaults below):
//
//      {
//        "import_baseline": true,              // (import "bsd.sb") for dyld/mach/dev
//        "read_only":       [ "/path", ... ],  // file-read* allowed
//        "read_write":      [ "/path", ... ],  // file-read* + file-write*
//        "allow_network":   true,               // network* (default: allowed)
//        "allow_exec":      true,              // process-exec*
//        "allow_fork":      true,              // process-fork
//        "extra_rules":     [ "(allow ...)" ]  // raw SBPL escape hatch
//      }
//

#pragma once

#ifdef __cplusplus

#include <string>
#include <vector>

namespace sandbox
{

struct Config
{
    bool import_baseline = true;       // emits (import "bsd.sb")
    std::vector<std::string> read_only;
    std::vector<std::string> read_write;
    bool allow_network = true;
    bool allow_exec    = true;
    bool allow_fork    = true;
    std::vector<std::string> extra_rules;  // raw SBPL strings appended verbatim

    bool empty() const
    {
        return read_only.empty() && read_write.empty() && extra_rules.empty();
    }
};

// Load a JSON profile from a file into `out`. Returns true on success.
// On failure, prints a diagnostic to gLogErr and leaves `out` unchanged.
// The CLI-merged dirs are NOT touched here; callers can append to `out`
// after this call to merge --sandbox-allow-read/write into the JSON config.
bool LoadConfigFromJsonFile(const std::string& path, Config& out);

// Build the SBPL profile string from `config`. Always begins with
// (version 1) (debug deny). (debug deny) sets the default action to deny
// and additionally logs each denial to the unified system log, which is
// what sandbox-discover.py reads back to compose a JSON profile.
//
// Any read_only / read_write entry equal to "/" is dropped with a warning:
// granting subpath access on root would unlock the entire filesystem.
std::string GenerateSbplProfile(const Config& config);

// Returns true if sandbox_init_with_parameters is linked at runtime.
// On macOS this is normally always true; check is for robustness only.
bool IsAvailable();

// Apply an already-built SBPL profile to the current process. Once this
// returns true, the kernel enforces the profile for this process and every
// process it spawns; the policy cannot be removed or weakened.
// Returns false (hard failure) if the SPI is absent or the call reports an error.
// If verbose is true, prints the SBPL profile to stdout before applying.
bool ApplyProfile(const std::string& sbpl_profile, bool verbose = false);

// Convenience: GenerateSbplProfile + ApplyProfile.
// If verbose is true, prints the SBPL profile to stdout before applying.
bool ApplyConfig(const Config& config, bool verbose = false);

// Load optional JSON profile, merge allow_read/allow_write/allow_network
// All failures return false.
// If verbose is true, prints the SBPL profile to stdout before applying.
bool InitializeSandbox(const std::string& profile_path,
                  const std::vector<std::string>& allow_read,
                  const std::vector<std::string>& allow_write,
                  bool allow_network,
                  bool verbose = false);

}  // namespace sandbox

#endif  // __cplusplus
