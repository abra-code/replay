#!/usr/bin/env python3
"""
test_sandbox_discover.py - sandbox/sandbox-discover.py.

Scenarios:
  1. collapsing refused paths to folders: a file's parent; a refused folder itself; a path
     directly inside a too-wide folder (the home folder, /usr) by itself; nothing inside
     another grant twice
  2. profile text: a quote or a backslash in a folder name cannot end the string
  3. option errors: --loop with --native, no "--"
  4. a single run (the default) exits with the command's status and writes what was refused
  5. loop mode on a job that reads one folder, then writes another: it finds both, the job then
     succeeds, the profile holds the read folder read-only and the written one read-write, and
     what the successful pass was still refused is left out
  6. --json: a "pass" event per run, a "check" event when candidate folders were verified, and a
     "done" event, on standard error, nothing on stdout
  7. loop mode on a command that fails for a reason no folder fixes: it stops with status 3

4-7 run commands under /usr/bin/sandbox-exec and read the system log (`log stream`), so they
need to run outside any sandbox; inside one, sandbox-exec cannot apply a profile and they are
skipped.

Usage: python3 test_sandbox_discover.py [ignored]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
DISCOVER = SCRIPT_DIR.parent / "sandbox" / "sandbox-discover.py"

# No bytecode cache next to the script: it is run from the repository, not installed.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sandbox_discover", DISCOVER)
discover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discover)

passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


def run(args, cwd=None):
    return subprocess.run([sys.executable, str(DISCOVER)] + args, capture_output=True, text=True, cwd=cwd)


print("== collapsing refused paths ==")
home = "/Users/alice"
wide = discover.wide_folders(home)
folders = {"/Users/alice/src/app/build"}
collapse = lambda paths: discover.minimal_dirs(paths, wide, is_dir=lambda p: p in folders)
check("a file's parent folder", collapse({"/Users/alice/src/app/main.c"}) == ["/Users/alice/src/app"])
check("a refused folder is granted itself, not its parent",
      collapse({"/Users/alice/src/app/build"}) == ["/Users/alice/src/app/build"])
check("a file directly in the home folder is granted by itself",
      collapse({"/Users/alice/.gitconfig"}) == ["/Users/alice/.gitconfig"])
check("  and so is one directly in ~/Library or /usr",
      collapse({"/Users/alice/Library/x.plist", "/usr/thing"}) == ["/Users/alice/Library/x.plist", "/usr/thing"])
check("nothing inside another grant is listed twice",
      collapse({"/Users/alice/src/app/a.c", "/Users/alice/src/app/sub/b.c"}) == ["/Users/alice/src/app"])
check("a name that only starts like a grant is not inside it",
      collapse({"/data/a/x", "/data/ab/y"}) == ["/data/a", "/data/ab"])
check("a refused folder above a grant is left out: the grant under it is what was needed",
      discover.minimal_dirs({"/Users/alice/src", "/Users/alice/src/app/build"}, wide,
                            is_dir=lambda p: p in {"/Users/alice/src", "/Users/alice/src/app/build"})
      == ["/Users/alice/src/app/build"])
check("  and is given as the folder itself, for a rule on that one path",
      discover.folders_above_grants({"/Users/alice/src", "/Users/alice/src/app/build", "/Users/alice"}, wide,
                                    is_dir=lambda p: True) == ["/Users/alice/src"])
check("  whose rule names the path, not what is under it",
      discover.folder_rule('/a/b"c') == '(allow file-read* (literal "/a/b\\"c"))')
check("a file in the temporary folder is granted by itself, not all of /private/tmp",
      collapse({"/private/tmp/x.lock"}) == ["/private/tmp/x.lock"])
check("the root folder is never a grant", collapse({"/x"}) == ["/x"] and "/" not in collapse({"/x", "/"}))
check("a too-wide folder that was refused itself is left out",
      collapse({"/Users/alice", "/Users/alice/Library", "/usr"}) == [])

with tempfile.TemporaryDirectory() as tmp:
    # Refused paths are resolved, so a home folder behind a symbolic link must be too wide
    # under its real name as well.
    real_home = os.path.join(os.path.realpath(tmp), "real")
    os.makedirs(real_home)
    os.symlink(real_home, os.path.join(tmp, "link"))
    linked = discover.wide_folders(os.path.join(tmp, "link"))
    check("a file in a home folder behind a symbolic link does not grant the home folder",
          discover.minimal_dirs({real_home + "/.gitconfig", real_home + "/Library/x.plist"}, linked,
                                is_dir=lambda p: False)
          == [real_home + "/.gitconfig", real_home + "/Library/x.plist"])

print("== paths in a tool's own error lines ==")
check("in double quotes", discover.paths_in_error_line('open "/a/b c" failed: Operation not permitted') == ["/a/b c"])
check("in single quotes",
      discover.paths_in_error_line("git: error: developer directory '/Applications/Xcode.app/Contents/Developer' isn't accessible (errno=Operation not permitted)")
      == ["/Applications/Xcode.app/Contents/Developer"])
check("bare, before the error text",
      discover.paths_in_error_line("cat: /Users/alice/x y/in.txt: Operation not permitted") == ["/Users/alice/x y/in.txt"])
check("  and after a tool's prefix with a colon",
      discover.paths_in_error_line("sh: line 1: /opt/tool/run: Permission denied") == ["/opt/tool/run"])
check("no path, nothing", discover.paths_in_error_line("Operation not permitted") == [])

print("== profile text ==")
with tempfile.TemporaryDirectory() as tmp:
    sbpl = os.path.join(tmp, "p.sb")
    discover.write_sbpl(sbpl, ['/tmp/a"b'], ["/tmp/c\\d"])
    text = open(sbpl).read()
    check("a quote in a folder name is escaped", '(subpath "/tmp/a\\"b")' in text, text)
    check("a backslash is escaped", '(subpath "/tmp/c\\\\d")' in text, text)

print("== option errors ==")
r = run(["--loop", "--native", "--", "/usr/bin/true"])
check("--loop with --native is refused", r.returncode == 2 and "--loop cannot be combined" in r.stderr, r.stderr[-200:])
r = run(["/usr/bin/true"])
check('a command without "--" is refused', r.returncode == 2 and "separator is required" in r.stderr, r.stderr[-200:])

r = run(["--native", "--", tempfile.gettempdir()])
check("a command that cannot be started is an error, not a traceback",
      r.returncode == 1 and "error: cannot" in r.stderr and "Traceback" not in r.stderr, r.stderr[-300:])


def children_of(pid):
    listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
    rows = [line.split() for line in listing.splitlines()]
    return [int(row[0]) for row in rows if len(row) == 2 and row[1] == str(pid)]


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def interrupted_run(delay, profile):
    """Interrupt the tool `delay` seconds into a run of a long command. Returns its exit status
    and those of its child processes (the log stream, the command) that are still running."""
    tool = subprocess.Popen([sys.executable, str(DISCOVER), "-o", profile, "--", "/bin/sleep", "60"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(delay)
    started = children_of(tool.pid)
    tool.send_signal(signal.SIGINT)
    try:
        status = tool.wait(timeout=30)
    except subprocess.TimeoutExpired:
        tool.kill()
        status = None
    time.sleep(0.5)
    left = [pid for pid in started if alive(pid)]
    for pid in left:
        os.kill(pid, signal.SIGKILL)
    return status, started, left


probe = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                       capture_output=True)
if probe.returncode != 0:
    print("== live runs: skipped (sandbox-exec cannot apply a profile here: already in a sandbox) ==")
else:
    # Work in the home folder: the baseline profile grants nothing there, and the per-user
    # temporary folder is where the shell itself looks.
    work = tempfile.mkdtemp(prefix=".sandbox-discover-test-", dir=os.path.expanduser("~"))
    try:
        os.makedirs(os.path.join(work, "in"))
        os.makedirs(os.path.join(work, "out"))
        source = os.path.join(work, "in", "data.txt")
        target = os.path.join(work, "out", "copy.txt")
        with open(source, "w") as f:
            f.write("data\n")
        job = os.path.join(work, "in", "job.sh")
        with open(job, "w") as f:
            f.write(f"#!/bin/sh\n/bin/cat '{source}' > /dev/null || exit 4\n/bin/cp '{source}' '{target}' || exit 5\nexit 0\n")
        profile = os.path.join(work, "profile.json")
        real = os.path.realpath(work)

        print("== a single run ==")
        r = run(["-o", profile, "--", "/bin/sh", job])
        found = json.load(open(profile))
        check("it exits with the command's status", r.returncode != 0, str(r.returncode))
        check("  and writes the folder the command was refused",
              os.path.join(real, "in") in found.get("read_only", []), json.dumps(found))

        print("== loop mode ==")
        os.path.exists(target) and os.remove(target)
        r = run(["--loop", "-o", profile, "--", "/bin/sh", job])
        found = json.load(open(profile))
        check("the job ends up succeeding", r.returncode == 0 and os.path.exists(target), r.stdout[-400:])
        check("the folder it reads is read-only", os.path.join(real, "in") in found.get("read_only", []), json.dumps(found))
        check("the folder it writes is read-write", os.path.join(real, "out") in found.get("read_write", []), json.dumps(found))
        check("  and not listed as read-only too", os.path.join(real, "out") not in found.get("read_only", []))
        check("the home folder is not granted", os.path.expanduser("~") not in found.get("read_only", []) + found.get("read_write", []))

        print("== --json ==")
        os.remove(target)
        r = run(["--loop", "--json", "-o", profile, "--", "/bin/sh", job])
        events = [json.loads(line) for line in r.stderr.splitlines() if line.startswith("{")]
        kinds = [e.get("event") for e in events]
        # A "check" event follows the passes when a refusal came from a process too short-lived to
        # be seen as the job's own (cp here, at times): the folder is then verified by a run without it.
        check("pass events, perhaps a check, then done",
              len(kinds) >= 2 and kinds[-1] == "done" and "pass" in kinds and set(kinds[:-1]) <= {"pass", "check"}, str(kinds))
        check("  done says success and names the profile",
              events and events[-1].get("stopped") == "success" and events[-1].get("profile") == os.path.realpath(profile),
              str(events[-1] if events else None))
        last_pass = [e for e in events if e.get("event") == "pass"][-1:] or [{}]
        check("  the last pass lists what was refused and not needed", "not_needed" in last_pass[0], str(last_pass[0]))
        check("  a folder kept unverified is one of the job's own",
              all(d.startswith(real) or d.startswith("/bin/") for d in events[-1].get("unverified", [])),
              str(events[-1].get("unverified")))
        check("  nothing on standard output", r.stdout == "", r.stdout[:200])

        print("== an interrupt ==")
        status, started, left = interrupted_run(0.6, profile)
        check("before the command starts: status 130 and the log stream is stopped",
              status == 130 and len(started) >= 1 and left == [], f"{status} {started} {left}")
        status, started, left = interrupted_run(4.0, profile)
        check("while the command runs: status 130, the log stream and the command are stopped",
              status == 130 and len(started) >= 2 and left == [], f"{status} {started} {left}")

        print("== a failure no folder fixes ==")
        r = run(["--loop", "--json", "-o", profile, "--", "/usr/bin/false"])
        events = [json.loads(line) for line in r.stderr.splitlines() if line.startswith("{")]
        check("it stops with status 3", r.returncode == 3, str(r.returncode))
        check("  saying nothing new was refused, or that the passes ran out",
              events and events[-1].get("stopped") in ("no-new-paths", "max-passes"), str(events[-1] if events else None))
    finally:
        subprocess.run(["/bin/rm", "-rf", work])

print(f"\n{passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
