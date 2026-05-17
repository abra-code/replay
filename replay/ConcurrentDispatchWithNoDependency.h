#import "ReplayAction.h"
#include <vector>

void StartConcurrentDispatchWithNoDependency(ReplayContext *context);
void FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context);

void DispatchTasksConcurrentlyWithNoDependency(const std::vector<ActionStep>& playlist, ReplayContext *context);
// Single-step dispatch for the streaming path (stdin / server); still takes NSDictionary*.
void DispatchTaskConcurrentlyWithNoDependency(NSDictionary *stepDescription, ReplayContext *context);
