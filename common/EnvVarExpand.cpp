#include "EnvVarExpand.h"
#include <cstring>
#include <unistd.h>

// macOS SDK does not declare environ in <unistd.h>
extern char **environ;

std::optional<std::string> expand_env_vars(
    std::string_view input,
    const std::unordered_map<std::string, std::string> &env)
{
    std::string result;
    result.reserve(input.size());
    size_t i = 0;
    while(i < input.size())
    {
        // Minimum sequence is ${A} = 4 chars; ${} (empty name) is not a variable.
        if(input[i] == '$' &&
           i + 3 < input.size() &&
           input[i + 1] == '{' &&
           input[i + 2] != '}')
        {
            size_t name_start = i + 2;
            size_t close = input.find('}', name_start);
            if(close == std::string_view::npos)
            {
                return std::nullopt; // unterminated ${
            }
            auto it = env.find(std::string(input.substr(name_start, close - name_start)));
            if(it == env.end())
            {
                return std::nullopt; // variable not found
            }
            result += it->second;
            i = close + 1;
        }
        else
        {
            result += input[i++];
        }
    }
    return result;
}

std::unordered_map<std::string, std::string> env_map_from_environ()
{
    std::unordered_map<std::string, std::string> map;
    if(environ == nullptr)
    {
        return map;
    }
    for(char **var = environ; *var != nullptr; ++var)
    {
        const char *eq = strchr(*var, '=');
        if(eq != nullptr)
        {
            map.emplace(std::string(*var, eq - *var), std::string(eq + 1));
        }
    }
    return map;
}
