#include "StringAndPath.h"
#include "EnvVarExpand.h"


std::optional<std::string>
ExpandEnvVars(const char *str, ReplayContext *context)
{
	if(str == nullptr)
		return std::nullopt;
	auto result = expand_env_vars(str, context->environment);
	if(!result.has_value())
	{
		LogError("error: missing or unterminated environment variable in \"%s\"\n", str);
		context->lastError.set("error: malformed string or missing environment variable", 1);
	}
	return result;
}
