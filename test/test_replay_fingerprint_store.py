#!/usr/bin/env python3
"""
test_replay_fingerprint_store.py - the sidecar per-file hash memoization
(--cache-memo sidecar, replay/FingerprintStore.{h,cpp}).

The memo is invisible by design: it only decides whether a file's bytes are read
again, never what the cache concludes. What makes it testable is the verbose
summary line

    memo: <hits> hits, <computed> computed, store <path>

plus the store's two files, which this suite parses independently - header,
capacity, entry count, the crc32c trailer and every journal batch checksum are
re-derived here rather than taken on trust, so a format change that breaks a
reader shows up as a failure.

Scenarios:
  1.  a cached run creates the store; the next run hits the memo for every file
  2.  the entry count tracks the number of distinct files across runs, with new
      files landing in the journal rather than rewriting the table
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
  13. steady state writes nothing: an unchanged run leaves neither file touched,
      and one changed file writes a journal batch instead of the whole table
  14. a journal torn by a crash is repaired without rewriting the table, and the
      batches that did verify are carried into the replacement
  15. a batch left behind for a superseded table image is dropped, not overlaid
  16. exceeding the journal's budget folds it back into the table and clears it,
      and the records that lived only in the journal survive that fold
  17. a table too full to absorb the journal compacts and grows, even while the
      journal is still under its own budget
  18. a FIFO planted at either store path fails the open rather than hanging on it
  19. an unusable journal with nothing to recover is removed, not answered with a
      whole-table rewrite
  20. rewriting files the table already holds stays in the journal: they add no
      slots, so they must not force the table to compact and grow
  21. a table written before the nonce field existed rewrites once to mint one,
      instead of journalling batches no reader could ever accept
  22. the index records its own checksum in an xattr under replay's own name, not a
      public.fingerprint.* one the other tools would trust in place of reading it -
      and replay still catches a rotted index, because what it verifies is the
      trailer inside the file rather than any record beside it

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
# replay's own name for the index's self-record. Deliberately not one of the above:
# those carry a trust rule (inode+size+mtime match => skip reading the file) that an
# index cannot honour, because bit rot moves none of the three.
STORE_XATTR_NAME = "public.replay.store-crc32c"

# Mirrors replay/FingerprintStore.cpp. Little-endian, no padding: the structs are
# laid out so that every field is naturally aligned.
FP_HEADER     = struct.Struct("<QIIQQQ16sQ")    # 64 bytes
FP_TRAILER    = struct.Struct("<QII")           # 16 bytes
HEADER_MAGIC  = 0x01535046594C5052              # "RPLYFPS\1"
TRAILER_MAGIC = 0x01545046594C5052              # "RPLYFPT\1"
SLOT_SIZE     = 32
# magic 0, version 8, hashAlgo 12, capacity 16, count 24, runCounter 32, hostUuid 40,
# nonce 56.
HOSTUUID_OFF  = 40

# The journal beside it: FpJournalHeader | (FpBatchHeader | n slots | FpBatchTrailer)*
FP_JOURNAL      = struct.Struct("<QII16s")      # 32 bytes
FP_BATCH        = struct.Struct("<QQQQ")        # 32: magic, count, storeRun, storeNonce
FP_BATCH_END    = struct.Struct("<QII")         # 16 bytes: magic, crc32c, reserved
JOURNAL_MAGIC   = 0x014A5046594C5052            # "RPLYFPJ\1"
BATCH_MAGIC     = 0x01425046594C5052            # "RPLYFPB\1"
BATCH_END_MAGIC = 0x01455046594C5052            # "RPLYFPE\1"
# The store rewrites itself when the journal would exceed capacity/4 entries, or
# when table + journal would pass the 0.7 load factor. Mirrors FingerprintStore.cpp.
JOURNAL_SHARE   = 4
MIN_CAPACITY    = 1024

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
    """'memo: N hits, M computed, store PATH (T table, J journalled)', printed only
    under --verbose. (-1, -1, '') if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("memo: ") and " hits, " in line:
            parts = line.split()
            return (int(parts[1]), int(parts[3]), parts[6])
    return (-1, -1, "")


