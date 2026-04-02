#import "ReplayAction.h"

#ifdef __cplusplus
extern "C" {
#endif

void StartConcurrentDispatchWithNoDependency(ReplayContext *context);
void FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context);

void DispatchTasksConcurrentlyWithNoDependency(NSArray<NSDictionary*> *playlist, ReplayContext *context);
void DispatchTaskConcurrentlyWithNoDependency(NSDictionary *stepDescription, ReplayContext *context);

#ifdef __cplusplus
}
#endif
