//
//  PlaylistSandboxPaths.mm
//

#import <Foundation/Foundation.h>
#import "StringAndPath.h"
#include "PlaylistSandboxPaths.h"
#include "FileSystemHelpers.h"
#include "GlobOverlap.h"

#include <string>
#include <vector>


// Add one path string to the read or write sandbox vector.
// is_write=true  → add the parent directory (covers creation, atomic replace, deletion).
//                  Skips parent == "/" — granting write on root would open the entire
//                  filesystem; a playlist that targets "/file" must use --allow-write
//                  explicitly (and even then SandboxProfile rejects "/").
// is_write=false → add the path itself. SBPL (subpath ...) on a file matches just that
//                  file, so reading /etc/passwd does not unlock all of /etc. If a parent
//                  dir of this path is also in reads/writes, DeduplicatePaths drops the
//                  redundant entry.
// Glob patterns (containing *, ?, [, or {) → concrete prefix dir before first metachar.
//   The prefix is added to reads or writes according to is_write.
//   Endnode-only patterns with no '/' before the first metachar are skipped: they
//   have no useful directory prefix (the caller already added the search root).
static void AddPathToSandbox(NSString *rawPath,
                               NSDictionary<NSString*, NSString*> *env,
                               bool is_write,
                               std::vector<std::string>& reads,
                               std::vector<std::string>& writes)
{
    if (![rawPath isKindOfClass:[NSString class]] || [rawPath length] == 0)
        return;

    NSString *path = StringByExpandingEnvironmentVariables(rawPath, env);
    if (path == nil || [path length] == 0)
        return;

    if (![path isAbsolutePath])
    {
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        path = [cwd stringByAppendingPathComponent:path];
    }
    path = [path stringByStandardizingPath];

    std::string p([path UTF8String]);

    if (globoverlap::is_glob_pattern(p))
    {
        // Extract the concrete directory prefix before the first glob metachar.
        // empty string means there is no directory component before the wildcard (endnode glob) — skip.
        std::string prefix = globoverlap::glob_concrete_prefix(p);
        if (prefix.empty())
            return;
        if (is_write)
            writes.push_back(prefix);
        else
            reads.push_back(prefix);
        return;
    }

    // Concrete (non-glob) path.
    if (is_write)
    {
        NSString *parent = [path stringByDeletingLastPathComponent];
        // [parent length] > 1 skips "/" — see header comment.
        if (parent != nil && [parent length] > 1)
            writes.push_back([parent UTF8String]);
    }
    else
    {
        reads.push_back([path UTF8String]);
    }
}

static void AddFieldToSandbox(NSDictionary *action, NSString *key,
                                NSDictionary<NSString*, NSString*> *env,
                                bool is_write,
                                std::vector<std::string>& reads,
                                std::vector<std::string>& writes)
{
    id value = action[key];
    if (value == nil)
        return;
    if ([value isKindOfClass:[NSString class]])
    {
        AddPathToSandbox((NSString*)value, env, is_write, reads, writes);
    }
    else if ([value isKindOfClass:[NSArray class]])
    {
        for (id item in (NSArray*)value)
        {
            if ([item isKindOfClass:[NSString class]])
                AddPathToSandbox((NSString*)item, env, is_write, reads, writes);
        }
    }
}

