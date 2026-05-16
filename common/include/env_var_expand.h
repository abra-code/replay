#pragma once
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

// Expands ${VAR} sequences in input using the provided environment map.
// ${} with an empty name is not treated as a variable and is passed through literally.
// Minimum sequence: ${A} (4 characters).
// Returns nullopt if any referenced variable is not found in env,
// or if a ${ sequence is unterminated.
std::optional<std::string> expand_env_vars(
    std::string_view input,
    const std::unordered_map<std::string, std::string> &env);

// Builds an environment map from the current process environment (environ).
std::unordered_map<std::string, std::string> env_map_from_environ();
