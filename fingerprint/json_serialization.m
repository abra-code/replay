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

CFMutableDictionaryRef deserialize_json_from_file(const char* path)
{
    FILE* file = fopen(path, "rb");
    if (file == NULL)
    {
        fprintf(stderr, "Error: cannot open JSON file: %s\n", path);
        return NULL;
    }
    
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    NSMutableData* data = [NSMutableData dataWithLength:size];
    size_t read = fread(data.mutableBytes, 1, size, file);
    fclose(file);
    
    if (read != (size_t)size)
    {
        fprintf(stderr, "Error: failed to read JSON file: %s\n", path);
        return NULL;
    }
    
    NSError* error = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (jsonObject == nil)
    {
        fprintf(stderr, "Error: failed to parse JSON: %s\n", error.localizedDescription.UTF8String);
        return NULL;
    }
    
    if (![jsonObject isKindOfClass:[NSMutableDictionary class]])
    {
        fprintf(stderr, "Error: JSON root is not a dictionary\n");
        return NULL;
    }
    
    NSMutableDictionary* dict = (NSMutableDictionary*)jsonObject;
    CFRetain((__bridge CFTypeRef)dict);
    return (__bridge CFMutableDictionaryRef)dict;
}