static void ExtractPathsFromAction(NSDictionary *action,
                                    NSDictionary<NSString*, NSString*> *env,
                                    std::vector<std::string>& reads,
                                    std::vector<std::string>& writes)
{
    id actionType = action[@"action"];
    if (![actionType isKindOfClass:[NSString class]])
        return;

    // Match the action name case-sensitively, the same way ActionFromName does.
    // A case-insensitive match here would extract paths for actions that the
    // executor would later reject (e.g. "READ"), silently widening the sandbox.
    NSString *type = (NSString*)actionType;

    if ([type isEqualToString:@"read"])
    {
        AddFieldToSandbox(action, @"items", env, false, reads, writes);
    }
    else if ([type isEqualToString:@"info"])
    {
        AddFieldToSandbox(action, @"path",  env, false, reads, writes);
        AddFieldToSandbox(action, @"items", env, false, reads, writes);
    }
    else if ([type isEqualToString:@"list"] || [type isEqualToString:@"tree"])
    {
        AddFieldToSandbox(action, @"directory", env, false, reads, writes);
    }
    else if ([type isEqualToString:@"glob"])
    {
        AddFieldToSandbox(action, @"root", env, false, reads, writes);
    }
    else if ([type isEqualToString:@"create"])
    {
        AddFieldToSandbox(action, @"file",      env, true, reads, writes);
        AddFieldToSandbox(action, @"directory", env, true, reads, writes);
    }
    else if ([type isEqualToString:@"edit"])
    {
        AddFieldToSandbox(action, @"items", env, true, reads, writes);
    }
    else if ([type isEqualToString:@"clone"]    || [type isEqualToString:@"copy"] ||
             [type isEqualToString:@"hardlink"] || [type isEqualToString:@"symlink"])
    {
        AddFieldToSandbox(action, @"from",                  env, false, reads, writes);
        AddFieldToSandbox(action, @"items",                 env, false, reads, writes);
        AddFieldToSandbox(action, @"to",                    env, true,  reads, writes);
        AddFieldToSandbox(action, @"destination directory", env, true,  reads, writes);
    }
    else if ([type isEqualToString:@"move"])
    {
        // sources are exclusive inputs — removed from source location, so source needs rw
        AddFieldToSandbox(action, @"from",                  env, true, reads, writes);
        AddFieldToSandbox(action, @"items",                 env, true, reads, writes);
        AddFieldToSandbox(action, @"to",                    env, true, reads, writes);
        AddFieldToSandbox(action, @"destination directory", env, true, reads, writes);
    }
    else if ([type isEqualToString:@"delete"])
    {
        AddFieldToSandbox(action, @"items", env, true, reads, writes);
    }
    else if ([type isEqualToString:@"execute"])
    {
        NSString *tool = action[@"tool"];
        if ([tool isKindOfClass:[NSString class]])
        {
            NSString *expanded = StringByExpandingEnvironmentVariables(tool, env);
            if (expanded != nil && [expanded length] > 0)
            {
                if (![expanded isAbsolutePath])
                {
                    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
                    expanded = [cwd stringByAppendingPathComponent:expanded];
                }
                NSString *toolParent = [[expanded stringByStandardizingPath]
                                        stringByDeletingLastPathComponent];
                if (toolParent != nil && [toolParent length] > 0)
                    reads.push_back([toolParent UTF8String]);
            }
        }
        AddFieldToSandbox(action, @"inputs",           env, false, reads, writes);
        AddFieldToSandbox(action, @"exclusive inputs", env, true,  reads, writes);
        AddFieldToSandbox(action, @"outputs",          env, true,  reads, writes);
    }
    // "echo" emits text only — no path-bearing fields.
    // "start"/"wait" are dispatch-tool helpers, not real playlist actions; ignore.

    id deps = action[@"dependencies"];
    if ([deps isKindOfClass:[NSDictionary class]])
    {
        AddFieldToSandbox((NSDictionary*)deps, @"mutatingInputs", env, true, reads, writes);
    }
}


void ExtractPlaylistSandboxPaths(const char *playlist_path,
                                  NSArray<NSString*> *playlist_keys,
                                  NSDictionary<NSString*, NSString*> *env,
                                  std::vector<std::string>& reads,
                                  std::vector<std::string>& writes)
{
    if (playlist_path == nullptr)
        return;

    NSString *nsPath = [NSString stringWithUTF8String:playlist_path];
    if (nsPath == nil)
        return;

    if (![nsPath isAbsolutePath])
    {
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        nsPath = [cwd stringByAppendingPathComponent:nsPath];
        nsPath = [nsPath stringByStandardizingPath];
    }

    NSURL *url = [NSURL fileURLWithPath:nsPath];
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (data == nil)
        return;

    id root = nil;
    NSString *ext = [[url pathExtension] lowercaseString];
    if ([ext isEqualToString:@"json"])
    {
        root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (root == nil)
            root = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:nil error:&error];
    }
    else
    {
        root = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil error:&error];
        if (root == nil)
            root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    }
    if (root == nil)
        return;

    NSMutableArray<NSArray*> *actionArrays = [NSMutableArray new];

    if ([playlist_keys count] > 0 && [root isKindOfClass:[NSDictionary class]])
    {
        for (NSString *key in playlist_keys)
        {
            id arr = ((NSDictionary*)root)[key];
            if ([arr isKindOfClass:[NSArray class]])
                [actionArrays addObject:(NSArray*)arr];
        }
    }
    else if ([root isKindOfClass:[NSArray class]])
    {
        [actionArrays addObject:(NSArray*)root];
    }

    for (NSArray *actions in actionArrays)
    {
        for (id item in actions)
        {
            if ([item isKindOfClass:[NSDictionary class]])
                ExtractPathsFromAction((NSDictionary*)item, env, reads, writes);
        }
    }
}