def memo_sources(proc: subprocess.CompletedProcess) -> tuple:
    """The '(T table, J journalled)' tail of the memo line: where the entries this
    run could see came from. (-1, -1) if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("memo: ") and " table, " in line:
            parts = line.split()
            return (int(parts[7].lstrip("(")), int(parts[9]))
    return (-1, -1)


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
        magic, version, algo, capacity, count, runs, host, nonce = \
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
        self.nonce = nonce
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


def journal_path(cache: Path):
    if not cache.exists():
        return None
    paths = sorted(cache.glob("fingerprints-*.jrnl"))
    return paths[0] if len(paths) == 1 else None


class Journal:
    """A parsed journal. Every batch checksum is recomputed here, so a batch that
    replay would refuse to read is one this parser refuses too."""

    def __init__(self, path):
        self.path = path
        # Tolerates a missing journal so that a scenario whose expectation is wrong
        # reports a clean FAIL and lets the rest of the suite run, rather than dying
        # with a traceback and skipping everything after it.
        self.raw = path.read_bytes() if (path is not None and path.exists()) else b""
        self.valid = False
        self.host = b""
        # (storeRun, storeNonce, slot_count) per verified batch, in file order
        self.batches = []
        self.trailing = 0   # bytes after the last batch that verified

        if len(self.raw) < FP_JOURNAL.size:
            return
        magic, version, algo, host = FP_JOURNAL.unpack_from(self.raw, 0)
        if magic != JOURNAL_MAGIC:
            return
        self.version = version
        self.algo = algo
        self.host = host
        self.valid = True

        offset = FP_JOURNAL.size
        while offset < len(self.raw):
            remaining = len(self.raw) - offset
            if remaining < FP_BATCH.size + FP_BATCH_END.size:
                break
            bmagic, count, store_run, store_nonce = FP_BATCH.unpack_from(self.raw, offset)
            if bmagic != BATCH_MAGIC or count == 0:
                break
            body = FP_BATCH.size + (count * SLOT_SIZE)
            if body + FP_BATCH_END.size > remaining:
                break
            emagic, stored_crc, _ = FP_BATCH_END.unpack_from(self.raw, offset + body)
            if emagic != BATCH_END_MAGIC:
                break
            if crc32c(self.raw[offset:offset + body]) != stored_crc:
                break
            self.batches.append((store_run, store_nonce, count))
            offset += body + FP_BATCH_END.size
        self.trailing = len(self.raw) - offset

    @property
    def entries(self) -> int:
        """Slots across every batch that verified. Counts a file once per batch it
        appears in, which is what the file holds - replay collapses them on read."""
        return sum(count for _run, _nonce, count in self.batches)


def read_journal(cache: Path) -> Journal:
    """The journal a scenario expects to exist. A missing one is a real failure mode
    of the code under test, so it is reported as a FAIL and parsing continues against
    an empty journal - the caller's own checks then fail cleanly too."""
    path = journal_path(cache)
    if path is None:
        listing = [p.name for p in sorted(cache.iterdir())] if cache.exists() else "nothing"
        fail("a journal was expected in the cache directory", str(listing))
    return Journal(path)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def xattr_names(path: Path) -> list:
    proc = subprocess.run(["/usr/bin/xattr", str(path)],
                          capture_output=True, text=True, timeout=10)
    return proc.stdout.split()


def has_fingerprint_xattr(path: Path) -> bool:
    return any(n in xattr_names(path) for n in XATTR_NAMES)


