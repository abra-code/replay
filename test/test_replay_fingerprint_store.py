#!/usr/bin/env python3
"""
test_replay_fingerprint_store.py - the sidecar per-file hash memoization
(--cache-memo sidecar, replay/FingerprintStore.{h,cpp}).

The memo is invisible by design: it only decides whether a file's bytes are read
again, never what the cache concludes. What makes it testable is the verbose
summary line

    memo: <hits> hits, <computed> computed, store <path>

plus the store file itself, which this suite parses independently - header,
capacity, entry count and the crc32c trailer are all re-derived here rather than
taken on trust, so a format change that breaks a reader shows up as a failure.

Scenarios:
  1.  a cached run creates the store; the next run hits the memo for every file
  2.  the entry count tracks the number of distinct files across runs
  3.  a flipped byte inside the slots is caught: 0 hits, correct output, rebuilt
  4.  a chopped trailer is treated as an empty store, run still correct
  5.  a store from another machine is ignored
  6.  --cache-hash crc32c and blake3 keep separate stores, neither invalidating
      the other
  7.  --cache-memo off writes no store and no xattrs
  8.  --cache-memo xattr writes xattrs and no store
  9.  --cache-memo-refresh ignores the memo and rewrites it correctly
  10. --dry-run reads the store and leaves it byte-identical; a cold dry run
      creates nothing; and --dry-run --cache-memo xattr writes no xattr and does
      not disturb a read-only input's mode
  11. touch -r: a same-size rewrite with a restored mtime still re-runs the task
      under "sidecar", and is a wrong skip under "xattr" - the headline
      correctness difference between the two backends, pinned deliberately
  12. many concurrent tasks over a shared input tree: correct entry count, and
      the second run fully hits
  13. steady state writes nothing: an unchanged run leaves the store untouched

Usage: python3 test_replay_fingerprint_store.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

XATTR_NAMES = ("public.fingerprint.crc32c", "public.fingerprint.blake3")

# Mirrors replay/FingerprintStore.cpp. Little-endian, no padding: the structs are
# laid out so that every field is naturally aligned.
FP_HEADER     = struct.Struct("<QIIQQQ16s8s")   # 64 bytes
FP_TRAILER    = struct.Struct("<QII")           # 16 bytes
HEADER_MAGIC  = 0x01535046594C5052              # "RPLYFPS\1"
TRAILER_MAGIC = 0x01545046594C5052              # "RPLYFPT\1"
SLOT_SIZE     = 32
# magic 0, version 8, hashAlgo 12, capacity 16, count 24, runCounter 32, hostUuid 40.
HOSTUUID_OFF  = 40

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


def run(args: list, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(REPLAY)] + [str(a) for a in args],
        capture_output=True, text=True, timeout=timeout,
    )


def summary(proc: subprocess.CompletedProcess) -> tuple:
    """'cache: N hits, M executed, K failed'. (-1,-1,-1) if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("cache: ") and " hits, " in line:
            parts = line.split()
            return (int(parts[1]), int(parts[3]), int(parts[5]))
    return (-1, -1, -1)


