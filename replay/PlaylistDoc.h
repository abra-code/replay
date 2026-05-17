#pragma once
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include "CFObj.h"
#include "ReplayAction.h"

// Forward declaration — full definition only needed in PlaylistDoc.mm
namespace Json { class Document; }

// Returns an absolute path for inputPath, resolving relative paths against cwd.
std::string EnsureAbsolutePath(std::string_view inputPath);

// Owns one loaded playlist file in native in-memory format.
// CF for plist files (CFPropertyListCreateWithData), yyjson for JSON.
// Builds ActionStep vectors from the loaded tree without any extra parsing.
struct PlaylistDoc
{
    CFObj<CFPropertyListRef> cfRoot;
    std::shared_ptr<Json::Document> jsonDoc;

    PlaylistDoc() = default;
    ~PlaylistDoc() noexcept;
    PlaylistDoc(const PlaylistDoc&) = delete;
    PlaylistDoc& operator=(const PlaylistDoc&) = delete;
    PlaylistDoc(PlaylistDoc&& o) noexcept;
    PlaylistDoc& operator=(PlaylistDoc&& o) noexcept;

    bool valid() const noexcept;

    // Returns steps when root is an array (no playlist key specified).
    std::vector<ActionStep> root_steps() const;

    // Returns steps under the given key from a root dictionary.
    std::vector<ActionStep> steps_for_key(const std::string& key) const;
};

PlaylistDoc LoadPlaylist(const char* playlistPath, ReplayContext* context);