def read_store_checksum_xattr(path: Path):
    """The 32-byte record the index writes about itself, as (inode, size, mtime_ns,
    hash), or None. Read through /usr/bin/xattr because os.getxattr is Linux-only."""
    proc = subprocess.run(["/usr/bin/xattr", "-px", STORE_XATTR_NAME, str(path)],
                          capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        return None
    raw = bytes.fromhex(proc.stdout.replace(" ", "").replace("\n", ""))
    if len(raw) != 32:
        return None
    return struct.unpack("<qqqQ", raw)


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

        # A new file for a new task adds exactly two records - its input and its
        # output - and two records is nowhere near the journal's budget, so they
        # go there and the table is not rewritten at all.
        table_digest = digest(store_path(cache))
        steps = json.loads(playlist.read_text())
        extra = src / "in_extra.txt"
        extra.write_text("extra payload")
        steps.append({
            "action": "execute", "tool": "/bin/sh",
            "arguments": ["-c", f"cat {extra} > {out}/out_extra.txt"],
            "inputs": [str(extra)], "outputs": [str(out / "out_extra.txt")],
        })
        playlist.write_text(json.dumps(steps))

        r = run(args + ["-v", playlist])
        check("adding a task appends to the journal rather than rewriting the table",
              "appended 2 records" in r.stderr, r.stderr)
        check("the table really was left byte-identical",
              digest(store_path(cache)) == table_digest, str(store_path(cache)))

        jrnl = journal_path(cache)
        check("a journal file now exists", jrnl is not None, str(cache))
        parsed = Journal(jrnl)
        check("the journal parses and every batch checksum verifies",
              parsed.valid and parsed.trailing == 0, f"trailing={parsed.trailing}")
        check("the journal holds exactly the two new files",
              parsed.entries == 2, f"entries={parsed.entries} batches={parsed.batches}")
        check("the table carries a nonzero image nonce", store.nonce != 0, str(store.nonce))
        check("the batch names the table image it extends, counter AND nonce",
              parsed.batches == [(store.run_counter, store.nonce, 2)],
              f"{parsed.batches} vs run={store.run_counter} nonce={store.nonce}")

        # Table plus journal is what a lookup sees, and it has to add up to every
        # distinct file: the next run hits all of them and computes nothing.
        r2 = run(args + ["-v", playlist])
        check("table plus journal covers every file: nothing is recomputed",
              memo(r2)[1] == 0, f"{memo(r2)} in: {r2.stderr}")
        check("and the count of distinct files is the table's plus the journal's",
              Store(store_path(cache)).count + read_journal(cache).entries
                  == expected + 2,
              f"{Store(store_path(cache)).count} + "
              f"{read_journal(cache).entries} != {expected + 2}")


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
    print("\n=== Scenario 13: an unchanged run writes nothing at all ===")
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
        check("a cold run writes no journal: it just wrote the whole table",
              journal_path(cache) is None, str(sorted(cache.iterdir())))

        r2 = run(args + [playlist])
        check("run 2 hit everything", summary(r2) == (3, 0, 0), r2.stderr)
        check("run 2 left the store byte-identical", digest(path) == first_digest, str(path))
        check("run 2 did not even replace the inode",
              path.stat().st_ino == first_inode and path.stat().st_mtime_ns == first_mtime,
              str(path))
        check("run 2 wrote no journal either", journal_path(cache) is None,
              str(sorted(cache.iterdir())))

        r3 = run(args + [playlist])
        check("run 3 likewise", digest(path) == first_digest and
              path.stat().st_ino == first_inode, str(path))

        # One changed file is what the journal is for: its two records are written
        # as a batch, and the table - which may be 32 MB - is not touched.
        (src / "in1.txt").write_text("payload 1 v2 longer")
        r4 = run(args + [playlist])
        check("a changed file re-runs its task", summary(r4) == (2, 1, 0), r4.stderr)
        check("the table was not rewritten for it", digest(path) == first_digest, str(path))
        check("its records went to the journal instead",
              journal_path(cache) is not None and read_journal(cache).entries == 2,
              r4.stderr)

        # And the steady state holds on top of a journal, not just on top of a
        # freshly written table: a run that changes nothing appends nothing.
        jrnl = journal_path(cache)
        jrnl_digest = digest(jrnl)
        r5 = run(args + [playlist])
        check("run 5 hits everything again", summary(r5) == (3, 0, 0), r5.stderr)
        check("run 5 recomputes nothing, so the journal was read", memo(r5)[1] == 0,
              f"{memo(r5)} in: {r5.stderr}")
        check("and it says so: 6 entries from the table, 2 from the journal",
              memo_sources(r5) == (6, 2), f"{memo_sources(r5)} in: {r5.stderr}")
        check("run 5 leaves both files byte-identical",
              digest(path) == first_digest and digest(jrnl) == jrnl_digest, str(jrnl))


def journalled_tree(d: Path, count: int = 3):
    """A tree run once cold and then changed just enough to leave a journal
    behind. Returns everything the caller needs to poke at it."""
    playlist, src, out, _ = make_tree(d, count)
    cache = d / "cache"
    args = ["--cache", "--cache-dir", cache, "-v"]
    run(args + [playlist])
    (src / "in0.txt").write_text("payload 0 v2 longer")
    run(args + [playlist])
    return playlist, src, out, cache, args


def test_torn_journal_is_repaired():
    print("\n=== Scenario 14: a journal torn by a crash is repaired in place ===")
    # A batch is only as good as its checksum, and a reader stops at the first one
    # that fails - so a tail half-written by a crash would hide every batch after
    # it. The repair rewrites the journal from the batches that did verify rather
    # than falling back on rewriting the whole table.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, cache, args = journalled_tree(d, 3)
        table = store_path(cache)
        jrnl = journal_path(cache)
        check("the setup left a journal", jrnl is not None, str(sorted(cache.iterdir())))
        table_digest = digest(table)

        # Append a plausible-looking but unfinished batch, exactly as a crash
        # partway through a write() would leave behind.
        torn = bytearray(jrnl.read_bytes())
        torn += FP_BATCH.pack(BATCH_MAGIC, 4, 1, 1)
        torn += b"\x11" * (2 * SLOT_SIZE)   # half the slots the header promises
        jrnl.write_bytes(bytes(torn))
        damaged = Journal(jrnl)
        check("the torn batch is not readable, and is at the tail",
              damaged.entries == 2 and damaged.trailing > 0,
              f"entries={damaged.entries} trailing={damaged.trailing}")

        r = run(args + [playlist])
        check("the run over a torn journal exits 0", r.returncode == 0, r.stderr)
        check("the cache verdict is unaffected", summary(r) == (3, 0, 0), r.stderr)
        check("recovering the journal did not rewrite the table",
              digest(table) == table_digest, str(table))

        repaired = read_journal(cache)
        check("the journal is whole again", repaired.valid and repaired.trailing == 0,
              f"trailing={repaired.trailing}")
        check("the records that verified were carried into the replacement",
              repaired.entries == 2, f"entries={repaired.entries}")

        # The real proof that nothing was lost: nothing has to be recomputed.
        r2 = run(args + [playlist])
        check("the repaired journal still answers every lookup", memo(r2)[1] == 0,
              f"{memo(r2)} in: {r2.stderr}")


def test_stale_generation_is_dropped():
    print("\n=== Scenario 15: a batch for a superseded table image is dropped ===")
    # The window this covers is a crash between publishing a new table and clearing
    # the journal that described the old one. Those records are still true, but
    # their epochs belong to a generation that is gone, so they must not be overlaid
    # on a table they were never written against.
    #
    # Both halves of the image identity are exercised. The run counter alone is not
    # enough: it restarts at 1 every time the table is rebuilt from nothing, which a
    # failed checksum makes routine, so two different images really can share one.
    # The nonce is what tells them apart, and "same counter, different nonce" is the
    # case that would otherwise be accepted.
    for label, bump_run, bump_nonce in (("different counter", True, False),
                                        ("same counter, different nonce", False, True)):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td).resolve()
            playlist, src, out, cache, args = journalled_tree(d, 3)
            jrnl = journal_path(cache)
            table = Store(store_path(cache))
            check(f"[{label}] the batch starts out matching the table",
                  Journal(jrnl).batches == [(table.run_counter, table.nonce, 2)],
                  f"{Journal(jrnl).batches} vs ({table.run_counter}, {table.nonce})")

            # Restamp the batch for an image that does not exist, and repair its
            # checksum so that ONLY the generation check can reject it.
            raw = bytearray(jrnl.read_bytes())
            offset = FP_JOURNAL.size
            bmagic, count, run_id, nonce = FP_BATCH.unpack_from(raw, offset)
            if bump_run:
                run_id += 99
            if bump_nonce:
                nonce ^= 0xA5A5A5A5A5A5A5A5
            FP_BATCH.pack_into(raw, offset, bmagic, count, run_id, nonce)
            body = FP_BATCH.size + (count * SLOT_SIZE)
            FP_BATCH_END.pack_into(raw, offset + body, BATCH_END_MAGIC,
                                   crc32c(bytes(raw[offset:offset + body])), 0)
            jrnl.write_bytes(bytes(raw))
            check(f"[{label}] the restamped batch still verifies its own checksum",
                  Journal(jrnl).entries == count, str(Journal(jrnl).batches))

            r = run(args + [playlist])
            check(f"[{label}] the run exits 0", r.returncode == 0, r.stderr)
            check(f"[{label}] the cache verdict is unaffected",
                  summary(r) == (3, 0, 0), r.stderr)
            check(f"[{label}] the stale records were not trusted: the file was re-hashed",
                  memo(r)[1] > 0, f"{memo(r)} in: {r.stderr}")
            rebuilt = read_journal(cache)
            check(f"[{label}] and the journal was reset to this table image",
                  rebuilt.batches == [(table.run_counter, table.nonce, 2)],
                  f"{rebuilt.batches} vs ({table.run_counter}, {table.nonce})")


