#import "ReplayAction.h"

void StartSerialDispatch(ReplayContext *context);
void FinishSerialDispatchAndWait(ReplayContext *context);

void DispatchTasksSerially(NSArray<NSDictionary*> *playlist, ReplayContext *context);
void DispatchTaskSerially(NSDictionary *stepDescription, ReplayContext *context);

