//
//  env_var_expand.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 12/2/25.
//


#include "env_var_expand.h"
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <unordered_map>
#include <unistd.h>
#include <dispatch/dispatch.h>

// macOS SDK does not declare "environ" in <unistd.h>, we must do it ourselves
extern char** environ;

static const std::unordered_map<std::string, std::string>& get_environment_variables()
{
    static std::unordered_map<std::string, std::string> envMap;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        if (environ == nullptr)
            return;
        
        for (char** env_var = environ; *env_var != nullptr; ++env_var)
        {
            const char* eq = strchr(*env_var, '=');
            if (eq != nullptr)
            {
                std::string key(*env_var, eq - *env_var);
                std::string value(eq + 1);
                envMap.emplace(std::move(key), std::move(value));
            }
        }
    });

    return envMap;
}

// this code handles both standard ${VAR} and Xcode-idiomatic $(VAR) environment variable syntax
std::string expand_env_variables(std::string_view input)
{
    const std::unordered_map<std::string, std::string>& env_map = get_environment_variables();
    std::string result;
    result.reserve(input.size());

    size_t i = 0;
    while (i < input.size())
    {
        if (input[i] == '$')
        {
            size_t start = i + 1;
            char opener = 0, closer = 0;

            if (start < input.size())
            {
                if (input[start] == '(')      { opener = '('; closer = ')'; ++start; }
                else if (input[start] == '{') { opener = '{'; closer = '}'; ++start; }
            }

            if (opener != 0)
            {
                size_t end = input.find(closer, start);
                if (end != std::string_view::npos)
                {
                    std::string varname(input.substr(start, end - start));
                    if (auto it = env_map.find(varname); it != env_map.end())
                        result += it->second;
                    i = end + 1;
                    continue;
                }
            }
        }
        result += input[i++];
    }
    return result;
}

std::vector<std::string> read_input_file_list(const std::string& path)
{
    std::vector<std::string> paths;
    std::ifstream file(path);
    if (!file.is_open())
        return paths; // caller should handle error

    std::string line;
    while (std::getline(file, line))
    {
        // Skip empty and comment lines
        if (line.empty() || line[0] == '#')
            continue;

        std::string expanded = expand_env_variables(line);
        if (!expanded.empty())
            paths.emplace_back(std::move(expanded));
    }
    return paths;
}
