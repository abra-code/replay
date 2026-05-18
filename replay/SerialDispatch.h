#include "ReplayAction.h"
#include <vector>

void StartSerialDispatch(ReplayContext *context);
void FinishSerialDispatchAndWait(ReplayContext *context);

void DispatchTasksSerially(const std::vector<ActionStep>& playlist, ReplayContext *context);
void DispatchTaskSerially(ActionStep step, ReplayContext *context);
