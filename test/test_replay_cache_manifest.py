#!/usr/bin/env python3
"""
test_replay_cache_manifest.py — cache manifest lifecycle and --cache-* option plumbing.

At this stage no task is wrapped by the cache yet, so execution behavior must be
completely unchanged; only the manifest file and the new verbose/warning lines are new.

Scenarios:
  1. --cache writes a JSON manifest with the expected header fields, twice in a row
  2. --cache-format plist writes a binary plist manifest with the same fields
  3. --cache-hash blake3 is recorded in the manifest
  4. execution output is identical with and without --cache
  5. --cache is ignored with a warning in --no-dependency, stdin and server modes
  6. invalid --cache-format / --cache-hash / --cache-memo values are rejected
  7. --dry-run --cache writes no manifest
  8. --help documents the cache options

Usage: python3 test_replay_cache_manifest.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

_pass = 0
_fail = 0


def ok(name: str) -> None:
    global _pass
    _pass += 1
    print(f"  PASS: {name}")


def fail(name: str, reason: str = "") -> None:
    global _fail
    _fail += 1
    msg = f"  FAIL: {name}"
    if reason:
        msg += f"\n        {reason[:300]}"
    print(msg)


def check(name: str, condition: bool, reason: str = "") -> bool:
    if condition:
        ok(name)
        return True
    fail(name, reason)
    return False


def write_playlist(directory: Path) -> Path:
    """A trivial playlist: one directory and two files created inside it."""
    out = directory / "out"
    playlist = [
        {"action": "create", "directory": str(out)},
        {"action": "create", "file": str(out / "a.txt"), "content": "alpha"},
        {"action": "create", "file": str(out / "b.txt"), "content": "beta"},
    ]
    path = directory / "playlist.json"
    path.write_text(json.dumps(playlist))
    return path


def run(args: list, timeout: int = 30, stdin_data: str = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(REPLAY)] + [str(a) for a in args],
        input=stdin_data, capture_output=True, text=True, timeout=timeout,
    )


def manifests_in(cache_dir: Path) -> list:
    if not cache_dir.is_dir():
        return []
    return sorted(p for p in cache_dir.iterdir()
                  if ".replay-cache." in p.name
                  and not p.name.endswith(".lock")
                  and not p.name.endswith(".tmp"))


def seed_manifest(cache_dir: Path, playlist: Path, tasks: dict,
                  version: int = 1, hash_algorithm: str = "crc32c",
                  playlist_path: str = None, extra_args: list = ()) -> Path:
    """Write a manifest by hand so load/prune/carry logic can be tested before any
    task is actually wrapped by the cache."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    # Reproduce replay's manifest naming: blake3-16hex of the resolved playlist path.
    # Rather than reimplement blake3 here, let replay create the file and reuse its name.
    # The priming run may itself fail (some tests deliberately seed a broken playlist);
    # all that matters is that it produced a manifest whose name we can reuse.
    result = run(["--cache", "--cache-dir", cache_dir] + list(extra_args) + [playlist])
    found = manifests_in(cache_dir)
    assert found, f"priming run produced no manifest: {result.stderr[:300]}"
    manifest = found[0]
    data = {
        "version": version,
        "playlist": playlist_path if playlist_path is not None else str(playlist.resolve()),
        "hash_algorithm": hash_algorithm,
        "tasks": tasks,
    }
    manifest.write_text(json.dumps(data, indent=2))
    return manifest


def entry(action: str = "execute", key: str = "") -> dict:
    return {
        "action": action,
        "key": key,
        "world_in": "1111111111111111",
        "world_out": "2222222222222222",
        "timestamp": "2026-07-23T12:00:00",
    }


def loaded_count(stderr: str) -> int:
    for line in stderr.splitlines():
        if line.startswith("cache: loaded "):
            return int(line.split()[2])
    return -1


# ---------------------------------------------------------------------------
# Scenario 1: JSON manifest is created and rewritten on a second run
# ---------------------------------------------------------------------------

