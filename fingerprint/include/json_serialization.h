//
//  json_serialization.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 2/17/26.
//

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

int serialize_dict_to_json(CFDictionaryRef root_dict, const char* path);
CFMutableDictionaryRef deserialize_json_from_file(const char* path);

#ifdef __cplusplus
}
#endif
