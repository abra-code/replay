#import <Foundation/Foundation.h>
#import "ReplayAction.h"

#ifdef __cplusplus
extern "C" {
#endif

NSString *StringByExpandingEnvironmentVariables(NSString *origString, NSDictionary<NSString *,NSString *> *environment);
NSString *StringByExpandingEnvironmentVariablesWithErrorCheck(NSString *origString, ReplayContext *context);
NSArray<NSURL*> *ItemPathsToURLs(NSArray<NSString*> *itemPaths, ReplayContext *context);
NSArray<NSURL*> *GetDestinationsForMultipleItems(NSArray<NSURL*> *sourceItemURLs, NSURL *destinationDirectoryURL, ReplayContext *context);

#ifdef __cplusplus
}
#endif