def test_planted_fifo_does_not_hang():
    print("\n=== Scenario 18: a FIFO planted at either store path fails, never hangs ===")
    # A shared cache directory is an advertised use case, so another user can create
    # names in it. O_NOFOLLOW covers symlinks; a FIFO is the other way to make an
    # open block forever, and it blocks before any fstat could reject the file. The
    # run must degrade to "no memo", not to a build that never finishes.
    for label, suffix in (("index", ".bin"), ("journal", ".jrnl")):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td).resolve()
            playlist, src, out, _ = make_tree(d, 2)
            cache = d / "cache"
            args = ["--cache", "--cache-dir", cache, "-v"]

            run(args + [playlist])          # establish the real names
            table = store_path(cache)
            if not check(f"[{label}] the setup run created a store", table is not None,
                         str(sorted(cache.iterdir())) if cache.exists() else str(cache)):
                continue
            target = table.with_suffix(suffix)
            if target.exists():
                target.unlink()
            os.mkfifo(target)
            check(f"[{label}] a FIFO is in place", target.is_fifo(), str(target))

            try:
                r = run(args + [playlist], timeout=25)
                timed_out = False
            except subprocess.TimeoutExpired:
                r = None
                timed_out = True
            check(f"[{label}] the run finishes rather than blocking on the open",
                  not timed_out, "timed out after 25s")
            if not timed_out:
                check(f"[{label}] and it exits 0", r.returncode == 0, r.stderr)
                check(f"[{label}] the cache verdict is unaffected",
                      summary(r) == (2, 0, 0), r.stderr)


