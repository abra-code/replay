#pragma once

#include <string>
#include <string_view>
#include <vector>

/**
 * Expands ${VAR} or $(VAR) in a string using the current process environment.
 * Matches Xcode xcfilelist behavior
 *
 * @param input   Input string (e.g. from xcfilelist line)
 * @return        Fully expanded string. Unset variables are replaced with empty string.
 */
std::string expand_env_variables(std::string_view input);

/**
 * Convenience: expands variables in every line of a file.
 * Skips empty lines and lines starting with '#'.
 */
std::vector<std::string> read_input_file_list(const std::string& path);