def test_json_manifest() -> None:
    print("\n--- Scenario 1: --cache writes a JSON manifest ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        result = run(["--cache", "--cache-dir", cache_dir, "--verbose", playlist])
        check("run 1 exits 0", result.returncode == 0, result.stderr[:300])
        check("run 1 created the output files",
              (td / "out" / "a.txt").read_text() == "alpha"
              and (td / "out" / "b.txt").read_text() == "beta")

        found = manifests_in(cache_dir)
        if not check("exactly one manifest file exists", len(found) == 1, str(found)):
            return

        manifest = found[0]
        check("manifest name ends with .replay-cache.json",
              manifest.name.endswith(".replay-cache.json"), manifest.name)

        data = json.loads(manifest.read_text())
        check("manifest has version 1", data.get("version") == 1, str(data)[:200])
        check("manifest records the resolved playlist path",
              data.get("playlist", "").endswith("playlist.json"), str(data.get("playlist")))
        check("manifest records hash_algorithm crc32c",
              data.get("hash_algorithm") == "crc32c", str(data.get("hash_algorithm")))
        check("manifest has a tasks object", isinstance(data.get("tasks"), dict), str(data)[:200])

        check("verbose run reports the loaded entry count",
              "cache: loaded" in result.stderr, result.stderr[:300])
        check("run reports the end-of-run summary",
              "hits," in result.stderr and "manifest" in result.stderr, result.stderr[:300])

        # Second run: the manifest must still parse and stay a single file.
        result2 = run(["--cache", "--cache-dir", cache_dir, playlist])
        check("run 2 exits 0", result2.returncode == 0, result2.stderr[:300])
        found2 = manifests_in(cache_dir)
        check("still exactly one manifest after run 2", len(found2) == 1, str(found2))
        json.loads(found2[0].read_text())
        ok("manifest still parses as JSON after run 2")
        check("no temp manifest left behind",
              not any(p.name.endswith(".tmp") for p in cache_dir.iterdir()),
              str(list(cache_dir.iterdir())))


# ---------------------------------------------------------------------------
# Scenario 2: plist manifest
# ---------------------------------------------------------------------------

def test_plist_manifest() -> None:
    print("\n--- Scenario 2: --cache-format plist ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        result = run(["--cache-format", "plist", "--cache-dir", cache_dir, playlist])
        check("exits 0", result.returncode == 0, result.stderr[:300])

        found = manifests_in(cache_dir)
        if not check("exactly one manifest file exists", len(found) == 1, str(found)):
            return
        check("manifest name ends with .replay-cache.plist",
              found[0].name.endswith(".replay-cache.plist"), found[0].name)

        with open(found[0], "rb") as f:
            data = plistlib.load(f)
        check("plist manifest has version 1", data.get("version") == 1, str(data)[:200])
        check("plist manifest records hash_algorithm",
              data.get("hash_algorithm") == "crc32c", str(data)[:200])
        check("plist manifest has a tasks dict", isinstance(data.get("tasks"), dict), str(data)[:200])

        # --cache-format alone must imply --cache.
        check("--cache-format implies --cache",
              "hits," in result.stderr, result.stderr[:300])


# ---------------------------------------------------------------------------
# Scenario 3: --cache-hash is recorded
# ---------------------------------------------------------------------------

def test_hash_algorithm_recorded() -> None:
    print("\n--- Scenario 3: --cache-hash blake3 ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        result = run(["--cache-hash", "blake3", "--cache-dir", cache_dir, playlist])
        check("exits 0", result.returncode == 0, result.stderr[:300])

        found = manifests_in(cache_dir)
        if not check("manifest created", len(found) == 1, str(found)):
            return
        data = json.loads(found[0].read_text())
        check("manifest records hash_algorithm blake3",
              data.get("hash_algorithm") == "blake3", str(data.get("hash_algorithm")))


# ---------------------------------------------------------------------------
# Scenario 4: execution behavior is unchanged by --cache
# ---------------------------------------------------------------------------

def test_execution_unchanged() -> None:
    print("\n--- Scenario 4: --cache does not change execution output ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        plain = run(["--verbose", playlist])

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cached = run(["--cache", "--cache-dir", td / "cache", "--verbose", playlist])

    check("both runs exit 0", plain.returncode == 0 and cached.returncode == 0,
          f"plain={plain.returncode} cached={cached.returncode}")

    def normalize(text: str) -> set:
        # Paths differ between the two temp dirs; compare the action names only.
        return {line.split("\t")[0] for line in text.splitlines() if line.startswith("[")}

    check("stdout action set is identical with and without --cache",
          normalize(plain.stdout) == normalize(cached.stdout),
          f"plain={normalize(plain.stdout)} cached={normalize(cached.stdout)}")

    cache_lines = [line for line in cached.stderr.splitlines() if line.startswith("cache:")]
    other_stderr = "\n".join(line for line in cached.stderr.splitlines()
                             if not line.startswith("cache:") and not line.startswith("memo:"))
    check("the only new stderr output is the cache: and memo: lines",
          other_stderr.strip() == plain.stderr.strip(),
          f"cached extra: {other_stderr[:200]} | plain: {plain.stderr[:200]}")
    check("cache lines were emitted", len(cache_lines) >= 1, cached.stderr[:300])


# ---------------------------------------------------------------------------
# Scenario 5: unsupported modes warn and disable the cache
# ---------------------------------------------------------------------------

def test_unsupported_modes() -> None:
    print("\n--- Scenario 5: --cache ignored in unsupported modes ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        cache_dir = td / "cache"
        # -p skips dependency analysis, so the steps must be independent of each other.
        flat = [{"action": "create", "file": str(td / "a.txt"), "content": "alpha"}]
        playlist = td / "flat.json"
        playlist.write_text(json.dumps(flat))

        result = run(["-p", "--cache", "--cache-dir", cache_dir, playlist])
        check("-p --cache exits 0", result.returncode == 0, result.stderr[:300])
        check("-p --cache warns that the cache is ignored",
              "--cache is ignored" in result.stderr and "--no-dependency" in result.stderr,
              result.stderr[:300])
        check("-p --cache writes no manifest", not manifests_in(cache_dir),
              str(manifests_in(cache_dir)))

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        cache_dir = Path(td) / "cache"
        result = run(["--cache", "--cache-dir", cache_dir], stdin_data="[echo]\thello\n")
        check("stdin --cache exits 0", result.returncode == 0, result.stderr[:300])
        check("stdin --cache warns that the cache is ignored",
              "--cache is ignored" in result.stderr and "stdin" in result.stderr,
              result.stderr[:300])
        check("stdin --cache still executes the action", "hello" in result.stdout,
              result.stdout[:200])
        check("stdin --cache writes no manifest", not manifests_in(cache_dir),
              str(manifests_in(cache_dir)))


# ---------------------------------------------------------------------------
# Scenario 6: invalid option values are rejected
# ---------------------------------------------------------------------------

def test_invalid_option_values() -> None:
    print("\n--- Scenario 6: invalid --cache-* values ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)

        for option, value, expected in [
            ("--cache-format", "yaml", "--cache-format"),
            ("--cache-hash", "md5", "--cache-hash"),
            ("--cache-memo", "maybe", "--cache-memo"),
        ]:
            result = run([option, value, playlist])
            check(f"{option} {value} exits non-zero", result.returncode != 0,
                  f"rc={result.returncode}")
            check(f"{option} {value} explains the valid values",
                  expected in result.stderr, result.stderr[:200])
            check(f"{option} {value} does not execute the playlist",
                  not (td / "out").exists(), "output directory was created")


# ---------------------------------------------------------------------------
# Scenario 7: --dry-run writes no manifest
# ---------------------------------------------------------------------------

def test_dry_run_writes_nothing() -> None:
    print("\n--- Scenario 7: --dry-run --cache writes no manifest ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        result = run(["--dry-run", "--cache", "--cache-dir", cache_dir, playlist])
        check("exits 0", result.returncode == 0, result.stderr[:300])
        check("no manifest written", not manifests_in(cache_dir), str(manifests_in(cache_dir)))
        check("no files created", not (td / "out").exists(), "output directory was created")


# ---------------------------------------------------------------------------
# Scenario 8: help text
# ---------------------------------------------------------------------------

def test_help_lists_cache_options() -> None:
    print("\n--- Scenario 8: --help documents the cache options ---")

    result = run(["--help"])
    for flag in ["--cache", "--cache-dir", "--cache-format", "--cache-hash",
                 "--cache-refresh", "--cache-env", "--cache-memo", "--cache-memo-refresh"]:
        check(f"help mentions {flag}", flag in result.stdout, "")


# ---------------------------------------------------------------------------
# Scenario 9: prune and carry semantics
# ---------------------------------------------------------------------------

def test_prune_and_carry() -> None:
    print("\n--- Scenario 9: pruning is scoped to the processed playlist key ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        out = td / "out"
        steps = [{"action": "create", "directory": str(out)}]
        playlist = td / "keyed.json"
        playlist.write_text(json.dumps({"KeyA": steps, "KeyB": steps}))
        cache_dir = td / "cache"

        # Seed one entry per key. None of their signatures can be seen this run
        # (no task is wrapped yet), so KeyA's entry is the only prune candidate.
        manifest = seed_manifest(cache_dir, playlist, {
            "aaaaaaaaaaaaaaaa": entry(key="KeyA"),
            "bbbbbbbbbbbbbbbb": entry(key="KeyB"),
            "cccccccccccccccc": entry(key=""),
        }, extra_args=["--playlist-key", "KeyA"])

        result = run(["--cache", "--cache-dir", cache_dir, "--playlist-key", "KeyA",
                      "--verbose", playlist])
        check("keyed run exits 0", result.returncode == 0, result.stderr[:300])
        check("all three seeded entries were loaded", loaded_count(result.stderr) == 3,
              result.stderr[:300])

        tasks = json.loads(manifest.read_text())["tasks"]
        check("entry for the processed key was pruned",
              "aaaaaaaaaaaaaaaa" not in tasks, str(sorted(tasks)))
        check("entry for an unprocessed key was carried",
              "bbbbbbbbbbbbbbbb" in tasks, str(sorted(tasks)))
        check("entry for the root-array key was carried",
              "cccccccccccccccc" in tasks, str(sorted(tasks)))
        check("carried entry keeps its fingerprints verbatim",
              tasks.get("bbbbbbbbbbbbbbbb", {}).get("world_in") == "1111111111111111"
              and tasks.get("bbbbbbbbbbbbbbbb", {}).get("world_out") == "2222222222222222",
              str(tasks.get("bbbbbbbbbbbbbbbb")))


def test_no_prune_when_build_truncated() -> None:
    print("\n--- Scenario 9b: --stop-on-error truncating the build disables pruning ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        # Step 1 fails at declaration time (undefined variable), so with -e the
        # remaining steps are never examined and their entries must survive.
        playlist_data = [
            {"action": "create", "file": str(td / "${REPLAY_UNDEFINED_VAR_XYZ}.txt"), "content": "x"},
            {"action": "create", "file": str(td / "later.txt"), "content": "y"},
        ]
        playlist = td / "broken.json"
        playlist.write_text(json.dumps(playlist_data))
        cache_dir = td / "cache"

        manifest = seed_manifest(cache_dir, playlist, {"dddddddddddddddd": entry(key="")})

        result = run(["--cache", "--cache-dir", cache_dir, "--stop-on-error", playlist])
        tasks = json.loads(manifest.read_text())["tasks"]
        check("entries survive a truncated graph build",
              "dddddddddddddddd" in tasks,
              f"tasks={sorted(tasks)} rc={result.returncode} stderr={result.stderr[:200]}")


# ---------------------------------------------------------------------------
# Scenario 10: manifests that must be discarded wholesale
# ---------------------------------------------------------------------------

def test_manifest_invalidation() -> None:
    print("\n--- Scenario 10: version / hash-algorithm / playlist mismatch ---")

    cases = [
        ("version mismatch",  dict(version=99)),
        ("hash algo mismatch", dict(hash_algorithm="blake3")),
        ("playlist mismatch",  dict(playlist_path="/somewhere/else/other.json")),
    ]
    for name, kwargs in cases:
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            playlist = write_playlist(td)
            cache_dir = td / "cache"
            manifest = seed_manifest(cache_dir, playlist,
                                     {"eeeeeeeeeeeeeeee": entry()}, **kwargs)

            result = run(["--cache", "--cache-dir", cache_dir, "--verbose", playlist])
            check(f"{name}: exits 0", result.returncode == 0, result.stderr[:300])
            check(f"{name}: all entries discarded", loaded_count(result.stderr) == 0,
                  result.stderr[:300])
            tasks = json.loads(manifest.read_text())["tasks"]
            check(f"{name}: manifest rebuilt without the stale entry",
                  "eeeeeeeeeeeeeeee" not in tasks, str(sorted(tasks)))


def test_matching_manifest_is_loaded() -> None:
    print("\n--- Scenario 10b: a matching manifest is actually read back ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"
        seed_manifest(cache_dir, playlist,
                      {"ffffffffffffffff": entry(), "0000000000000000": entry()})

        result = run(["--cache", "--cache-dir", cache_dir, "--verbose", playlist])
        check("both seeded entries loaded", loaded_count(result.stderr) == 2,
              result.stderr[:300])


# ---------------------------------------------------------------------------
# Scenario 11: corrupt manifests are disposable, never fatal and never noisy
# ---------------------------------------------------------------------------

def test_corrupt_manifests() -> None:
    print("\n--- Scenario 11: corrupt / truncated manifests ---")

    corruptions = [
        ("truncated json", b"not json {"),
        ("empty file", b""),
        ("json array root", b"[1, 2, 3]"),
    ]
    for name, content in corruptions:
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            playlist = write_playlist(td)
            cache_dir = td / "cache"
            manifest = seed_manifest(cache_dir, playlist, {})
            manifest.write_bytes(content)

            result = run(["--cache", "--cache-dir", cache_dir, playlist])
            check(f"{name}: exits 0", result.returncode == 0, result.stderr[:300])
            check(f"{name}: no error printed",
                  "Error" not in result.stderr and "error" not in result.stderr,
                  result.stderr[:300])
            check(f"{name}: manifest rewritten as valid JSON",
                  json.loads(manifest.read_text()).get("version") == 1,
                  manifest.read_text()[:200])

    # Same for plist, which parses through CoreFoundation: a non-dictionary root
    # must not be blindly cast (that aborts the process).
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"
        run(["--cache-format", "plist", "--cache-dir", cache_dir, playlist])
        manifest = manifests_in(cache_dir)[0]

        with open(manifest, "wb") as f:
            plistlib.dump(["not", "a", "dict"], f, fmt=plistlib.FMT_BINARY)
        result = run(["--cache-format", "plist", "--cache-dir", cache_dir, playlist])
        check("plist array root: exits 0 (no abort)", result.returncode == 0,
              f"rc={result.returncode} stderr={result.stderr[:300]}")

        manifest.write_bytes(b"\x00\x01\x02 not a plist at all")
        result = run(["--cache-format", "plist", "--cache-dir", cache_dir, playlist])
        check("garbage plist: exits 0", result.returncode == 0,
              f"rc={result.returncode} stderr={result.stderr[:300]}")


def test_plist_round_trip() -> None:
    print("\n--- Scenario 11b: plist manifests are loaded back ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        run(["--cache-format", "plist", "--cache-dir", cache_dir, playlist])
        manifest = manifests_in(cache_dir)[0]
        with open(manifest, "wb") as f:
            plistlib.dump({
                "version": 1,
                "playlist": str(playlist.resolve()),
                "hash_algorithm": "crc32c",
                # Tagged with a key this run does not process, so it must be carried
                # rather than pruned - which is what proves it was read back.
                "tasks": {"1234567812345678": entry(key="OtherKey")},
            }, f, fmt=plistlib.FMT_BINARY)

        result = run(["--cache-format", "plist", "--cache-dir", cache_dir,
                      "--verbose", playlist])
        check("plist entry loaded back", loaded_count(result.stderr) == 1,
              result.stderr[:300])
        with open(manifest, "rb") as f:
            tasks = plistlib.load(f)["tasks"]
        check("plist entry carried through the round trip",
              tasks.get("1234567812345678", {}).get("world_in") == "1111111111111111",
              str(tasks)[:200])


# ---------------------------------------------------------------------------
# Scenario 12: remaining option and mode coverage
# ---------------------------------------------------------------------------

def test_valid_option_values_run() -> None:
    print("\n--- Scenario 12: valid --cache-* values execute normally ---")

    variants = [
        ["--cache-refresh"],
        ["--cache", "--cache-env", "HOME"],
        ["--cache", "--cache-env", "HOME", "--cache-env", "PATH"],
        ["--cache-memo", "sidecar"],
        ["--cache-memo", "xattr"],
        ["--cache-memo", "off"],
        ["--cache-memo-refresh"],
    ]
    for extra in variants:
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            playlist = write_playlist(td)
            cache_dir = td / "cache"
            result = run(extra + ["--cache-dir", cache_dir, playlist])
            label = " ".join(extra)
            check(f"{label}: exits 0", result.returncode == 0, result.stderr[:300])
            check(f"{label}: manifest written", len(manifests_in(cache_dir)) == 1,
                  str(manifests_in(cache_dir)))
            check(f"{label}: playlist executed",
                  (td / "out" / "a.txt").exists(), "output missing")


def test_remaining_unsupported_modes() -> None:
    print("\n--- Scenario 12b: serial and server modes ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        result = run(["-s", "--cache", "--cache-dir", cache_dir, playlist])
        check("-s --cache exits 0", result.returncode == 0, result.stderr[:300])
        check("-s --cache is supported: no warning",
              "--cache is ignored" not in result.stderr, result.stderr[:300])
        check("-s --cache writes a manifest", len(manifests_in(cache_dir)) == 1,
              str(manifests_in(cache_dir)))
        check("-s --cache executes the playlist",
              (td / "out" / "a.txt").exists(), "output missing")

        # Serial dispatch never consults analyzeDependencies, so -p must not
        # disable the cache in serial mode.
        result = run(["-s", "-p", "--cache", "--cache-dir", cache_dir, playlist])
        check("-s -p --cache caches without a warning",
              result.returncode == 0 and "--cache is ignored" not in result.stderr,
              result.stderr[:300])

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"
        result = run(["--mcp-server", "--cache", "--cache-dir", cache_dir, playlist],
                     stdin_data="")
        check("--mcp-server --cache warns",
              "--cache is ignored" in result.stderr and "--mcp-server" in result.stderr,
              result.stderr[:300])


def test_multiple_playlist_keys() -> None:
    print("\n--- Scenario 12c: two --playlist-key in one invocation ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        first = [{"action": "create", "file": str(td / "one.txt"), "content": "1"}]
        second = [{"action": "create", "file": str(td / "two.txt"), "content": "2"}]
        playlist = td / "multi.json"
        playlist.write_text(json.dumps({"First": first, "Second": second}))
        cache_dir = td / "cache"

        result = run(["--cache", "--cache-dir", cache_dir,
                      "--playlist-key", "First", "--playlist-key", "Second", playlist])
        check("exits 0", result.returncode == 0, result.stderr[:300])
        check("both keys executed",
              (td / "one.txt").exists() and (td / "two.txt").exists(), "outputs missing")
        check("both sessions share one manifest file", len(manifests_in(cache_dir)) == 1,
              str(manifests_in(cache_dir)))
        check("one summary line per key",
              sum(1 for line in result.stderr.splitlines() if line.startswith("cache: ")
                  and "hits," in line) == 2,
              result.stderr[:300])
        json.loads(manifests_in(cache_dir)[0].read_text())
        ok("manifest still parses after two sequential sessions")


def test_manifest_is_stable() -> None:
    print("\n--- Scenario 12d: an unchanged cache produces a byte-identical manifest ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"
        seed_manifest(cache_dir, playlist, {
            "1111aaaa2222bbbb": entry(),
            "3333cccc4444dddd": entry(),
            "5555eeee6666ffff": entry(),
        })
        manifest = manifests_in(cache_dir)[0]

        run(["--cache", "--cache-dir", cache_dir, playlist])
        first = manifest.read_bytes()
        run(["--cache", "--cache-dir", cache_dir, playlist])
        second = manifest.read_bytes()
        check("manifest bytes are identical across two runs", first == second,
              f"{first[:120]!r} vs {second[:120]!r}")


def test_concurrent_processes() -> None:
    print("\n--- Scenario 12e: concurrent replay processes on one playlist ---")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        playlist = write_playlist(td)
        cache_dir = td / "cache"

        procs = [subprocess.Popen(
            [str(REPLAY), "--cache", "--cache-dir", str(cache_dir), str(playlist)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(6)]
        codes = [p.wait(timeout=60) for p in procs]

        check("all concurrent runs exit 0", all(c == 0 for c in codes), str(codes))
        found = manifests_in(cache_dir)
        check("exactly one manifest survives", len(found) == 1, str(found))
        data = json.loads(found[0].read_text())
        check("manifest is valid after concurrent writes", data.get("version") == 1,
              found[0].read_text()[:200])
        leftovers = [p.name for p in cache_dir.iterdir() if p.name.endswith(".tmp")]
        check("no temp files left behind", not leftovers, str(leftovers))


def test_concurrent_keys_do_not_clobber() -> None:
    print("\n--- Scenario 12f: concurrent invocations on different playlist keys ---")

    # Two --playlist-key invocations of one playlist file share a single manifest. Each
    # loads it before its scheduler starts, so unless the read-modify-write happens under
    # the file lock the second writer publishes a manifest built from a pre-run snapshot
    # and silently drops the first writer's entries.
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        cache_dir = td / "cache"
        playlist = td / "keyed.json"
        playlist.write_text(json.dumps({
            "keyA": [{"action": "execute", "tool": "/bin/sh",
                      "arguments": ["-c", f"sleep 1; echo A > {td}/a.txt"],
                      "outputs": [str(td / "a.txt")]}],
            "keyB": [{"action": "execute", "tool": "/bin/sh",
                      "arguments": ["-c", f"sleep 1; echo B > {td}/b.txt"],
                      "outputs": [str(td / "b.txt")]}],
        }))

        procs = [subprocess.Popen(
            [str(REPLAY), "--cache", "--cache-dir", str(cache_dir),
             "--playlist-key", key, str(playlist)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for key in ("keyA", "keyB")]
        codes = [p.wait(timeout=60) for p in procs]
        check("both keyed runs exit 0", all(c == 0 for c in codes), str(codes))

        found = manifests_in(cache_dir)
        check("one manifest for the playlist file", len(found) == 1, str(found))
        tasks = json.loads(found[0].read_text()).get("tasks", {})
        keys = sorted(entry.get("key", "") for entry in tasks.values())
        check("neither key's entry was clobbered", keys == ["keyA", "keyB"], str(keys))

        # Both must now hit; a lost entry shows up here as an execution.
        for key in ("keyA", "keyB"):
            warm = run(["--cache", "--cache-dir", cache_dir, "--playlist-key", key, playlist])
            hits = [line for line in warm.stderr.splitlines()
                    if line.startswith("cache: 1 hits, 0 executed")]
            check(f"warm {key} hits", len(hits) == 1, warm.stderr)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

test_json_manifest()
test_plist_manifest()
test_hash_algorithm_recorded()
test_execution_unchanged()
test_unsupported_modes()
test_invalid_option_values()
test_dry_run_writes_nothing()
test_help_lists_cache_options()
test_prune_and_carry()
test_no_prune_when_build_truncated()
test_manifest_invalidation()
test_matching_manifest_is_loaded()
test_corrupt_manifests()
test_plist_round_trip()
test_valid_option_values_run()
test_remaining_unsupported_modes()
test_multiple_playlist_keys()
test_manifest_is_stable()
test_concurrent_processes()
test_concurrent_keys_do_not_clobber()

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
