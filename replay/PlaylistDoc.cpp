#include "PlaylistDoc.h"
#include "yyjson.hpp"
#include "CFType.h"
#include "CFArr.h"
#include "CFDict.h"
#include "CFStr.h"
#include <filesystem>
#include <fcntl.h>
#include <sys/stat.h>
#include <cerrno>
#include <cstring>

// ---------------------------------------------------------------------------
// EnsureAbsolutePath
// ---------------------------------------------------------------------------

std::string EnsureAbsolutePath(std::string_view inputPath)
{
    if (inputPath.empty())
        return {};

    if (inputPath[0] == '/')
        return std::string(inputPath);

    try
    {
        std::filesystem::path cwd = std::filesystem::current_path();
        return (cwd / inputPath).lexically_normal().string();
    }
    catch (...)
    {
        return std::string(inputPath);
    }
}

// ---------------------------------------------------------------------------
// PlaylistDoc special members
// ---------------------------------------------------------------------------

PlaylistDoc::~PlaylistDoc() noexcept = default;

PlaylistDoc::PlaylistDoc(PlaylistDoc&& o) noexcept
    : jsonDoc(std::move(o.jsonDoc))
{
    cfRoot.Swap(o.cfRoot);
}

PlaylistDoc& PlaylistDoc::operator=(PlaylistDoc&& o) noexcept
{
    cfRoot.Adopt(o.cfRoot.Detach());
    jsonDoc = std::move(o.jsonDoc);
    return *this;
}

bool PlaylistDoc::valid() const noexcept
{
    return cfRoot != nullptr || (jsonDoc != nullptr && jsonDoc->valid());
}

// ---------------------------------------------------------------------------
// Step-array helpers (file-scope, not exposed in header)
// ---------------------------------------------------------------------------

static std::vector<ActionStep> cf_steps_from_array(CFArrayRef arrRef)
{
    CFArr arr(arrRef);
    CFIndex count = arr.GetCount();
    std::vector<ActionStep> steps;
    steps.reserve((size_t)count);
    for (CFIndex i = 0; i < count; i++)
    {
        CFDictionaryRef dict = nullptr;
        if (arr.GetValueAtIndex(i, dict))
            steps.emplace_back(dict);
    }
    return steps;
}

static std::vector<ActionStep> json_steps_from_array(Json::Val arr,
                                                      std::shared_ptr<Json::Document> doc)
{
    std::vector<ActionStep> steps;
    steps.reserve(arr.arr_size());
    Json::ArrIter iter(arr);
    while (iter.has_next())
    {
        auto item = iter.next();
        if (item.is_obj())
            steps.emplace_back(item.raw(), doc);
    }
    return steps;
}

// ---------------------------------------------------------------------------
// PlaylistDoc public accessors
// ---------------------------------------------------------------------------

std::vector<ActionStep> PlaylistDoc::root_steps() const
{
    if (cfRoot != nullptr)
    {
        CFArrayRef arr = CFType<CFArrayRef>::DynamicCast(cfRoot.Get());
        if (arr == nullptr)
            return {};
        return cf_steps_from_array(arr);
    }
    if (jsonDoc != nullptr && jsonDoc->valid())
    {
        auto root = jsonDoc->root();
        if (!root.is_arr())
            return {};
        return json_steps_from_array(root, jsonDoc);
    }
    return {};
}

std::vector<ActionStep> PlaylistDoc::steps_for_key(const std::string& key) const
{
    if (cfRoot != nullptr)
    {
        CFDictionaryRef dictRef = CFType<CFDictionaryRef>::DynamicCast(cfRoot.Get());
        if (dictRef == nullptr)
            return {};
        CFDict dict(dictRef);
        CFStr cfKey(key);
        CFArrayRef arr = nullptr;
        if (!dict.GetValue(cfKey, arr))
            return {};
        return cf_steps_from_array(arr);
    }
    if (jsonDoc != nullptr && jsonDoc->valid())
    {
        auto root = jsonDoc->root();
        if (!root.is_obj())
            return {};
        auto arr = root.obj_get(key);
        if (!arr.is_arr())
            return {};
        return json_steps_from_array(arr, jsonDoc);
    }
    return {};
}

// ---------------------------------------------------------------------------
// ReadFileBytes — reads file bytes via POSIX for the CF plist path
// ---------------------------------------------------------------------------

static std::vector<uint8_t> ReadFileBytes(const char* path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return {};
    struct stat st;
    if (fstat(fd, &st) != 0)
    {
        close(fd);
        return {};
    }
    std::vector<uint8_t> buf((size_t)st.st_size);
    ssize_t n = read(fd, buf.data(), buf.size());
    close(fd);
    if (n != (ssize_t)buf.size())
        return {};
    return buf;
}

// ---------------------------------------------------------------------------
// LoadPlaylist
// ---------------------------------------------------------------------------

PlaylistDoc LoadPlaylist(const char* playlistPath, ReplayContext* context)
{
    if (playlistPath == nullptr)
    {
        LogError("error: playlist file path not provided\n");
        return {};
    }

    std::string absPath = EnsureAbsolutePath(playlistPath);

    // Detect format hint from extension.
    bool tryJsonFirst = false;
    {
        auto dot = absPath.rfind('.');
        if (dot != std::string::npos)
        {
            std::string ext = absPath.substr(dot + 1);
            for (auto& c : ext) c = (char)tolower((unsigned char)c);
            tryJsonFirst = (ext == "json");
        }
    }

    PlaylistDoc result;

    // Allow trailing commas and comments to match NSJSONSerialization's leniency.
    constexpr yyjson_read_flag kJsonFlags =
        YYJSON_READ_ALLOW_TRAILING_COMMAS | YYJSON_READ_ALLOW_COMMENTS;

    auto try_json = [&]() -> bool
    {
        Json::Document doc = Json::parse_file(absPath.c_str(), kJsonFlags);
        if (!doc.valid())
            return false;
        auto root = doc.root();
        if (!root.is_obj() && !root.is_arr())
            return false;
        result.jsonDoc = std::make_shared<Json::Document>(std::move(doc));
        return true;
    };

    auto try_plist = [&]() -> bool
    {
        auto bytes = ReadFileBytes(absPath.c_str());
        if (bytes.empty())
            return false;
        CFObj<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, bytes.data(), (CFIndex)bytes.size()));
        if (data == nullptr)
            return false;
        CFObj<CFPropertyListRef> plist(CFPropertyListCreateWithData(
            kCFAllocatorDefault, data, kCFPropertyListImmutable, nullptr, nullptr));
        if (plist == nullptr)
            return false;
        if (CFType<CFDictionaryRef>::DynamicCast(plist) == nullptr &&
            CFType<CFArrayRef>::DynamicCast(plist) == nullptr)
            return false;
        result.cfRoot = std::move(plist);
        return true;
    };

    bool loaded = tryJsonFirst ? (try_json() || try_plist())
                               : (try_plist() || try_json());

    if (!loaded)
    {
        struct stat st;
        if (stat(absPath.c_str(), &st) != 0)
        {
            int err = errno;
            context->lastError.set(
                std::string("error: playlist file \"") + absPath + "\" cannot be opened: " + strerror(err), err);
            LogError("error: playlist file \"%s\" cannot be opened. Error: \"%s\"\n",
                     absPath.c_str(), strerror(err));
        }
        else
        {
            context->lastError.set("error: unknown or invalid playlist type", 1);
            LogError("error: unknown or invalid playlist type. Only .plist and .json playlists are supported\n");
        }
    }

    return result;
}