def test_unusable_journal_is_only_removed():
    print("\n=== Scenario 19: an unusable journal is removed, not answered with a rewrite ===")
    # A journal that cannot be read and has nothing to recover is repaired by
    # deleting it. Falling through to the table rewrite would republish bytes that
    # are already correct - at the sizes this feature targets, tens of megabytes to
    # fix a file that should simply have been unlinked.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, cache, args = journalled_tree(d, 3)
        table = store_path(cache)
        table_digest = digest(table)

        # Destroy the journal beyond recovery, and drop the task whose files it
        # described - so this run has nothing new to record either.
        journal_path(cache).write_bytes(b"GARBAGE!" * 4)
        steps = json.loads(playlist.read_text())
        playlist.write_text(json.dumps(steps[1:]))

        r = run(args + [playlist])
        check("the run exits 0", r.returncode == 0, r.stderr)
        check("the cache verdict is unaffected", summary(r) == (2, 0, 0), r.stderr)
        check("the table was NOT rewritten to repair a journal",
              digest(table) == table_digest, r.stderr)
        check("the unusable journal is simply gone", journal_path(cache) is None,
              str(sorted(cache.iterdir())))


def test_pre_nonce_table_upgrades_once():
    print("\n=== Scenario 21: a table with no nonce rewrites once, then journals ===")
    # A table written before the nonce field existed carries 0 there, and 0 identifies
    # no image, so no batch can name it. Appending to it anyway would write a batch the
    # reader rejects forever: the changed files would be re-hashed and re-appended every
    # run, and the journal could never grow enough to trigger the compaction that would
    # fix it. The first store-modifying run must rewrite the table instead, which mints
    # a nonce, after which the journal works normally.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        table = store_path(cache)

        # Age the store back to before the field existed, repairing the trailer so
        # that ONLY the zero nonce distinguishes it.
        raw = bytearray(table.read_bytes())
        struct.pack_into("<Q", raw, 56, 0)
        body = bytes(raw[:len(raw) - FP_TRAILER.size])
        FP_TRAILER.pack_into(raw, len(raw) - FP_TRAILER.size,
                             TRAILER_MAGIC, crc32c(body), 0)
        table.write_bytes(bytes(raw))
        aged = Store(table)
        check("the aged table still verifies its checksum", aged.crc_ok, str(table))
        check("and carries no nonce", aged.nonce == 0, str(aged.nonce))

        (src / "in0.txt").write_text("payload 0 v2 longer")
        r1 = run(args + [playlist])
        check("the first change rewrites the table rather than journalling it",
              "rewrote the store" in r1.stderr, r1.stderr)
        upgraded = Store(table)
        check("the rewrite minted a nonce", upgraded.nonce != 0, str(upgraded.nonce))
        check("and wrote no journal", journal_path(cache) is None,
              str(sorted(cache.iterdir())))

        # The livelock this guards against: without the fix every later run re-hashes
        # the same files and rewrites a journal no reader will ever accept.
        r2 = run(args + [playlist])
        check("the next unchanged run recomputes nothing", memo(r2)[1] == 0,
              f"{memo(r2)} in: {r2.stderr}")
        table_digest = digest(table)

        (src / "in1.txt").write_text("payload 1 v2 longer")
        r3 = run(args + [playlist])
        check("a later change now goes to the journal", "appended 2 records" in r3.stderr,
              r3.stderr)
        check("leaving the upgraded table alone", digest(table) == table_digest, str(table))
        r4 = run(args + [playlist])
        check("and that journal is accepted on the next run", memo(r4)[1] == 0,
              f"{memo(r4)} in: {r4.stderr}")


