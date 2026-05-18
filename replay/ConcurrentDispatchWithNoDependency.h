#include "ReplayAction.h"
#include <vector>

void StartConcurrentDispatchWithNoDependency(ReplayContext *context);
void FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context);

void DispatchTasksConcurrentlyWithNoDependency(const std::vector<ActionStep>& playlist, ReplayContext *context);
void DispatchTaskConcurrentlyWithNoDependency(ActionStep step, ReplayContext *context);
