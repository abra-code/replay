#include "TaskCache.h"
#include "TaskFingerprint.h"
#include "GlobOverlap.h"
#include "LogStream.h"
#include "OutputSerializer.h"
#include "PosixFileOps.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <vector>

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>

#include "blake3.h"
#include "json_serialization.h"
#include "yyjson.hpp"
#include "CFObj.h"
#include "CFStr.h"
#include "CFDict.h"

static const int64_t kManifestVersion = 1;

const char *
CacheHashAlgorithmName(FileHashAlgorithm algorithm)
{
	return (algorithm == FileHashAlgorithm::BLAKE3) ? "blake3" : "crc32c";
}

// ============================================================================
// Task signature
// ============================================================================

// Every variable-length string is hashed as an 8-byte little-endian length
// followed by its raw bytes, and every field group is preceded by a one-byte
// domain tag. The length prefix removes the delimiter-injection ambiguity of
// gate's separator-only scheme (gate/gate_cache.cpp), where a path containing
// the separator byte could impersonate a field boundary.
static void hash_tag(blake3_hasher &hasher, uint8_t tag)
{
	blake3_hasher_update(&hasher, &tag, 1);
}

static void hash_string(blake3_hasher &hasher, const std::string &value)
{
	uint8_t lengthBytes[8];
	uint64_t length = (uint64_t)value.size();
	for(size_t i = 0; i < sizeof(lengthBytes); ++i)
	{
		lengthBytes[i] = (uint8_t)((length >> (8 * i)) & 0xFF);
	}
	blake3_hasher_update(&hasher, lengthBytes, sizeof(lengthBytes));
	blake3_hasher_update(&hasher, value.data(), value.size());
}

