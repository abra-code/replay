//
//  json_serialization.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 2/17/26.
//

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include "CFDict.h"

namespace Json { class MutableDoc; }

// Writes a yyjson mutable document to a file at `path` (pretty-printed).
// Returns EXIT_SUCCESS or EXIT_FAILURE; errors are reported to stderr.
int write_json_doc_to_file(const Json::MutableDoc& doc, const char* path);

// Parses a JSON file with yyjson and converts the resulting tree to a
// CFMutableDictionary hierarchy of CFString / CFNumber / CFBoolean /
// CFMutableArray / CFMutableDictionary.
// Returns an empty CFMutableDict on failure or when the root is not an object.
CFMutableDict load_json_file_as_cfdict(const char* path);
