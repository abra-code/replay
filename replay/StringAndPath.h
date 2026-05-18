#include "ReplayAction.h"
#include <optional>
#include <string>

std::optional<std::string> ExpandEnvVars(const char *str, ReplayContext *context);
