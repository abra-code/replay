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

    // What the root container is: an array of action steps (run with no playlist key), a
    // dictionary of playlists (run with --playlist-key), or None when nothing was loaded.
    enum class RootKind { None, Array, Dictionary };
    RootKind root_kind() const noexcept;

    // The keys of a root dictionary that hold a playlist (an array), sorted; empty for any
    // other root. For the message that tells which key to pass.
    std::vector<std::string> playlist_keys() const;

    // True when a root dictionary holds a playlist (an array) under key.
    bool has_playlist(const std::string& key) const;

    // How many items the playlist array holds, action steps or not: a root array when key
    // is null, else the array under key (0 when there is none). Tells an empty playlist
    // from one whose items are not action steps (dictionaries), which the steps skip.
    size_t item_count(const std::string* key) const;

    // Returns steps when root is an array (no playlist key specified).
    std::vector<ActionStep> root_steps() const;

    // Returns steps under the given key from a root dictionary.
    std::vector<ActionStep> steps_for_key(const std::string& key) const;
};

PlaylistDoc LoadPlaylist(const char* playlistPath, ReplayContext* context);
