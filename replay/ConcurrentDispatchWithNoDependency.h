#import "ReplayAction.h"

void StartConcurrentDispatchWithNoDependency(ReplayContext *context);
void FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context);

void DispatchTasksConcurrentlyWithNoDependency(NSArray<NSDictionary*> *playlist, ReplayContext *context);
void DispatchTaskConcurrentlyWithNoDependency(NSDictionary *stepDescription, ReplayContext *context);