static void hash_u64(blake3_hasher &hasher, uint64_t value)
{
	uint8_t bytes[8];
	for(size_t i = 0; i < sizeof(bytes); ++i)
	{
		bytes[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
	}
	blake3_hasher_update(&hasher, bytes, sizeof(bytes));
}

// The element count makes the stream self-delimiting: without it the encoding relies on
// the domain tags never being confusable with a length prefix byte, which holds only
// because paths do not contain NUL bytes. With the count it is injective outright.
static void hash_sorted_strings(blake3_hasher &hasher, uint8_t tag, const std::vector<std::string> &values)
{
	hash_tag(hasher, tag);
	hash_u64(hasher, (uint64_t)values.size());
	std::vector<std::string> sorted = values;
	std::sort(sorted.begin(), sorted.end());
	for(const auto &value : sorted)
	{
		hash_string(hasher, value);
	}
}

static std::string hex64(uint64_t value)
{
	char buffer[17];
	snprintf(buffer, sizeof(buffer), "%016llx", (unsigned long long)value);
	return std::string(buffer);
}

std::string
compute_task_signature(const std::string &actionName,
                       const std::vector<std::string> &inputs,
                       const std::vector<std::string> &exclusiveInputs,
                       const std::vector<std::string> &mutatingInputs,
                       const std::vector<std::string> &outputs,
                       const std::string &extras,
                       const std::vector<std::string> &envNames,
                       const std::string &playlistKey)
{
	blake3_hasher hasher;
	blake3_hasher_init(&hasher);

	hash_tag(hasher, 0x01);
	hash_string(hasher, actionName);
	hash_sorted_strings(hasher, 0x02, inputs);
	hash_sorted_strings(hasher, 0x03, exclusiveInputs);
	hash_sorted_strings(hasher, 0x04, mutatingInputs);
	hash_sorted_strings(hasher, 0x05, outputs);
	hash_tag(hasher, 0x06);
	hash_string(hasher, extras);
	hash_sorted_strings(hasher, 0x07, envNames);
	hash_tag(hasher, 0x08);
	hash_string(hasher, playlistKey);

	uint8_t output[8] = {0};
	blake3_hasher_finalize(&hasher, output, sizeof(output));

	uint64_t key = 0;
	for(size_t i = 0; i < sizeof(output); ++i)
	{
		key |= ((uint64_t)output[i]) << (8 * i);
	}
	return hex64(key);
}

// ============================================================================
// world_out
// ============================================================================

static std::optional<uint64_t>
compute_world_out_internal(const std::vector<std::string> &ownedPaths, bool outputsExistenceOnly)
{
	if(!outputsExistenceOnly)
	{
		// requireConcreteFiles is false on purpose: an owned path that is absent is a
		// legitimate end state (a delete's items, a move's source), and absence is what
		// the fixed-point check reproduces. A failed rollup (glob compile, allocation)
		// propagates as nullopt: collapsing it to a sentinel would make the same
		// deterministic failure at store and check time look like a match - a wrong hit.
		return TaskFingerprint::fingerprint_paths(ownedPaths, false);
	}

	// create directory: the output must be checked as existence + type only, never as
	// content, because other tasks legitimately write into it afterwards. Hashing the
	// directory recursively here would make the task miss on every run (design 4.6).
	blake3_hasher hasher;
	blake3_hasher_init(&hasher);
	blake3_hasher_update(&hasher, "\x01dir-exists", 11);

	std::vector<std::string> sorted = ownedPaths;
	std::sort(sorted.begin(), sorted.end());
	for(const auto &path : sorted)
	{
		// lstat, not stat: stat follows the link, so replacing the created directory with
		// a symlink to some other directory would still record "directory present" and the
		// task would hit while every later step wrote through the link.
		struct stat st;
		uint8_t marker;
		if(lstat(path.c_str(), &st) == 0)
		{
			marker = S_ISDIR(st.st_mode) ? 1 : 0;
		}
		else if((errno == ENOENT) || (errno == ENOTDIR))
		{
			marker = 0; // genuinely absent
		}
		else
		{
			// Could not look (EACCES on a parent, ELOOP, EIO). Recording marker 0 here
			// would be the same value as "absent", so a stored absence would match a
			// directory that exists but is unreachable and it would never be created.
			return std::nullopt;
		}

		uint8_t lengthBytes[8];
		uint64_t length = (uint64_t)path.size();
		for(size_t i = 0; i < sizeof(lengthBytes); ++i)
		{
			lengthBytes[i] = (uint8_t)((length >> (8 * i)) & 0xFF);
		}
		blake3_hasher_update(&hasher, lengthBytes, sizeof(lengthBytes));
		blake3_hasher_update(&hasher, path.data(), path.size());
		blake3_hasher_update(&hasher, &marker, 1);
	}

	uint8_t output[8] = {0};
	blake3_hasher_finalize(&hasher, output, sizeof(output));

	uint64_t result = 0;
	for(size_t i = 0; i < sizeof(output); ++i)
	{
		result |= ((uint64_t)output[i]) << (8 * i);
	}
	return result;
}

std::optional<uint64_t>
compute_world_out(const std::vector<std::string> &ownedPaths, bool outputsExistenceOnly)
{
	// Same guarantee as TaskFingerprint::fingerprint_paths, which the non-existence-only
	// branch already has: this runs inside a taskBlock on a GCD queue (run_task) and on
	// the finalize fan-out, where an escaping exception is std::terminate. The
	// existence-only branch copies and sorts a vector, so it can throw bad_alloc on its
	// own. Report it as "unavailable", which can only cost an extra execution.
	try
	{
		return compute_world_out_internal(ownedPaths, outputsExistenceOnly);
	}
	catch(...)
	{
		return std::nullopt;
	}
}

std::string
build_cache_env_text(const std::vector<std::string> &globalNames,
                     const std::vector<std::string> &stepNames,
                     const std::unordered_map<std::string, std::string> &environment)
{
	// One sorted, deduplicated sequence over the UNION of both groups. The task signature
	// hashes that same union (WrapActionWithCache), so emitting the two groups separately
	// would let a name move between --cache-env and a step's "env" - or appear in both -
	// change this text, and therefore world_in, while the signature stayed identical: a
	// full spurious miss with nothing to explain it.
	std::vector<std::string> names = globalNames;
	names.insert(names.end(), stepNames.begin(), stepNames.end());
	std::sort(names.begin(), names.end());
	names.erase(std::unique(names.begin(), names.end()), names.end());

	std::string text;
	for(const auto &name : names)
	{
		text += name;
		text.push_back('=');
		auto found = environment.find(name);
		if(found != environment.end())
			text += found->second;
		text.push_back('\n');
	}
	return text;
}

std::function<void()>
WrapActionWithCache(std::function<bool()> action,
                    const std::string &actionName,
                    const std::vector<std::string> &inputs,
                    const std::vector<std::string> &mutatingInputs,
                    const std::vector<std::string> &exclusiveInputs,
                    const std::vector<std::string> &outputs,
                    const ActionCacheInfo &cacheInfo,
                    ReplayContext *context)
{
	CacheSession *session = context->cacheSession;
	if((session == nullptr) || !cacheInfo.cacheable)
	{
		return [inner = std::move(action)]() {
			(void)inner();
		};
	}

	// Signature and env text come from the expanded, original-case declaration
	// vectors, so the cache key is identical across execution engines and stays
	// independent of dependency-analysis internals.
	std::vector<std::string> signatureEnvNames = context->cacheGlobalEnvNames;
	signatureEnvNames.insert(signatureEnvNames.end(), cacheInfo.envNames.begin(), cacheInfo.envNames.end());
	std::string signature = compute_task_signature(actionName, inputs, exclusiveInputs, mutatingInputs, outputs,
		cacheInfo.extras, signatureEnvNames, context->playlistKey);
	std::string envText = build_cache_env_text(context->cacheGlobalEnvNames, cacheInfo.envNames, context->environment);

	// Owned paths (world_out material): outputs + exclusive + mutating, glob or
	// concrete. Concrete outputs separately for the miss-reason refinement.
	std::vector<std::string> ownedPaths = outputs;
	ownedPaths.insert(ownedPaths.end(), exclusiveInputs.begin(), exclusiveInputs.end());
	ownedPaths.insert(ownedPaths.end(), mutatingInputs.begin(), mutatingInputs.end());

	std::vector<std::string> concreteOutputs;
	for(const auto &oneOutput : outputs)
	{
		if(!globoverlap::is_glob_pattern(oneOutput))
			concreteOutputs.push_back(oneOutput);
	}

	TaskCacheRecord *record = session->make_record(std::move(signature), actionName, inputs,
		std::move(ownedPaths), std::move(concreteOutputs), std::move(envText), cacheInfo.outputsExistenceOnly);
	return [session, record, inner = std::move(action)]() {
		session->run_task(record, inner);
	};
}

// ============================================================================
// Manifest serialization
// ============================================================================

static std::string current_timestamp()
{
	time_t now = time(nullptr);
	struct tm timeParts;
	localtime_r(&now, &timeParts);
	char buffer[32];
	strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S", &timeParts);
	return std::string(buffer);
}

// Strict inverse of hex64: exactly 16 hex digits, nothing else. strtoull alone would
// accept "0x..", leading spaces, a sign and trailing junk, and would silently yield 0
// for a field that is not a number at all - a value a real rollup can also take.
static bool hex64_from_cfstring(CFStringRef value, uint64_t &outValue)
{
	if(value == nullptr)
		return false;
	if(CFGetTypeID(value) != CFStringGetTypeID())
		return false;

	std::string text = CFStr::ToString(value);
	if(text.size() != 16)
		return false;

	uint64_t result = 0;
	for(char oneChar : text)
	{
		unsigned digit;
		if((oneChar >= '0') && (oneChar <= '9'))
			digit = (unsigned)(oneChar - '0');
		else if((oneChar >= 'a') && (oneChar <= 'f'))
			digit = (unsigned)(oneChar - 'a') + 10;
		else if((oneChar >= 'A') && (oneChar <= 'F'))
			digit = (unsigned)(oneChar - 'A') + 10;
		else
			return false;
		result = (result << 4) | digit;
	}
	outValue = result;
	return true;
}

// Load a binary plist into a CFMutableDictionary. Returns an empty dict on failure.
static CFMutableDict load_plist_file_as_cfdict(const std::string &path)
{
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if(file.fail())
		return {};

	std::streamsize size = file.tellg();
	if(size <= 0)
		return {};

	file.seekg(0, std::ios::beg);
	std::vector<char> buffer((size_t)size);
	if(!file.read(buffer.data(), size))
		return {};

	CFObj<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, (const UInt8 *)buffer.data(), (CFIndex)size));
	if(data == nullptr)
		return {};

	CFErrorRef error = nullptr;
	CFPropertyListFormat plistFormat;
	CFObj<CFTypeRef> plist(CFPropertyListCreateWithData(
		kCFAllocatorDefault, data, kCFPropertyListMutableContainers, &plistFormat, &error));

	if(plist == nullptr)
	{
		if(error != nullptr)
			CFRelease(error);
		return {};
	}

	// A corrupt manifest must be treated as empty, never trusted to be a dictionary:
	// blindly casting an array or a string here and calling CFDictionaryGetValueIfPresent
	// on it aborts the process, which would make a disposable cache file fatal.
	if(CFGetTypeID(plist) != CFDictionaryGetTypeID())
		return {};

	return CFMutableDict((CFMutableDictionaryRef)(CFTypeRef)plist, kCFObjRetain);
}