def test_changed_existing_files_stay_in_journal():
    print("\n=== Scenario 20: rewriting existing files does not force the table to grow ===")
    # The compaction rule asks whether the TABLE can hold what the journal adds. A
    # changed file already owns a slot, so it adds nothing - counting it as new made
    # a run that merely rewrote existing files compact, and then double the table for
    # a load it was never going to carry.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        tasks = 260                       # 520 files in a 1024-slot table: load 0.51
        playlist, src, out, _ = big_tree(d, tasks)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        table = store_path(cache)
        cold = Store(table)
        budget = max(64, cold.capacity // JOURNAL_SHARE)
        table_digest = digest(table)

        # Enough changed EXISTING files that the naive count would pass 0.7 of the
        # table, while the true number of new slots is zero.
        changed = 120
        records = changed * 2             # each task's input and its regenerated output
        check("the change stays inside the journal's entry budget",
              records <= budget, f"{records} > {budget}")
        check("but the naive count would have passed the 0.7 load factor",
              (cold.count + records) > ((cold.capacity * 7) // 10),
              f"{cold.count} + {records} vs {(cold.capacity * 7) // 10}")

        for i in range(changed):
            (src / f"in{i}.txt").write_text(f"payload {i} v2 longer")
        r = run(args + [playlist])
        check("the run exits 0", r.returncode == 0, r.stderr)
        check("it appended instead of rewriting", f"appended {records} records" in r.stderr,
              r.stderr)
        check("the table was left byte-identical", digest(table) == table_digest, str(table))
        check("so its capacity did not double for files it already held",
              Store(table).capacity == cold.capacity,
              f"{cold.capacity} -> {Store(table).capacity}")

        r2 = run(args + [playlist])
        check("everything hits afterwards", summary(r2) == (tasks, 0, 0), r2.stderr)
        check("and nothing is recomputed", memo(r2)[1] == 0, f"{memo(r2)} in: {r2.stderr}")


def big_tree(d: Path, count: int, name: str = "pl", first: int = 0):
    """count independent copy tasks - 2*count declared files - written straight to
    a playlist. Large enough to reach the journal's size rules. `first` offsets the
    file names so two playlists can share a directory without overlapping."""
    src = d / "src"
    out = d / "out"
    src.mkdir(exist_ok=True)
    out.mkdir(exist_ok=True)
    steps = []
    for i in range(first, first + count):
        (src / f"in{i}.txt").write_text(f"payload {i} v1")
        steps.append({
            "action": "execute", "tool": "/bin/sh",
            "arguments": ["-c", f"cat {src}/in{i}.txt > {out}/out{i}.txt"],
            "inputs": [str(src / f"in{i}.txt")],
            "outputs": [str(out / f"out{i}.txt")],
        })
    playlist = d / f"{name}.json"
    playlist.write_text(json.dumps(steps))
    return playlist, src, out, steps


def test_journal_budget_forces_compaction():
    print("\n=== Scenario 16: exceeding the journal budget folds it into the table ===")
    # Two playlists share the cache directory, which is what gives the fold-in
    # something only it can save. A compaction writes every record of the run that
    # triggered it, so a file THAT run also touched would survive whether or not the
    # journal is merged. The second playlist's files are the ones that would not.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        tasks = 140                       # playlist A: 280 declared files
        side = 20                         # playlist B: 40 more, same cache directory
        playlist, src, out, _ = big_tree(d, tasks)
        side_playlist, _, _, _ = big_tree(d, side, name="side", first=1000)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        table = store_path(cache)
        cold = Store(table)
        budget = max(64, cold.capacity // JOURNAL_SHARE)
        check("the cold run wrote every file into the table",
              cold.count == tasks * 2, f"count={cold.count} expected={tasks * 2}")
        check("and wrote no journal", journal_path(cache) is None,
              str(sorted(cache.iterdir())))

        # Playlist B's files are new, so they land in the journal - and the table,
        # written before B ever ran, is the one place they are NOT.
        rb = run(args + [side_playlist])
        check("the second playlist appended to the journal",
              f"appended {side * 2} records" in rb.stderr, rb.stderr)
        first_digest = digest(table)
        check("the table did not absorb them", Store(table).count == tasks * 2,
              str(Store(table).count))
        check("the journal holds exactly the second playlist's files",
              read_journal(cache).entries == side * 2,
              str(read_journal(cache).batches))

        # Now change enough of playlist A that the journal would pass its budget.
        # A's run never looks at B's files, so only the fold-in can preserve them.
        changed = (budget // 2) + 4
        for i in range(changed):
            (src / f"in{i}.txt").write_text(f"payload {i} v2 longer")
        r = run(args + [playlist])
        check("the run exits 0", r.returncode == 0, r.stderr)
        check("passing the budget rewrote the table instead of appending",
              "rewrote the store" in r.stderr, r.stderr)
        check("the table really changed", digest(table) != first_digest, str(table))
        check("and the journal was cleared", journal_path(cache) is None,
              str(sorted(cache.iterdir())))

        folded = Store(table)
        check("the compacted table verifies", folded.crc_ok, str(table))
        check("the journal's records were folded in, not dropped",
              folded.count == (tasks + side) * 2,
              f"count={folded.count} expected={(tasks + side) * 2}")
        check("the fold-in bumped the run counter",
              folded.run_counter == cold.run_counter + 1,
              f"{cold.run_counter} -> {folded.run_counter}")

        folded_digest = digest(table)
        r2 = run(args + [playlist])
        check("every task hits after the compaction", summary(r2) == (tasks, 0, 0), r2.stderr)
        check("and the compacted table is itself a steady state",
              digest(table) == folded_digest and journal_path(cache) is None,
              str(sorted(cache.iterdir())))

        # The behavioural half of the same claim: the second playlist, which has not
        # run since its records were journal-only, must not have to re-hash anything.
        rb2 = run(args + [side_playlist])
        check("the second playlist still hits every task",
              summary(rb2) == (side, 0, 0), rb2.stderr)
        check("and recomputes nothing: its records survived the fold",
              memo(rb2)[1] == 0, f"{memo(rb2)} in: {rb2.stderr}")
        check("so it writes nothing either",
              digest(table) == folded_digest and journal_path(cache) is None,
              str(sorted(cache.iterdir())))


def test_load_factor_forces_compaction():
    print("\n=== Scenario 17: a table too full to absorb the journal grows ===")
    # The other compaction trigger, and the one that keeps the table from being
    # left permanently over its load factor: the journal is still well inside its
    # own budget here, so only the 0.7 rule can fire.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        tasks = 260                       # 520 files: a 1024-slot table at 0.51
        playlist, src, out, steps = big_tree(d, tasks)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        table = store_path(cache)
        cold = Store(table)
        budget = max(64, cold.capacity // JOURNAL_SHARE)
        check("the cold table is at the minimum capacity",
              cold.capacity == MIN_CAPACITY, str(cold.capacity))
        check("it holds every file", cold.count == tasks * 2, str(cold.count))

        # Enough NEW files to pass 0.7 of the table, but few enough to stay inside
        # the journal's own budget - so the two triggers are told apart.
        added = 110
        for i in range(tasks, tasks + added):
            (src / f"in{i}.txt").write_text(f"payload {i} v1")
            steps.append({
                "action": "execute", "tool": "/bin/sh",
                "arguments": ["-c", f"cat {src}/in{i}.txt > {out}/out{i}.txt"],
                "inputs": [str(src / f"in{i}.txt")],
                "outputs": [str(out / f"out{i}.txt")],
            })
        playlist.write_text(json.dumps(steps))
        new_records = added * 2
        check("the change stays inside the journal's budget",
              new_records <= budget, f"{new_records} > {budget}")
        check("but table plus journal would pass the 0.7 load factor",
              (cold.count + new_records) > ((cold.capacity * 7) // 10),
              f"{cold.count} + {new_records} vs {(cold.capacity * 7) // 10}")

        r = run(args + [playlist])
        check("the run exits 0", r.returncode == 0, r.stderr)
        check("the load factor rule rewrote the table",
              "rewrote the store" in r.stderr, r.stderr)
        grown = Store(table)
        check("the table grew rather than staying over its load factor",
              grown.capacity == cold.capacity * 2,
              f"{cold.capacity} -> {grown.capacity}")
        check("it holds every file, old and new",
              grown.count == (tasks + added) * 2,
              f"count={grown.count} expected={(tasks + added) * 2}")
        # Not "count <= 0.7 * capacity" - with both of those already pinned above that
        # cannot fail. What is worth asserting is that the size chosen is the SMALLEST
        # power of two that fits, so an over-eager growth rule would show up here.
        check("and it grew to the smallest power of two that fits",
              grown.count > ((cold.capacity * 7) // 10),
              f"count={grown.count} would have fit in {cold.capacity}")
        check("the grown table verifies", grown.crc_ok, str(table))

        r2 = run(args + [playlist])
        check("everything hits afterwards", summary(r2) == (tasks + added, 0, 0), r2.stderr)
        check("and nothing is recomputed", memo(r2)[1] == 0, f"{memo(r2)} in: {r2.stderr}")


def test_checksum_xattr_mirror():
    print("\n=== Scenario 22: the index records its own checksum, under its own name ===")
    # The record says what the index contained when it was published, which is a
    # weaker claim than what it contains now - no attribute can notice bit rot, since
    # rot moves neither size nor mtime. That is why the name matters: under a
    # public.fingerprint.* name the gate and fingerprint tools would trust it in place
    # of reading the file, and a rotted index would report its pre-rot hash exactly
    # when someone was investigating the rot. The last third of this scenario pins
    # that replay is not fooled either.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, src, out, _ = make_tree(d, 3)
        cache = d / "cache"
        args = ["--cache", "--cache-dir", cache, "-v"]

        run(args + [playlist])
        table = store_path(cache)
        if not check("the setup run created an index", table is not None,
                     str(sorted(cache.iterdir())) if cache.exists() else str(cache)):
            return
        record = read_store_checksum_xattr(table)
        check("the index carries its own checksum record", record is not None,
              str(xattr_names(table)))
        check("under replay's name, NOT a memo name the other tools would trust",
              STORE_XATTR_NAME in xattr_names(table) and not has_fingerprint_xattr(table),
              str(xattr_names(table)))
        if record is not None:
            inode, size, mtime_ns, packed = record
            st = table.stat()
            check("its record describes the index as it stands",
                  (inode == st.st_ino) and (size == st.st_size) and (mtime_ns == st.st_mtime_ns),
                  f"{record} vs inode={st.st_ino} size={st.st_size} mtime={st.st_mtime_ns}")
            check("and its checksum is the crc32c of the WHOLE file, trailer included",
                  (packed & 0xFFFFFFFF) == crc32c(table.read_bytes()),
                  f"{hex(packed & 0xFFFFFFFF)} vs {hex(crc32c(table.read_bytes()))}")
            check("the unused half of the hash union stays zero", (packed >> 32) == 0,
                  hex(packed))

        # One changed file goes to the journal, which is appended to in place - any
        # record of its bytes would be stale on the next append, so it gets none.
        (src / "in0.txt").write_text("payload 0 v2 longer")
        run(args + [playlist])
        jrnl = journal_path(cache)
        check("the journal carries no such record",
              jrnl is not None and STORE_XATTR_NAME not in xattr_names(jrnl),
              str(xattr_names(jrnl)) if jrnl is not None else "no journal")
        check("and a journal-only run leaves the index's record alone",
              read_store_checksum_xattr(table) == record, str(read_store_checksum_xattr(table)))

        # A rewrite must produce a record for the image it actually wrote. Removing the
        # index is the cheapest way to force one - small changes deliberately do not,
        # which is what the journal is for and why this cannot be provoked by editing
        # files. The stale journal is dropped with it, since it names an image that is
        # gone.
        table.unlink()
        run(args + [playlist])
        if not check("the index was rebuilt", table.exists(), str(sorted(cache.iterdir()))):
            return
        rewritten = read_store_checksum_xattr(table)
        check("a rebuilt index carries a record of its own", rewritten is not None,
              str(xattr_names(table)))
        check("the record is not the one describing the old image", rewritten != record,
              f"{rewritten} vs {record}")
        if rewritten is not None:
            check("and its checksum matches the rebuilt bytes",
                  (rewritten[3] & 0xFFFFFFFF) == crc32c(table.read_bytes()),
                  f"{hex(rewritten[3] & 0xFFFFFFFF)} vs {hex(crc32c(table.read_bytes()))}")

        # THE point of the scenario. Rot one bit and put mtime back, so the mirrored
        # record still "matches" by its own rules. replay must ignore it entirely and
        # fall back on the trailer, which is inside the file and covers the bytes.
        st = table.stat()
        raw = bytearray(table.read_bytes())
        raw[FP_HEADER.size + 40] ^= 0x40
        table.write_bytes(bytes(raw))
        os.utime(table, ns=(st.st_atime_ns, st.st_mtime_ns))
        stale = read_store_checksum_xattr(table)
        check("the stale record still matches the rotted file's inode, size and mtime",
              stale is not None and stale[0] == table.stat().st_ino
              and stale[1] == table.stat().st_size and stale[2] == table.stat().st_mtime_ns,
              str(stale))
        check("but it no longer describes the bytes",
              stale is not None and (stale[3] & 0xFFFFFFFF) != crc32c(table.read_bytes()),
              str(stale))

        r = run(args + [playlist])
        check("replay catches the rot anyway: the trailer is what it trusts",
              memo(r)[0] == 0, f"{memo(r)} in: {r.stderr}")
        check("it says so", "integrity check" in r.stderr, r.stderr)
        check("the cache verdict is unaffected", summary(r) == (3, 0, 0), r.stderr)
        check("and the index was rebuilt with a fresh record",
              (read_store_checksum_xattr(table) or (0, 0, 0, 0))[3] & 0xFFFFFFFF
                  == crc32c(table.read_bytes()),
              str(read_store_checksum_xattr(table)))


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
    test_torn_journal_is_repaired()
    test_stale_generation_is_dropped()
    test_journal_budget_forces_compaction()
    test_load_factor_forces_compaction()
    test_planted_fifo_does_not_hang()
    test_unusable_journal_is_only_removed()
    test_pre_nonce_table_upgrades_once()
    test_changed_existing_files_stay_in_journal()
    test_checksum_xattr_mirror()

    print("\n========================================")
    print(f"  Passed: {_pass}  Failed: {_fail}")
    print("========================================")
    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