def memo(proc: subprocess.CompletedProcess) -> tuple:
    """'memo: N hits, M computed, store PATH', printed only under --verbose.
    (-1, -1, '') if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("memo: ") and " hits, " in line:
            parts = line.split()
            return (int(parts[1]), int(parts[3]), parts[6])
    return (-1, -1, "")


# --- independent crc32c, so the trailer is verified rather than assumed --------
# Castagnoli, reflected, init 0xFFFFFFFF, final xor 0xFFFFFFFF - the convention
# fast-crc32's crc32_impl(0, ...) implements.
_CRC32C_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (0x82F63B78 if (_c & 1) else 0)
    _CRC32C_TABLE.append(_c)


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _CRC32C_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


def store_paths(cache: Path) -> list:
    if not cache.exists():
        return []
    return sorted(cache.glob("fingerprints-*.bin"))


def store_path(cache: Path):
    paths = store_paths(cache)
    return paths[0] if len(paths) == 1 else None


class Store:
    """A parsed store file. valid is False when it fails its own format rules."""

    def __init__(self, path: Path):
        self.path = path
        self.raw = path.read_bytes()
        self.valid = False
        self.count = -1
        self.capacity = -1
        self.run_counter = -1
        self.host = b""
        self.crc_ok = False

        if len(self.raw) < FP_HEADER.size + FP_TRAILER.size:
            return
        magic, version, algo, capacity, count, runs, host, _res = \
            FP_HEADER.unpack_from(self.raw, 0)
        if magic != HEADER_MAGIC:
            return
        body = len(self.raw) - FP_HEADER.size - FP_TRAILER.size
        if (body % SLOT_SIZE) != 0 or (body // SLOT_SIZE) != capacity:
            return
        tmagic, stored_crc, _ = FP_TRAILER.unpack_from(self.raw, len(self.raw) - FP_TRAILER.size)
        if tmagic != TRAILER_MAGIC:
            return
        self.crc_ok = (crc32c(self.raw[:len(self.raw) - FP_TRAILER.size]) == stored_crc)
        self.version = version
        self.algo = algo
        self.capacity = capacity
        self.count = count
        self.run_counter = runs
        self.host = host
        self.valid = True

    def live_slots(self) -> int:
        """Non-empty slots, counted from the table itself rather than the header's
        advisory count - the two must agree."""
        live = 0
        for i in range(self.capacity):
            offset = FP_HEADER.size + (i * SLOT_SIZE)
            (file_key,) = struct.unpack_from("<Q", self.raw, offset)
            if file_key != 0:
                live += 1
        return live


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def xattr_names(path: Path) -> list:
    proc = subprocess.run(["/usr/bin/xattr", str(path)],
                          capture_output=True, text=True, timeout=10)
    return proc.stdout.split()


def has_fingerprint_xattr(path: Path) -> bool:
    return any(n in xattr_names(path) for n in XATTR_NAMES)


def make_tree(d: Path, count: int = 3, shared: bool = False) -> tuple:
    """count independent copy tasks, each with one input and one output. With
    shared=True every task also declares one common header, so the same file is
    fingerprinted by every task - the duplicate-record path."""
    src = d / "src"
    out = d / "out"
    src.mkdir()
    out.mkdir()
    steps = []
    inputs = []
    for i in range(count):
        source = src / f"in{i}.txt"
        source.write_text(f"payload {i} v1")
        inputs.append(source)
        declared = [str(source)]
        if shared:
            declared.append(str(src / "common.h"))
        steps.append({
            "action": "execute", "tool": "/bin/sh",
            "arguments": ["-c", f"cat {source} > {out}/out{i}.txt"],
            "inputs": declared,
            "outputs": [str(out / f"out{i}.txt")],
        })
    if shared:
        (src / "common.h").write_text("#define SHARED 1\n")
        inputs.append(src / "common.h")
    playlist = d / "pl.json"
    playlist.write_text(json.dumps(steps))
    return playlist, src, out, inputs


def distinct_files(count: int, shared: bool = False) -> int:
    """Inputs plus outputs: what the store should hold after a full run."""
    return (count * 2) + (1 if shared else 0)


def test_created_and_hits():
    print("\n=== Scenario 1: the store is created, and the next run hits it ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        r1 = run(args + [playlist])
        check("cold run exits 0", r1.returncode == 0, r1.stderr)
        check("cold run executed every task", summary(r1) == (0, 3, 0), r1.stderr)
        path = store_path(cache)
        check("exactly one store file was created", path is not None,
              str(store_paths(cache)))
        check("cold run computed and never hit", memo(r1)[0] == 0 and memo(r1)[1] > 0,
              f"{memo(r1)} in: {r1.stderr}")
        check("the memo line names the store that exists",
              path is not None and memo(r1)[2] == str(path), f"{memo(r1)} vs {path}")

        store = Store(path)
        check("the store parses as a valid image", store.valid, str(path))
        check("the trailer checksum verifies independently", store.crc_ok, str(path))

        r2 = run(args + [playlist])
        check("warm run hit every task", summary(r2) == (3, 0, 0), r2.stderr)
        check("warm run hit the memo and computed nothing",
              memo(r2)[0] > 0 and memo(r2)[1] == 0, f"{memo(r2)} in: {r2.stderr}")
        check("outputs are correct", (out / "out2.txt").read_text() == "payload 2 v1")


def test_entry_count():
    print("\n=== Scenario 2: the entry count tracks the distinct files ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 4)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache]

        run(args + [playlist])
        store = Store(store_path(cache))
        expected = distinct_files(4)
        check("the store holds one entry per distinct file",
              store.count == expected, f"count={store.count} expected={expected}")
        check("the header count agrees with the live slots",
              store.live_slots() == store.count,
              f"live={store.live_slots()} header={store.count}")
        check("the table is a power of two at or above the 1024 minimum",
              store.capacity >= 1024 and (store.capacity & (store.capacity - 1)) == 0,
              str(store.capacity))

        # A new file for a new task: the entry count grows by exactly two
        # (its input and its output), the rest carry forward as survivors.
        steps = json.loads(playlist.read_text())
        extra = src / "in_extra.txt"
        extra.write_text("extra payload")
        steps.append({
            "action": "execute", "tool": "/bin/sh",
            "arguments": ["-c", f"cat {extra} > {out}/out_extra.txt"],
            "inputs": [str(extra)], "outputs": [str(out / "out_extra.txt")],
        })
        playlist.write_text(json.dumps(steps))

        run(args + [playlist])
        grown = Store(store_path(cache))
        check("adding one task adds exactly its two files",
              grown.count == expected + 2, f"count={grown.count} expected={expected + 2}")
        check("the rewrite bumped the run counter",
              grown.run_counter == store.run_counter + 1,
              f"{store.run_counter} -> {grown.run_counter}")


def test_corruption():
    print("\n=== Scenario 3: a flipped byte inside the slots is caught ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        path = store_path(cache)
        original = Store(path)

        # Flip one bit well inside the slot area. Structurally the file is still
        # a perfectly good store - only the checksum can tell.
        raw = bytearray(path.read_bytes())
        offset = FP_HEADER.size + 40
        raw[offset] ^= 0x40
        path.write_bytes(bytes(raw))
        check("the corrupted image no longer verifies", not Store(path).crc_ok, str(path))

        r = run(args + [playlist])
        check("the run after corruption exits 0", r.returncode == 0, r.stderr)
        check("a corrupt store yields no memo hits", memo(r)[0] == 0,
              f"{memo(r)} in: {r.stderr}")
        check("the cache still hits: the memo never changes the verdict",
              summary(r) == (3, 0, 0), r.stderr)
        check("outputs are still correct", (out / "out1.txt").read_text() == "payload 1 v1")

        rebuilt = Store(path)
        check("the store was rebuilt wholesale", rebuilt.valid and rebuilt.crc_ok, str(path))
        check("the rebuilt store holds every file again",
              rebuilt.count == original.count,
              f"{rebuilt.count} vs {original.count}")

        r2 = run(args + [playlist])
        check("and the run after that hits the memo again", memo(r2)[0] > 0,
              f"{memo(r2)} in: {r2.stderr}")


def test_truncation():
    print("\n=== Scenario 4: a chopped trailer is treated as an empty store ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 2)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        path = store_path(cache)
        raw = path.read_bytes()
        path.write_bytes(raw[:-8])  # half the trailer gone: size is no longer whole slots

        r = run(args + [playlist])
        check("the run over a truncated store exits 0", r.returncode == 0, r.stderr)
        check("a truncated store yields no memo hits", memo(r)[0] == 0,
              f"{memo(r)} in: {r.stderr}")
        check("the cache still hits", summary(r) == (2, 0, 0), r.stderr)
        check("the store was rebuilt and verifies", Store(path).crc_ok, str(path))


def test_foreign_host():
    print("\n=== Scenario 5: a store from another machine is ignored ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 2)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        path = store_path(cache)
        this_host = Store(path).host
        check("this machine's host uuid was recorded",
              this_host != b"\xEE" * 16 and len(this_host) == 16, repr(this_host))

        raw = bytearray(path.read_bytes())
        raw[HOSTUUID_OFF:HOSTUUID_OFF + 16] = b"\xEE" * 16
        # Repair the checksum, so ONLY the host check can reject it.
        body = bytes(raw[:len(raw) - FP_TRAILER.size])
        FP_TRAILER.pack_into(raw, len(raw) - FP_TRAILER.size,
                             TRAILER_MAGIC, crc32c(body), 0)
        path.write_bytes(bytes(raw))
        patched = Store(path)
        check("the patched image still verifies its checksum", patched.crc_ok, str(path))
        check("the patch really landed on hostUuid", patched.host == b"\xEE" * 16,
              repr(patched.host))

        r = run(args + [playlist])
        check("a foreign host's store yields no memo hits", memo(r)[0] == 0,
              f"{memo(r)} in: {r.stderr}")
        check("the cache still hits", summary(r) == (2, 0, 0), r.stderr)
        rebuilt = Store(path)
        check("the store was rebuilt under this machine's host",
              rebuilt.host == this_host, f"{rebuilt.host!r} vs {this_host!r}")
        check("the rebuilt store verifies and holds the files again",
              rebuilt.crc_ok and rebuilt.count == distinct_files(2),
              f"crc_ok={rebuilt.crc_ok} count={rebuilt.count}")


def test_algorithm_split():
    print("\n=== Scenario 6: crc32c and blake3 keep separate stores ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 2)
        cache = d / "cache"

        r1 = run(["--cache", "--cache-dir", cache, "-v", playlist])
        crc_store = store_path(cache)
        check("crc32c run created its store", crc_store is not None, str(store_paths(cache)))
        crc_digest = digest(crc_store)

        r2 = run(["--cache", "--cache-dir", cache, "--cache-hash", "blake3", "-v", playlist])
        check("blake3 run exits 0", r2.returncode == 0, r2.stderr)
        check("two store files now coexist", len(store_paths(cache)) == 2,
              str(store_paths(cache)))
        check("the blake3 run started with an empty memo", memo(r2)[0] == 0,
              f"{memo(r2)} in: {r2.stderr}")
        check("the crc32c store was left untouched", digest(crc_store) == crc_digest,
              str(crc_store))

        r3 = run(["--cache", "--cache-dir", cache, "-v", playlist])
        check("switching back to crc32c hits its own store", memo(r3)[0] > 0,
              f"{memo(r3)} in: {r3.stderr}")


def test_memo_off():
    print("\n=== Scenario 7: --cache-memo off writes no store and no xattrs ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, inputs = make_tree(d, 2)
        cache = d / "cache"
        args = ["--cache-memo", "off", "--cache-dir", cache, "-v"]

        r1 = run(args + [playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("no store file", store_paths(cache) == [], str(store_paths(cache)))
        check("no memo summary line", memo(r1) == (-1, -1, ""), r1.stderr)
        check("no fingerprint xattr on the input",
              not has_fingerprint_xattr(inputs[0]), str(xattr_names(inputs[0])))

        r2 = run(args + [playlist])
        check("the cache still hits without any memo", summary(r2) == (2, 0, 0), r2.stderr)


def test_memo_xattr():
    print("\n=== Scenario 8: --cache-memo xattr writes xattrs and no store ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, inputs = make_tree(d, 2)
        cache = d / "cache"
        args = ["--cache-memo", "xattr", "--cache-dir", cache, "-v"]

        r1 = run(args + [playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("no store file", store_paths(cache) == [], str(store_paths(cache)))
        check("no memo summary line", memo(r1) == (-1, -1, ""), r1.stderr)
        check("the input gained a fingerprint xattr",
              has_fingerprint_xattr(inputs[0]), str(xattr_names(inputs[0])))

        r2 = run(args + [playlist])
        check("the cache hits with the xattr memo", summary(r2) == (2, 0, 0), r2.stderr)


def test_memo_refresh():
    print("\n=== Scenario 9: --cache-memo-refresh ignores and rewrites the memo ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        before = Store(store_path(cache))

        r = run(args + ["--cache-memo-refresh", playlist])
        check("the refresh run exits 0", r.returncode == 0, r.stderr)
        check("the refresh run took no memo hit", memo(r)[0] == 0,
              f"{memo(r)} in: {r.stderr}")
        check("the refresh run computed every hash", memo(r)[1] > 0,
              f"{memo(r)} in: {r.stderr}")
        check("the cache verdict is unaffected by a memo refresh",
              summary(r) == (3, 0, 0), r.stderr)

        after = Store(store_path(cache))
        check("the rewritten store verifies", after.crc_ok, str(store_path(cache)))
        check("the rewritten store holds the same files",
              after.count == before.count, f"{after.count} vs {before.count}")

        r2 = run(args + [playlist])
        check("the next normal run hits the refreshed memo", memo(r2)[0] > 0,
              f"{memo(r2)} in: {r2.stderr}")


def test_dry_run():
    print("\n=== Scenario 10: --dry-run reads the store and never writes it ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 2)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        path = store_path(cache)
        before_digest = digest(path)
        before_mtime = path.stat().st_mtime_ns

        r = run(args + ["--dry-run", playlist])
        check("the dry run exits 0", r.returncode == 0, r.stderr)
        check("the dry run reports HIT", "[cache] HIT" in (r.stdout + r.stderr),
              r.stdout + r.stderr)
        # The whole point of the sidecar's dry-run behavior: the xattr backend has
        # to turn the memo off for a dry run, because it has no read-only mode and
        # any file that missed would be written to - so it re-hashes everything to
        # produce its report. This one just reads. Scenario 10c pins that arm.
        check("the dry run still used the memo", memo(r)[0] > 0,
              f"{memo(r)} in: {r.stderr}")
        check("the dry run computed nothing", memo(r)[1] == 0,
              f"{memo(r)} in: {r.stderr}")
        check("the store is byte-identical after the dry run",
              digest(path) == before_digest, str(path))
        check("the store's mtime is untouched",
              path.stat().st_mtime_ns == before_mtime, str(path))


def test_cold_dry_run_writes_nothing():
    print("\n=== Scenario 10b: a cold --dry-run creates no store ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 2)
        cache = d / "cache"

        r = run(["--cache", "--cache-dir", cache, "--dry-run", "-v", playlist])
        check("the cold dry run exits 0", r.returncode == 0, r.stderr)
        check("the cold dry run reports MISS", "[cache] MISS" in (r.stdout + r.stderr),
              r.stdout + r.stderr)
        check("no cache directory was created", not cache.exists(), str(cache))


def test_dry_run_xattr_purity():
    print("\n=== Scenario 10c: --dry-run --cache-memo xattr writes nothing to the inputs ===")
    # The xattr backend has no read-only mode: a MISS writes the record, and on a
    # non-user-writable file it lchmods first. A dry run must therefore turn that
    # backend off wholesale rather than merely avoid saving, which is the one place
    # the two backends are handled differently. A cold cache makes every declared
    # file a miss, so this is the case that would write if the arm were dropped.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, inputs = make_tree(d, 2)
        cache = d / "cache"
        readonly = inputs[0]
        readonly.chmod(0o444)

        r = run(["--cache-memo", "xattr", "--cache-dir", cache, "--dry-run", "-v", playlist])
        check("the xattr dry run exits 0", r.returncode == 0, r.stderr)
        check("the xattr dry run reports MISS", "[cache] MISS" in (r.stdout + r.stderr),
              r.stdout + r.stderr)
        for source in inputs:
            check(f"no fingerprint xattr written to {source.name}",
                  not has_fingerprint_xattr(source), str(xattr_names(source)))
        check("the read-only input's mode is untouched",
              (readonly.stat().st_mode & 0o7777) == 0o444,
              oct(readonly.stat().st_mode & 0o7777))
        check("the xattr dry run creates no cache directory", not cache.exists(), str(cache))

        # And the same run without --dry-run does write them, so the check above is
        # pinning the dry-run arm rather than a backend that never writes at all.
        r2 = run(["--cache-memo", "xattr", "--cache-dir", cache, playlist])
        check("a real xattr run does write the memo", has_fingerprint_xattr(inputs[1]),
              str(xattr_names(inputs[1])))


def rewrite_preserving_mtime(path: Path, content: str) -> None:
    """A same-size rewrite whose mtime is then restored - what a timestamp-
    preserving tool, or plain `touch -r`, leaves behind. ctime cannot be put
    back: utimes() is itself an inode metadata change."""
    before = path.stat()
    assert len(content.encode()) == before.st_size, "the rewrite must keep the size"
    path.write_text(content)
    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))


def test_touch_r_regression():
    print("\n=== Scenario 11: touch -r - sidecar re-runs, xattr wrongly skips ===")
    # The headline correctness difference. Both halves are asserted on purpose:
    # the xattr behavior is a documented limitation, not an accident, and if it
    # ever changes this test should be the thing that says so.
    for backend, expect_rerun in (("sidecar", True), ("xattr", False)):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td).resolve()
            playlist, src, out, _ = make_tree(d, 1)
            cache = d / "cache"
            args = ["--cache-memo", backend, "--cache-dir", cache]
            source = src / "in0.txt"

            r1 = run(args + [playlist])
            check(f"[{backend}] run 1 executed", summary(r1) == (0, 1, 0), r1.stderr)
            check(f"[{backend}] output is v1", (out / "out0.txt").read_text() == "payload 0 v1")

            rewrite_preserving_mtime(source, "payload 0 v2")

            r2 = run(args + [playlist])
            executed = summary(r2) == (0, 1, 0)
            if expect_rerun:
                check(f"[{backend}] a mtime-preserving rewrite still re-runs the task",
                      executed, f"{summary(r2)} in: {r2.stderr}")
                check(f"[{backend}] the output was regenerated",
                      (out / "out0.txt").read_text() == "payload 0 v2",
                      (out / "out0.txt").read_text())
            else:
                check(f"[{backend}] wrongly skips, as documented",
                      summary(r2) == (1, 0, 0), f"{summary(r2)} in: {r2.stderr}")
                check(f"[{backend}] the stale output survives, as documented",
                      (out / "out0.txt").read_text() == "payload 0 v1",
                      (out / "out0.txt").read_text())


def test_concurrent_shared_tree():
    print("\n=== Scenario 12: many concurrent tasks over a shared input ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        count = 40
        playlist, src, out, _ = make_tree(d, count, shared=True)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        r1 = run(args + [playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("run 1 executed every task", summary(r1) == (0, count, 0), r1.stderr)

        store = Store(store_path(cache))
        expected = distinct_files(count, shared=True)
        check("the shared header is stored once, not once per task",
              store.count == expected, f"count={store.count} expected={expected}")
        check("the header count agrees with the live slots",
              store.live_slots() == store.count,
              f"live={store.live_slots()} header={store.count}")
        check("the store verifies after a concurrent run", store.crc_ok, str(store.path))
        check("the load factor stayed under 0.7",
              store.count <= (store.capacity * 7) // 10,
              f"count={store.count} capacity={store.capacity}")

        r2 = run(args + [playlist])
        check("run 2 hits every task", summary(r2) == (count, 0, 0), r2.stderr)
        check("run 2 computed nothing", memo(r2)[1] == 0, f"{memo(r2)} in: {r2.stderr}")
        check("run 2 hit the memo once per fingerprinted file, tasks included",
              memo(r2)[0] >= expected, f"{memo(r2)} expected at least {expected}")


def test_steady_state_writes_nothing():
    print("\n=== Scenario 13: an unchanged run leaves the store untouched ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        path = store_path(cache)
        first_digest = digest(path)
        first_mtime = path.stat().st_mtime_ns
        first_inode = path.stat().st_ino

        r2 = run(args + [playlist])
        check("run 2 hit everything", summary(r2) == (3, 0, 0), r2.stderr)
        check("run 2 left the store byte-identical", digest(path) == first_digest, str(path))
        check("run 2 did not even replace the inode",
              path.stat().st_ino == first_inode and path.stat().st_mtime_ns == first_mtime,
              str(path))

        r3 = run(args + [playlist])
        check("run 3 likewise", digest(path) == first_digest and
              path.stat().st_ino == first_inode, str(path))

        # A single changed file must still trigger exactly one rewrite.
        (src / "in1.txt").write_text("payload 1 v2 longer")
        r4 = run(args + [playlist])
        check("a changed file re-runs its task", summary(r4) == (2, 1, 0), r4.stderr)
        check("and the store was rewritten", digest(path) != first_digest, str(path))
        check("the rewritten store verifies", Store(path).crc_ok, str(path))


def main() -> int:
    if not REPLAY.exists():
        print(f"error: replay not found at {REPLAY}")
        return 1

    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print(" Testing replay sidecar fingerprint store")
    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print(f"replay: {REPLAY}")

    test_created_and_hits()
    test_entry_count()
    test_corruption()
    test_truncation()
    test_foreign_host()
    test_algorithm_split()
    test_memo_off()
    test_memo_xattr()
    test_memo_refresh()
    test_dry_run()
    test_cold_dry_run_writes_nothing()
    test_dry_run_xattr_purity()
    test_touch_r_regression()
    test_concurrent_shared_tree()
    test_steady_state_writes_nothing()

    print("\n========================================")
    print(f"  Passed: {_pass}  Failed: {_fail}")
    print("========================================")
    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