static int write_plist_dict_to_file(CFDictionaryRef dict, const std::string &path)
{
	CFErrorRef error = nullptr;
	CFObj<CFDataRef> data(CFPropertyListCreateData(kCFAllocatorDefault, dict,
		kCFPropertyListBinaryFormat_v1_0, 0, &error));
	if(data == nullptr)
	{
		if(error != nullptr)
			CFRelease(error);
		LogError("error: failed to serialize cache manifest plist\n");
		return EXIT_FAILURE;
	}

	std::ofstream out(path, std::ios::out | std::ios::binary);
	if(out.fail())
	{
		LogError("error: cannot open cache manifest for writing: %s\n", path.c_str());
		return EXIT_FAILURE;
	}

	out.write(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), CFDataGetLength(data));

	// Close explicitly: write() only buffers, so a full disk or quota hit surfaces at
	// flush time. Reporting success here and then renaming would put a truncated plist
	// over a good manifest.
	out.close();
	if(out.fail())
	{
		LogError("error: cannot write cache manifest: %s\n", path.c_str());
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

// ============================================================================
// CacheSession
// ============================================================================

CacheSession::CacheSession(std::string playlistPath, std::string playlistKey, ReplayContext *context)
	: mPlaylistPath(std::move(playlistPath))
	, mPlaylistKey(std::move(playlistKey))
	, mContext(context)
{
	// One manifest per playlist FILE, keyed by the hash of its resolved path so the
	// name stays short and filesystem-safe regardless of how deep the playlist lives.
	blake3_hasher hasher;
	blake3_hasher_init(&hasher);
	blake3_hasher_update(&hasher, mPlaylistPath.data(), mPlaylistPath.size());
	uint8_t output[8] = {0};
	blake3_hasher_finalize(&hasher, output, sizeof(output));

	uint64_t playlistId = 0;
	for(size_t i = 0; i < sizeof(output); ++i)
	{
		playlistId |= ((uint64_t)output[i]) << (8 * i);
	}

	const char *extension = (mContext->cacheFormat == CacheFormat::Json) ? "json" : "plist";
	mManifestPath = mContext->cacheDir + "/" + hex64(playlistId) + ".replay-cache." + extension;
}

void
CacheSession::read_manifest_entries(std::unordered_map<std::string, StoredCacheEntry> &outEntries) const
{
	// The manifest is disposable state: absent, empty, unparseable, wrong-version and
	// wrong-hash-algorithm all mean the same thing here - start from nothing and
	// overwrite on save. None of them is worth a diagnostic or a failure.
	//
	// Deliberately no read-side lock in load(): write_manifest publishes atomically via
	// temp+rename, so any open() there sees a complete manifest inode. Keep it that
	// way - adding a shared flock would only be needed if the write side ever stopped
	// being atomic, and that is the thing not to do. write_manifest calls this a second
	// time while holding the exclusive lock, to merge rather than clobber.
	struct stat st;
	if((stat(mManifestPath.c_str(), &st) != 0) || (st.st_size <= 0))
		return;

	CFMutableDict root = (mContext->cacheFormat == CacheFormat::Json)
		? load_json_file_as_cfdict(mManifestPath.c_str(), /*quiet=*/true)
		: load_plist_file_as_cfdict(mManifestPath);

	int64_t version = 0;
	if(!root.GetValue(CFSTR("version"), version) || (version != kManifestVersion))
		return;

	CFStringRef hashAlgorithm = nullptr;
	if(!root.GetValue(CFSTR("hash_algorithm"), hashAlgorithm))
		return;
	if(CFStr::ToString(hashAlgorithm) != CacheHashAlgorithmName(mContext->cacheHash))
		return; // per-file hashes are incomparable across algorithms: start over

	// Guards against a 64-bit playlist-id collision silently merging two playlists' caches.
	CFStringRef storedPlaylist = nullptr;
	if(!root.GetValue(CFSTR("playlist"), storedPlaylist))
		return;
	if(CFStr::ToString(storedPlaylist) != mPlaylistPath)
		return;

	CFDictionaryRef tasks = nullptr;
	if(!root.GetValue(CFSTR("tasks"), tasks))
		return;

	CFIndex taskCount = CFDictionaryGetCount(tasks);
	if(taskCount <= 0)
		return;

	std::vector<const void *> keys((size_t)taskCount, nullptr);
	std::vector<const void *> values((size_t)taskCount, nullptr);
	CFDictionaryGetKeysAndValues(tasks, keys.data(), values.data());

	for(CFIndex i = 0; i < taskCount; ++i)
	{
		CFStringRef signature = (CFStringRef)keys[(size_t)i];
		CFDictionaryRef taskRef = (CFDictionaryRef)values[(size_t)i];
		if((signature == nullptr) || (taskRef == nullptr))
			continue;
		if((CFGetTypeID(signature) != CFStringGetTypeID()) || (CFGetTypeID(taskRef) != CFDictionaryGetTypeID()))
			continue;

		CFDict task(taskRef);
		StoredCacheEntry entry;

		// world_in and world_out are the two fields a wrong skip would ride on, so a
		// missing or unparseable one invalidates the whole entry rather than defaulting
		// to zero: a zero-defaulted field would compare equal to any other truncated
		// entry, and to a genuine rollup that happens to be zero.
		CFStringRef text = nullptr;
		if(!task.GetValue(CFSTR("world_in"), text) || !hex64_from_cfstring(text, entry.worldIn))
			continue;
		if(!task.GetValue(CFSTR("world_out"), text) || !hex64_from_cfstring(text, entry.worldOut))
			continue;

		if(task.GetValue(CFSTR("action"), text))
			entry.actionName = CFStr::ToString(text);
		if(task.GetValue(CFSTR("key"), text))
			entry.playlistKey = CFStr::ToString(text);
		if(task.GetValue(CFSTR("timestamp"), text))
			entry.timestamp = CFStr::ToString(text);

		outEntries.emplace(CFStr::ToString(signature), std::move(entry));
	}
}

void
CacheSession::load()
{
	// A corrupt manifest must never be fatal, and parsing one is not allocation-free:
	// load_plist_file_as_cfdict sizes a buffer from the file length, and the CF and
	// yyjson readers allocate per node. bad_alloc here would take down a run over
	// disposable state.
	try
	{
		read_manifest_entries(mLoadedEntries);
	}
	catch(...)
	{
		mLoadedEntries.clear();
	}
}

const StoredCacheEntry *
CacheSession::lookup(const std::string &signature) const
{
	auto found = mLoadedEntries.find(signature);
	if(found == mLoadedEntries.end())
		return nullptr;
	return &found->second;
}

TaskCacheRecord *
CacheSession::make_record(std::string signature,
                          std::string actionName,
                          std::vector<std::string> plainInputs,
                          std::vector<std::string> ownedPaths,
                          std::vector<std::string> concreteOutputs,
                          std::string envText,
                          bool outputsExistenceOnly)
{
	std::lock_guard<std::mutex> lock(mRecordsMutex);
	// TaskCacheRecord holds an atomic and is therefore neither copyable nor movable:
	// construct in place and fill the fields.
	TaskCacheRecord &record = mRecords.emplace_back();
	record.signature = std::move(signature);
	record.actionName = std::move(actionName);
	record.playlistKey = mPlaylistKey;
	record.plainInputs = std::move(plainInputs);
	record.ownedPaths = std::move(ownedPaths);
	record.concreteOutputs = std::move(concreteOutputs);
	record.envText = std::move(envText);
	record.outputsExistenceOnly = outputsExistenceOnly;
	return &record;
}

// The first concrete output identifies the task in cache report lines; a task
// with only glob-declared paths falls back to its first owned path.
static const std::string &
report_path(const TaskCacheRecord *record)
{
	static const std::string empty;
	if(!record->concreteOutputs.empty())
		return record->concreteOutputs.front();
	if(!record->ownedPaths.empty())
		return record->ownedPaths.front();
	return empty;
}

void
CacheSession::run_task(TaskCacheRecord *record, const std::function<bool()> &inner)
{
	// world_in is ALWAYS computed when a record exists - for new tasks and under
	// --cache-refresh too - because it is what finalize stores if the task executes
	// successfully. It must describe the state the task actually consumes, so it is
	// captured here, immediately before the task runs, never at end of run (4.1).
	std::optional<uint64_t> rollup = TaskFingerprint::fingerprint_paths(record->plainInputs, true);
	if(rollup.has_value())
		record->checkedWorldIn = TaskFingerprint::combine_with_env(*rollup, record->envText);

	const StoredCacheEntry *entry = lookup(record->signature);

	const char *missReason = nullptr;
	if(!record->checkedWorldIn.has_value())
		missReason = "missing input";
	else if(mContext->cacheRefresh)
		missReason = "refresh";
	else if(entry == nullptr)
		missReason = "new task";
	else if(*record->checkedWorldIn != entry->worldIn)
		missReason = "inputs changed";
	else
	{
		// The owned-paths rollup is the one and only skip criterion for products: it
		// encodes presence and absence alike, so a product that is legitimately absent
		// at end of run (created here, deleted by a later step - the delete fixed
		// point) still matches its recorded state and hits. An existence check must
		// never veto that: it would re-run create+delete chains on every run forever.
		// A rollup that cannot be computed can never hit.
		std::optional<uint64_t> currentOut = compute_world_out(record->ownedPaths, record->outputsExistenceOnly);
		if(!currentOut.has_value() || (*currentOut != entry->worldOut))
		{
			missReason = "products changed";
			// Refine the reason for the common case. lstat, not stat: the rollup
			// records a symlink output as the link itself, so a dangling link is
			// a present product, not a missing one.
			for(const auto &path : record->concreteOutputs)
			{
				struct stat st;
				if(lstat(path.c_str(), &st) != 0)
				{
					missReason = "output missing";
					break;
				}
			}
		}
	}

	if(missReason == nullptr)
	{
		record->outcome.store(CacheOutcome::Hit, std::memory_order_release);
		if(mContext->dryRun)
		{
			// The dry-run report IS the output of the run, so it belongs on stdout.
			// orderedOutput is forced off in both engines that can cache (main.cpp), so
			// the line can go through the serializer without slot bookkeeping - the
			// skipped action never fills the slots it reserved.
			std::string line = std::string("[cache] HIT ") + record->actionName + " " + report_path(record) + "\n";
			mContext->outputSerializer->scheduleString(std::move(line), -1);
		}
		else if(mContext->verbose)
		{
			// During a real run this is a diagnostic, not output: stderr, same "cache:"
			// prefix as the summary line, so --cache never alters a playlist's stdout.
			LogError("cache: HIT %s %s\n", record->actionName.c_str(), report_path(record).c_str());
		}
		return;
	}

	if(mContext->dryRun)
	{
		std::string line = std::string("[cache] MISS (") + missReason + ") " + record->actionName + " " + report_path(record) + "\n";
		mContext->outputSerializer->scheduleString(std::move(line), -1);
	}
	else if(mContext->verbose)
	{
		// Under --verbose the reason goes to STDERR as a "cache:" diagnostic, next to the
		// end-of-run summary - not to stdout as the "[cache]" dry-run report format. A miss
		// is followed by the action's own output, so putting the line on stdout would make
		// --cache change what an executing playlist prints. It is worth printing at all
		// because a task whose world cannot be fingerprinted (an unreadable file under a
		// declared output, a declared input that does not exist) misses on EVERY run,
		// forever, and nothing else distinguishes that from a merely cold cache.
		LogError("cache: MISS (%s) %s %s\n", missReason, record->actionName.c_str(), report_path(record).c_str());
	}

	if(mContext->dryRun)
	{
		// Handlers no-op under dryRun but still print their action descriptions.
		// The outcome is left at NotSeen: nothing executed, and finalize never runs
		// under dryRun anyway, so no entry can be stored for this pretend run.
		(void)inner();
		return;
	}

	bool isOK = inner();
	record->outcome.store(isOK ? CacheOutcome::ExecutedOK : CacheOutcome::Failed, std::memory_order_release);
}

void
CacheSession::finalize_and_save()
{
	// The whole of finalize is disposable bookkeeping running after the build already
	// succeeded, and it allocates freely (maps, the manifest merge, the serializers).
	// An escaping bad_alloc here would terminate the process with every product already
	// written, so it is caught for the same reason load() catches: losing the manifest
	// costs a rebuild, losing the run costs the run.
	try
	{
		finalize_and_save_internal();
	}
	catch(...)
	{
		LogError("error: could not save cache manifest: %s\n", mManifestPath.c_str());
	}
}

void
CacheSession::finalize_and_save_internal()
{
	// This run's delta only. The manifest itself is re-read under the exclusive lock in
	// write_manifest and the delta applied there, so a concurrent invocation on another
	// playlist key of the same playlist file cannot be clobbered: merging into the
	// snapshot load() took before the scheduler started would silently drop whatever
	// that other invocation published in the meantime.
	std::unordered_map<std::string, StoredCacheEntry> updatedEntries;
	std::unordered_set<std::string> removedSignatures;

	std::unordered_set<std::string> seenSignatures;
	size_t hitCount = 0;
	size_t executedCount = 0;
	size_t failedCount = 0;

	std::string timestamp = current_timestamp();

	// Records that need an end-of-run world_out, collected first so the rollups can run
	// concurrently below. Doing them inline here would put one serial re-walk and re-hash
	// of every product tree on the critical path after the scheduler has already drained,
	// which on a wide playlist is the single longest thing left in the run.
	std::vector<TaskCacheRecord *> toStore;

	for(auto &record : mRecords)
	{
		seenSignatures.insert(record.signature);
		CacheOutcome outcome = record.outcome.load(std::memory_order_acquire);

		switch(outcome)
		{
			case CacheOutcome::Hit:
				++hitCount;
				// The check just proved the stored entry still matches: carry it unchanged.
			break;

			case CacheOutcome::ExecutedOK:
				++executedCount;

				// world_in was captured at CHECK time and already has envText folded in -
				// it is the state the task actually CONSUMED, stored verbatim. When it is
				// unavailable a declared concrete input was missing at check time, and we
				// store nothing at all: a value recomputed now would describe end-of-run
				// state the task never consumed, which is exactly the wrong skip design 4.1
				// forbids. Not storing costs one spurious miss next run, which is the
				// trade-off the design asks for.
				if(!record.checkedWorldIn.has_value())
					removedSignatures.insert(record.signature);
				else
					toStore.push_back(&record);
			break;

			case CacheOutcome::Failed:
				++failedCount;
				// Carry the old entry if there is one. It can only produce a hit later if
				// the declared world returns to the exact state that entry was recorded
				// from - i.e. the state a SUCCESSFUL run left - so the hit is correct even
				// though the last attempt failed. (Consequence worth knowing: a run that
				// fails and is then reverted comes back green without re-executing.)
			break;

			case CacheOutcome::NotSeen:
				// Never dispatched (cycle, or stop-on-error truncated the run). Carry.
			break;
		}
	}

	// world_out is captured HERE, at the end of the run, not when each task finished:
	// a later task may legitimately mutate an earlier task's products (an edit of a
	// generated file, a move, a delete). The end-of-run state is what a full
	// re-execution would reproduce, which is what gives the fixed-point semantics
	// (design 4.1). The scheduler has drained, so nothing is writing these paths and
	// the rollups are independent - fan them out.
	std::vector<std::optional<uint64_t>> worldOuts(toStore.size());
	if(!toStore.empty())
	{
		TaskCacheRecord **records = toStore.data();
		std::optional<uint64_t> *results = worldOuts.data();
		dispatch_apply(toStore.size(), DISPATCH_APPLY_AUTO, ^(size_t i) {
			results[i] = compute_world_out(records[i]->ownedPaths, records[i]->outputsExistenceOnly);
		});
	}

	for(size_t i = 0; i < toStore.size(); ++i)
	{
		const TaskCacheRecord *record = toStore[i];
		if(!worldOuts[i].has_value())
		{
			// Same rule as an unavailable world_in above: store nothing. A failed
			// rollup is likely deterministic (a glob that will not compile), and a
			// stored sentinel would match the same failure at check time - a wrong
			// hit. One spurious execution next run is the accepted price.
			removedSignatures.insert(record->signature);
			continue;
		}

		StoredCacheEntry entry;
		entry.actionName = record->actionName;
		entry.playlistKey = record->playlistKey;
		entry.worldIn = *record->checkedWorldIn;
		entry.worldOut = *worldOuts[i];
		entry.timestamp = timestamp;
		updatedEntries[record->signature] = std::move(entry);
	}

	if(!write_manifest(updatedEntries, removedSignatures, seenSignatures))
		return;

	LogError("cache: %zu hits, %zu executed, %zu failed, manifest %s\n",
		hitCount, executedCount, failedCount, mManifestPath.c_str());
}

bool
CacheSession::write_manifest(const std::unordered_map<std::string, StoredCacheEntry> &updatedEntries,
                             const std::unordered_set<std::string> &removedSignatures,
                             const std::unordered_set<std::string> &seenSignatures) const
{
	if(!posix_mkdir_p(mContext->cacheDir))
	{
		LogError("error: cannot create cache directory: %s\n", mContext->cacheDir.c_str());
		return false;
	}

	// Lock a dedicated file rather than the manifest itself: the manifest inode is
	// replaced by the rename below, so a lock held on it stops excluding anyone the
	// moment the first writer finishes, and a third process would sail straight past
	// a second one that is still writing. The lock file is never renamed or removed.
	// O_CLOEXEC so the descriptor cannot leak into an [execute] child and hold the
	// lock past our own close. O_NOFOLLOW because a shared cache directory is an
	// advertised use case: without it another user can pre-plant this name as a
	// symlink and have us open an arbitrary file of theirs for writing.
	std::string lockPath = mManifestPath + ".lock";
	int fd = open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0644);
	if(fd < 0)
	{
		LogError("error: cannot open cache lock file: %s\n", lockPath.c_str());
		return false;
	}
	// Everything from here to the unlock allocates (the manifest re-read, the merge, the
	// serializers), so the descriptor and the exclusive lock are released by scope exit
	// rather than by the code path: an escaping exception would otherwise hold the lock
	// until process exit and wedge every concurrent replay on this manifest.
	struct LockGuard
	{
		int fd;
		~LockGuard() { flock(fd, LOCK_UN); close(fd); }
	} lockGuard{fd};

	int lockResult;
	while(((lockResult = flock(fd, LOCK_EX)) != 0) && (errno == EINTR))
		{ /* a signal interrupted the wait: keep waiting rather than writing unlocked */ }
	if(lockResult != 0)
	{
		// ENOLCK, or a filesystem that does not implement flock - realistic on the network
		// and FUSE mounts where a shared cache directory is the whole point. Proceeding
		// would reintroduce the lost update this lock exists to prevent, silently.
		LogError("error: cannot lock cache manifest (%s): %s\n", strerror(errno), lockPath.c_str());
		return false;
	}

	// Re-read the manifest now that the lock is held, and apply this run's delta to
	// THAT, not to the snapshot load() took before the scheduler started. Two replay
	// invocations on different playlist keys of one playlist file share this manifest;
	// with a load-time snapshot the second writer's entries would silently overwrite
	// the first writer's and those tasks would re-execute on the next run.
	// Guarded for the same reason load() is: parsing a manifest allocates, this one may
	// have just been grown by another process, and an escaping bad_alloc here would
	// terminate the process AFTER the whole build succeeded. A failed re-read means we
	// merge into nothing, which costs a rebuild - never a wrong skip.
	std::unordered_map<std::string, StoredCacheEntry> entries;
	try
	{
		read_manifest_entries(entries);
	}
	catch(...)
	{
		entries.clear();
	}

	for(const auto &signature : removedSignatures)
	{
		entries.erase(signature);
	}
	for(const auto &pair : updatedEntries)
	{
		entries[pair.first] = pair.second;
	}

	// Prune entries for the playlist key we just processed whose task no longer exists
	// (step removed from the playlist, or its signature changed).
	//
	// Only safe when the graph build saw every step. TasksFromStep bails out early under
	// --stop-on-error once any error is set, including declaration-time errors like a
	// missing ${VAR}, so a single bad step near the top would otherwise delete the entries
	// of every later step - steps that are still present and unchanged - and force a full
	// rebuild after the typo is fixed. Carrying stale entries costs nothing: they are
	// revalidated against the real filesystem before any of them can produce a hit.
	if(mPruneAllowed)
	{
		for(auto it = entries.begin(); it != entries.end();)
		{
			if((it->second.playlistKey == mPlaylistKey) && (seenSignatures.count(it->first) == 0))
				it = entries.erase(it);
			else
				++it;
		}
	}

	// Format-parallel serialization: JSON is built natively with yyjson and never
	// passes through CFDictionary; plist goes through CF. Deserialization converges
	// on CFMutableDictionary for both.
	// The temp name carries the pid so two processes racing on the same manifest cannot
	// write the same temp file and hand each other a half-written manifest.
	std::string tempPath = mManifestPath + "." + std::to_string((long)getpid()) + ".tmp";

	// Claim the temp name before the writers open it by path. Both writers (yyjson's
	// fopen and std::ofstream) follow symlinks, so in a shared cache directory a name
	// planted by another user would redirect the manifest write onto any file WE can
	// write. O_EXCL|O_NOFOLLOW refuses anything already sitting there, including a
	// symlink; the unlink first clears a stale temp left behind by a crashed run that
	// happened to have this pid.
	unlink(tempPath.c_str());
	int tempFd = open(tempPath.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
	if(tempFd < 0)
	{
		LogError("error: cannot create temporary cache manifest: %s\n", tempPath.c_str());
		return false;
	}
	close(tempFd);

	int result;

	// unordered_map iteration order varies run to run; sort so an unchanged cache
	// produces a byte-identical manifest and the JSON form stays diffable.
	std::vector<const std::string *> signatures;
	signatures.reserve(entries.size());
	for(const auto &entry : entries)
	{
		signatures.push_back(&entry.first);
	}
	std::sort(signatures.begin(), signatures.end(),
		[](const std::string *a, const std::string *b) { return *a < *b; });
	if(mContext->cacheFormat == CacheFormat::Json)
	{
		Json::MutableDoc doc;
		Json::MutableVal root = doc.new_obj();
		doc.obj_add(root, "version", doc.new_sint(kManifestVersion));
		doc.obj_add(root, "playlist", doc.new_str(mPlaylistPath));
		doc.obj_add(root, "hash_algorithm", doc.new_str(CacheHashAlgorithmName(mContext->cacheHash)));

		Json::MutableVal tasks = doc.new_obj();
		for(const std::string *signaturePtr : signatures)
		{
			const std::string &signature = *signaturePtr;
			const StoredCacheEntry &entry = entries.at(signature);
			Json::MutableVal task = doc.new_obj();
			doc.obj_add(task, "action", doc.new_str(entry.actionName));
			doc.obj_add(task, "key", doc.new_str(entry.playlistKey));
			doc.obj_add(task, "world_in", doc.new_str(hex64(entry.worldIn)));
			doc.obj_add(task, "world_out", doc.new_str(hex64(entry.worldOut)));
			doc.obj_add(task, "timestamp", doc.new_str(entry.timestamp));
			doc.obj_add(tasks, signature, task);
		}
		doc.obj_add(root, "tasks", tasks);
		doc.set_root(root);

		result = write_json_doc_to_file(doc, tempPath.c_str());
	}
	else
	{
		CFMutableDict root;
		root.SetValue(CFSTR("version"), (int64_t)kManifestVersion);
		root.SetValue(CFSTR("playlist"), CFStr(mPlaylistPath));
		root.SetValue(CFSTR("hash_algorithm"), CFStr(CacheHashAlgorithmName(mContext->cacheHash)));

		CFMutableDict tasks;
		for(const std::string *signaturePtr : signatures)
		{
			const std::string &signature = *signaturePtr;
			const StoredCacheEntry &entry = entries.at(signature);
			CFMutableDict task;
			task.SetValue(CFSTR("action"), CFStr(entry.actionName));
			task.SetValue(CFSTR("key"), CFStr(entry.playlistKey));
			task.SetValue(CFSTR("world_in"), CFStr(hex64(entry.worldIn)));
			task.SetValue(CFSTR("world_out"), CFStr(hex64(entry.worldOut)));
			task.SetValue(CFSTR("timestamp"), CFStr(entry.timestamp));
			tasks.SetValue(CFStr(signature), (CFTypeRef)(CFMutableDictionaryRef)task);
		}
		root.SetValue(CFSTR("tasks"), (CFTypeRef)(CFMutableDictionaryRef)tasks);

		result = write_plist_dict_to_file(root, tempPath);
	}

	if(result == EXIT_SUCCESS)
	{
		// Atomic against concurrent readers: they see either the old inode or the new one,
		// never a partial write. Not durable against a crash - there is no fsync here -
		// but a truncated or zero-length manifest is loaded as empty, so the worst case
		// is a full re-execution.
		if(rename(tempPath.c_str(), mManifestPath.c_str()) != 0)
		{
			LogError("error: cannot replace cache manifest: %s\n", mManifestPath.c_str());
			result = EXIT_FAILURE;
			// The rename can fail for reasons that leave the temp file intact (ENOSPC,
			// EROFS, the manifest path replaced by a directory); clean it up here too or
			// it stays in the cache directory forever.
			unlink(tempPath.c_str());
		}
	}
	else
	{
		unlink(tempPath.c_str());
	}

	// lockGuard releases the flock and closes the descriptor here.
	return (result == EXIT_SUCCESS);
}
