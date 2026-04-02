#import "ReplayAction.h"

#ifdef __cplusplus
extern "C" {
#endif

void StartSerialDispatch(ReplayContext *context);
void FinishSerialDispatchAndWait(ReplayContext *context);

void DispatchTasksSerially(NSArray<NSDictionary*> *playlist, ReplayContext *context);
void DispatchTaskSerially(NSDictionary *stepDescription, ReplayContext *context);

#ifdef __cplusplus
}
#endif
