#include "ReplayAction.h"
#include <vector>

void StartSerialDispatch(ReplayContext *context);
void FinishSerialDispatchAndWait(ReplayContext *context);

void DispatchTasksSerially(const std::vector<ActionStep>& playlist, ReplayContext *context);
// Single-step dispatch for the streaming path (stdin / server); still takes NSDictionary*.
void DispatchTaskSerially(NSDictionary *stepDescription, ReplayContext *context);
