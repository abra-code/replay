#import <Foundation/Foundation.h>
#import "ReplayAction.h"

NSString *StringByExpandingEnvironmentVariablesWithErrorCheck(NSString *origString, ReplayContext *context);
NSArray<NSURL*> *ItemPathsToURLs(NSArray<NSString*> *itemPaths, ReplayContext *context);
NSArray<NSURL*> *GetDestinationsForMultipleItems(NSArray<NSURL*> *sourceItemURLs, NSURL *destinationDirectoryURL, ReplayContext *context);

#include <optional>
#include <string>

std::optional<std::string> ExpandEnvVars(const char *str, ReplayContext *context);
