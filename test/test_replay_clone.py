#!/usr/bin/env python3
"""
test_replay_clone.py - what the clone action copies, and move across file systems.

clone uses copyfile(3) on macOS and replay/LinuxCopyItem.cpp on Linux, which follows
copyfile's behavior; these checks pin that behavior on both platforms:
  1. a file: data (empty, small, several MB), mode, modification time, xattrs
  2. an existing destination file fails and is left alone; --force replaces it
  3. an existing destination folder receives the item inside it
  4. a missing parent folder fails
  5. symlinks are copied as symlinks, dangling ones too
  6. a folder tree: files, subfolders, symlinks, folder modes and xattrs; hard links
     become separate files
  6b. trailing slashes: a symlink to a folder is followed, a file fails, no copying into
     an existing folder, a file to "missing/" fails
  7. a FIFO fails
  8. Linux only, where it differs from copyfile on purpose: a read-only subfolder
     copies; a folder copied into itself fails up front
  9. move to another file system (the clone-and-delete fallback), when two are available

Usage: python3 test_replay_clone.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

sys.path.insert(0, str(SCRIPT_DIR))
from xattr_support import IS_LINUX, get_xattr, set_xattr  # noqa: E402

FIXED_TIME = 1577934245  # 2020-01-02, whole seconds so every file system keeps it exactly
XATTR_NAME = "com.example.replay-clone-test"

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


def run_replay(playlist: list, extra_args: list = ()) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(playlist, f)
        path = f.name
    try:
        return subprocess.run([str(REPLAY)] + list(extra_args) + [path],
                              capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(path)


def clone(src, dst, extra_args: list = ()) -> subprocess.CompletedProcess:
    return run_replay([{"action": "clone", "from": str(src), "to": str(dst)}], extra_args)


def mode_of(path: Path) -> int:
    return stat.S_IMODE(os.lstat(path).st_mode)


def make_file(path: Path, data: bytes, mode: int = 0o640) -> None:
    path.write_bytes(data)
    os.chmod(path, mode)
    os.utime(path, (FIXED_TIME, FIXED_TIME))


def failed(result: subprocess.CompletedProcess) -> bool:
    return (result.returncode != 0) and ("failed to clone" in result.stderr)


# ---------------------------------------------------------------------------

def test_files(work: Path) -> None:
    print("\n--- 1. files: data, mode, time, xattrs ---")
    big = os.urandom(3 * 1024 * 1024 + 17)
    for name, data in (("empty", b""), ("small", b"hello\n"), ("big", big)):
        src = work / f"{name}.src"
        dst = work / f"{name}.dst"
        make_file(src, data)
        has_xattr = set_xattr(src, XATTR_NAME, b"value-" + name.encode())
        result = clone(src, dst)
        if not check(f"{name}: clone exits 0", result.returncode == 0, result.stderr):
            continue
        check(f"{name}: same data", dst.read_bytes() == data)
        check(f"{name}: mode 640", mode_of(dst) == 0o640, oct(mode_of(dst)))
        check(f"{name}: modification time kept", int(os.stat(dst).st_mtime) == FIXED_TIME,
              str(os.stat(dst).st_mtime))
        if has_xattr:
            check(f"{name}: xattr copied", get_xattr(dst, XATTR_NAME) == b"value-" + name.encode())
        else:
            print(f"  note: {name}: this file system takes no user xattrs; xattr copy not checked")


def test_existing_destination(work: Path) -> None:
    print("\n--- 2. existing destination file ---")
    src = work / "e.src"
    dst = work / "e.dst"
    make_file(src, b"new\n")
    dst.write_bytes(b"old\n")
    result = clone(src, dst)
    check("fails without --force", failed(result), f"rc={result.returncode} {result.stderr}")
    check("destination left alone", dst.read_bytes() == b"old\n")
    result = clone(src, dst, ["--force"])
    check("--force: exits 0", result.returncode == 0, result.stderr)
    check("--force: destination replaced", dst.read_bytes() == b"new\n")


def test_into_existing_folder(work: Path) -> None:
    print("\n--- 3. existing destination folder ---")
    src = work / "into.txt"
    make_file(src, b"into\n")
    folder = work / "folder"
    folder.mkdir()
    result = clone(src, folder)
    check("file into folder: exits 0", result.returncode == 0, result.stderr)
    check("file lands inside the folder", (folder / "into.txt").read_bytes() == b"into\n")
    result = clone(src, folder)
    check("again: fails, the name inside exists", failed(result), result.stderr)

    tree = work / "intotree"
    (tree / "sub").mkdir(parents=True)
    (tree / "sub" / "x").write_bytes(b"x")
    result = clone(tree, folder)
    check("folder into folder: exits 0", result.returncode == 0, result.stderr)
    check("folder lands inside the folder", (folder / "intotree" / "sub" / "x").read_bytes() == b"x")


def test_missing_parent(work: Path) -> None:
    print("\n--- 4. missing parent folder ---")
    src = work / "orphan.txt"
    make_file(src, b"o")
    result = clone(src, work / "no-such-folder" / "orphan.txt")
    check("fails", failed(result), f"rc={result.returncode} {result.stderr}")


def test_symlinks(work: Path) -> None:
    print("\n--- 5. symlinks ---")
    target = work / "target.txt"
    make_file(target, b"t")
    link = work / "link"
    os.symlink("target.txt", link)
    result = clone(link, work / "link2")
    check("symlink: exits 0", result.returncode == 0, result.stderr)
    check("copied as a symlink", (work / "link2").is_symlink() and os.readlink(work / "link2") == "target.txt")
    dangling = work / "dangling"
    os.symlink("no-such-target", dangling)
    result = clone(dangling, work / "dangling2")
    check("dangling symlink: exits 0", result.returncode == 0, result.stderr)
    check("dangling copied as a symlink",
          (work / "dangling2").is_symlink() and os.readlink(work / "dangling2") == "no-such-target")


def test_tree(work: Path) -> None:
    print("\n--- 6. folder tree ---")
    src = work / "tree"
    sub = src / "sub"
    sub.mkdir(parents=True)
    make_file(src / "a.txt", b"a\n", 0o600)
    make_file(sub / "b.txt", b"b\n", 0o644)
    os.link(src / "a.txt", src / "hard.txt")
    os.symlink("a.txt", src / "la")
    os.symlink("../a.txt", sub / "lb")
    has_xattr = set_xattr(sub, XATTR_NAME, b"folder")
    os.chmod(sub, 0o750)
    dst = work / "tree-copy"
    result = clone(src, dst)
    if not check("tree: exits 0", result.returncode == 0, result.stderr):
        return
    check("a.txt data and mode", (dst / "a.txt").read_bytes() == b"a\n" and mode_of(dst / "a.txt") == 0o600)
    check("sub/b.txt data", (dst / "sub" / "b.txt").read_bytes() == b"b\n")
    check("file time kept inside the tree", int(os.stat(dst / "sub" / "b.txt").st_mtime) == FIXED_TIME)
    check("subfolder mode 750", mode_of(dst / "sub") == 0o750, oct(mode_of(dst / "sub")))
    check("symlinks stay symlinks",
          os.readlink(dst / "la") == "a.txt" and os.readlink(dst / "sub" / "lb") == "../a.txt")
    check("hard link becomes a separate file",
          os.stat(dst / "hard.txt").st_ino != os.stat(dst / "a.txt").st_ino and
          (dst / "hard.txt").read_bytes() == b"a\n")
    if has_xattr:
        check("folder xattr copied", get_xattr(dst / "sub", XATTR_NAME) == b"folder")


def test_trailing_slashes(work: Path) -> None:
    print("\n--- 6b. trailing slashes ---")
    base = work / "slash"
    (base / "d" / "in").mkdir(parents=True)
    (base / "d" / "in" / "x").write_bytes(b"x")
    make_file(base / "f1", b"f1")
    os.symlink("d", base / "ld")
    os.symlink("f1", base / "lf")
    (base / "e").mkdir()

    result = clone(f"{base / 'd'}/", base / "d-copy")
    check("d/ to a missing name: copies the folder", result.returncode == 0 and
          (base / "d-copy" / "in" / "x").read_bytes() == b"x", result.stderr)
    result = clone(f"{base / 'ld'}/", base / "ld-copy")
    check("ld/ (symlink to a folder): copies the folder, not the link",
          result.returncode == 0 and not (base / "ld-copy").is_symlink() and
          (base / "ld-copy" / "in" / "x").read_bytes() == b"x", result.stderr)
    for name in ("f1", "lf"):
        result = clone(f"{base / name}/", base / f"{name}-copy")
        check(f"{name}/ (not a folder): fails", failed(result) and not os.path.lexists(base / f"{name}-copy"),
              f"rc={result.returncode} {result.stderr}")
    result = clone(f"{base / 'd'}/", base / "e")
    check("d/ to an existing folder: fails, nothing copied into it",
          failed(result) and not os.path.lexists(base / "e" / "d"), f"rc={result.returncode} {result.stderr}")
    result = clone(base / "f1", f"{base / 'newf'}/")
    check("file to a missing name/: fails", failed(result) and not os.path.lexists(base / "newf"),
          f"rc={result.returncode} {result.stderr}")


def test_fifo(work: Path) -> None:
    print("\n--- 7. FIFO ---")
    fifo = work / "fifo"
    os.mkfifo(fifo)
    result = clone(fifo, work / "fifo2")
    check("FIFO: fails", failed(result), f"rc={result.returncode} {result.stderr}")
    check("FIFO: nothing created", not os.path.lexists(work / "fifo2"))


def test_linux_differences(work: Path) -> None:
    print("\n--- 8. Linux: read-only subfolder, folder into itself ---")
    if not IS_LINUX:
        print("  skipped: copyfile on macOS fails both (EACCES; ENAMETOOLONG after recursing)")
        return
    if os.geteuid() == 0:
        print("  note: running as root, which ignores folder permissions, so the read-only check"
              " passes whatever order the mode is applied in")
    src = work / "ro-tree"
    ro = src / "ro"
    ro.mkdir(parents=True)
    (ro / "inside").write_bytes(b"i")
    os.chmod(ro, 0o555)
    dst = work / "ro-copy"
    try:
        result = clone(src, dst)
        check("read-only subfolder: exits 0", result.returncode == 0, result.stderr)
        check("its contents copied", (dst / "ro" / "inside").read_bytes() == b"i")
        check("its mode 555", mode_of(dst / "ro") == 0o555, oct(mode_of(dst / "ro")))
    finally:
        os.chmod(ro, 0o755)
        if (dst / "ro").exists():
            os.chmod(dst / "ro", 0o755)

    result = clone(src, src / "nested")
    check("folder into itself: fails", failed(result) and "Invalid argument" in result.stderr, result.stderr)
    check("folder into itself: nothing created", not os.path.lexists(src / "nested"))


def other_file_system_folder(work: Path):
    """A writable folder on a different file system from work, or None."""
    candidates = [Path(tempfile.gettempdir()), Path.home(), Path("/dev/shm")]
    work_dev = os.stat(work).st_dev
    for candidate in candidates:
        try:
            if candidate.is_dir() and os.access(candidate, os.W_OK) and os.stat(candidate).st_dev != work_dev:
                return Path(tempfile.mkdtemp(prefix="replay-clone-xfs.", dir=str(candidate)))
        except OSError:
            continue
    return None


def test_move_across_file_systems(work: Path) -> None:
    print("\n--- 9. move to another file system ---")
    other = other_file_system_folder(work)
    if other is None:
        print("  skipped: no second writable file system found")
        return
    try:
        src = work / "mv.txt"
        make_file(src, b"move me\n")
        tree = work / "mvtree"
        (tree / "s").mkdir(parents=True)
        (tree / "s" / "f").write_bytes(b"f")
        result = run_replay([
            {"action": "move", "from": str(src), "to": str(other / "mv.txt")},
            {"action": "move", "from": str(tree), "to": str(other / "mvtree")},
        ])
        check("move: exits 0", result.returncode == 0, result.stderr)
        check("file moved", (other / "mv.txt").read_bytes() == b"move me\n" and not src.exists())
        check("file time kept", int(os.stat(other / "mv.txt").st_mtime) == FIXED_TIME)
        check("folder moved", (other / "mvtree" / "s" / "f").read_bytes() == b"f" and not tree.exists())
    finally:
        subprocess.run(["/bin/rm", "-rf", str(other)], check=False)


# ---------------------------------------------------------------------------

if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

# Under $HOME rather than the temporary folder: /tmp is a separate tmpfs on some Linux
# systems, and test 9 then finds the temporary folder as the "other" file system.
with tempfile.TemporaryDirectory(prefix=".replay-clone-test.", dir=str(Path.home())) as tmp:
    work = Path(tmp)
    test_files(work)
    test_existing_destination(work)
    test_into_existing_folder(work)
    test_missing_parent(work)
    test_symlinks(work)
    test_tree(work)
    test_trailing_slashes(work)
    test_fifo(work)
    test_linux_differences(work)
    test_move_across_file_systems(work)

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
