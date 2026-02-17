//
//  json_serialization.m
//  fingerprint
//
//  Created by Tomasz Kukielka on 2/17/26.
//

#import <Foundation/Foundation.h>
#include "json_serialization.h"

int serialize_dict_to_json(CFDictionaryRef root_dict, const char* path)
{
    NSDictionary* root = (__bridge NSDictionary*)root_dict;
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (jsonData == nil)
    {
        fprintf(stderr, "Error: failed to serialize JSON: %s\n", error.localizedDescription.UTF8String);
        return EXIT_FAILURE;
    }
    
    FILE* file = fopen(path, "wb");
    if (file == nil)
    {
        fprintf(stderr, "Error: cannot open snapshot file for writing: %s\n", path);
        return EXIT_FAILURE;
    }
    
    size_t written = fwrite(jsonData.bytes, 1, jsonData.length, file);
    fclose(file);
    
    if (written != jsonData.length)
    {
        fprintf(stderr, "Error: failed to write snapshot file: %s\n", path);
        return EXIT_FAILURE;
    }
    
    return EXIT_SUCCESS;
}
