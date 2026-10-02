#!/usr/bin/env python3
"""
sandbox-discover — capture sandbox violations for a command and emit a profile.

Three modes:

  Default (sandbox-exec mode):
    Wraps COMMAND with sandbox-exec using a minimal baseline-only policy.
    Every file access outside bsd.sb becomes a violation. Use this for
    arbitrary commands that have no built-in sandbox support. One run: a
    denied operation usually fails, so the command may stop at its first
    refusal and the profile holds only what it reached.

  Loop mode (--loop [N]):
    The same, repeated: each pass runs COMMAND under the baseline plus the
    folders found so far, until the command succeeds, a pass finds nothing
    new, or N passes ran (default 8). What a successful pass was still
    refused is reported, not granted: the command did not need it. This is how a
    profile for a real workflow (a build, a test run) is found: each pass
    gets one layer further.

  Native mode (-n / --native):
    Runs COMMAND directly without any wrapper. Use this when the command
    applies its own sandbox (e.g. replay/gate with --sandbox-profile or
    --allow-write). Violations from the tool's own sandbox appear
    in the system log just like those from sandbox-exec.

Usage:
  sandbox-discover.py [-o profile.json] [-v] [-n | --loop [N]] [--json]
                      [--allow-read DIR]... [--allow-write DIR]... -- COMMAND [ARGS...]

  The -- is required before COMMAND (to distinguish its args from sandbox-discover options).

Requirements:
  - sandbox-exec (/usr/bin/sandbox-exec, macOS built-in; not in native mode)
  - log         (/usr/bin/log, macOS built-in)
  - python3
  - No sudo required.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

LINE_RE = re.compile(r'\((\d+)\) deny\(\d+\)\s+(\S+)\s+(/.+)')
DENIED_RE = re.compile(
    r'\b(?:not permitted|permission denied|don[\'\"]t have permission)\b',
    re.IGNORECASE
)
WRITE_OP_RE = re.compile(r'\b(?:creat|write|save)\w*\b', re.IGNORECASE)
# A path in a tool's own error line: in double or single quotes ("developer directory '/x' isn't
# accessible"), or bare before the error text ("cat: /x/y: Operation not permitted").
PATH_RES = (
    re.compile(r'"(/[^"]+)"'),
    re.compile(r"'(/[^']+)'"),
    re.compile(r'(?:^|:\s)(/[^:\n]+?):\s+(?:operation not permitted|permission denied)', re.IGNORECASE),
)


def paths_in_error_line(line):
    found = []
    for pattern in PATH_RES:
        for m in pattern.finditer(line):
            if m.group(1) not in found:
                found.append(m.group(1))
    return found

DEFAULT_LOOP_PASSES = 8
# The violation records are read from a live `log stream` started before the command: on
# macOS 27 a `log show` just after the run misses records the stream delivers. The stream needs
# a moment to attach before the command starts, and the last records a moment to arrive after it.
LOG_ATTACH_SECONDS = 1.5
LOG_FLUSH_SECONDS = 2
# Candidate folders are checked one at a time, each with a run of the command, up to this many.
MAX_CANDIDATE_CHECKS = 12
LOG_PREDICATE = 'subsystem == "com.apple.sandbox" || sender == "Sandbox"'


def wide_folders(home):
    """Folders too broad to grant because one file inside was refused: granting the parent of
    ~/.gitconfig would grant the whole home folder. A path directly inside one of these is
    granted by itself instead."""
    wide = {'/', '/Applications', '/Library', '/System', '/Users', '/Volumes', '/bin', '/dev',
            '/etc', '/opt', '/private', '/private/etc', '/private/var', '/sbin', '/usr',
            '/usr/bin', '/usr/local', '/usr/sbin', '/var',
            '/tmp', '/private/tmp', '/private/var/tmp', '/private/var/folders', '/var/folders'}
    # Refused paths are compared in their resolved form, so a home folder reached through a
    # symbolic link is listed under both names.
    for home in sorted({home, os.path.realpath(home)} if home else ()):
        wide.add(home)
        for name in ('Library', 'Library/Application Support', 'Library/Caches',
                     'Library/Preferences', 'Library/Containers', 'Library/Group Containers',
                     'Documents', 'Desktop', 'Downloads', 'Movies', 'Music', 'Pictures',
                     '.config', '.cache', '.local', '.local/share'):
            wide.add(os.path.join(home, name))
    return wide


def minimal_dirs(paths, wide=frozenset(), is_dir=os.path.isdir):
    """Collapse a set of refused paths to the minimal set of folders to grant: a file's parent
    folder; the path itself when it is a folder (a refused folder asks for that folder, not for
    its siblings) or when its parent is in `wide`; then drop any folder inside another. A
    refused path that is itself in `wide` is left out, and so is a refused folder that has a
    grant under it."""
    grants = set()
    refused_folders = set()
    for p in paths:
        # A too-wide folder is never granted because it was refused itself (a shell that looks
        # at its home folder, say): that is a decision for a person, not for a recording.
        if not p or p in wide:
            continue
        parent = os.path.dirname(p)
        if is_dir(p):
            refused_folders.add(p)
        elif not parent or parent in wide:
            grants.add(p)
        else:
            grants.add(parent)
    # A refused folder is granted, unless something under it is granted already: a tool that
    # looks at the folders above its own (git does) would otherwise turn a grant of one project
    # into a grant of everything beside it.
    for folder in refused_folders:
        if not any(g.startswith(folder + '/') for g in grants | refused_folders):
            grants.add(folder)
    result = []
    for d in sorted(grants):
        if d and d != '/' and not any(d == r or d.startswith(r + '/') for r in result):
            result.append(d)
    return sorted(result)


def folders_above_grants(paths, wide=frozenset(), is_dir=os.path.isdir):
    """The refused folders that minimal_dirs leaves out because something under them is granted.
    A tool that was refused such a folder wanted the folder itself (to look at it, to list it),
    so it gets that and no more: a rule for that one path, not for what is inside."""
    paths = {p for p in paths if p}
    folders = {p for p in paths if p not in wide and is_dir(p)}
    return sorted(f for f in folders if any(q.startswith(f + '/') for q in paths))


def covered_by(path, dir_list):
    return any(path == d or path.startswith(d + '/') for d in dir_list)


def sbpl_string(text):
    """An SBPL string literal: backslashes and double quotes escaped, so a crafted folder name
    cannot end the string and add rules of its own."""
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def folder_rule(folder):
    """The rule that lets a folder itself be read, not what is inside it."""
    return f'(allow file-read* (literal {sbpl_string(folder)}))'


def write_sbpl(path, read_dirs=(), write_dirs=(), folder_only=()):
    """The minimal baseline, plus the folders granted so far (loop mode, --allow-*)."""
    lines = ['(version 1)', '(debug deny)', '(import "bsd.sb")',
             '(allow process-exec*)', '(allow process-fork)', '(allow network*)']
    for d in folder_only:
        lines.append(folder_rule(d))
    for d in read_dirs:
        lines.append(f'(allow file-read* (subpath {sbpl_string(d)}))')
    for d in write_dirs:
        lines.append(f'(allow file-read* file-write* (subpath {sbpl_string(d)}))')
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


class DiscoverError(Exception):
    """The run cannot be done at all: the system log cannot be read, or the command cannot be
    started."""


def all_pids():
    """Every process id on the system now."""
    try:
        result = subprocess.run(['/bin/ps', '-axo', 'pid='], capture_output=True, text=True)
    except OSError:
        return set()
    return {int(word) for word in result.stdout.split() if word.isdigit()}


class DescendantWatcher(threading.Thread):
    """Collects the pids of a process's descendants WHILE it runs. Asked after it exited, the
    system knows none of them, and a build's refusals come almost entirely from its children.

    The kernel tells of each fork (kqueue's NOTE_FORK on every process already known), and the
    forking process's children are listed at once (libproc's proc_listchildpids), so a child
    that lives only milliseconds (cp, a compiler) is usually seen. A slower look at the whole
    process table backs that up. A child gone before either look is still missed, which is why
    a refusal from an unknown NEW process is kept as a candidate (process_log_and_stderr)."""

    def __init__(self, root_pid, interval=0.1):
        super().__init__(daemon=True)
        self.root_pid = root_pid
        self.interval = interval
        self.pids = {root_pid}
        self._stop_event = threading.Event()
        self._kqueue = None
        self._libproc = None
        try:
            import ctypes
            import ctypes.util
            import select
            self._ctypes = ctypes
            self._select = select
            self._libproc = ctypes.CDLL(ctypes.util.find_library('proc') or '/usr/lib/libproc.dylib')
            self._kqueue = select.kqueue()
            self._watch(root_pid)
        except (OSError, AttributeError, ImportError):
            self._kqueue = None

    def _watch(self, pid):
        """Ask for this process's fork events. One that is already gone is simply not watched."""
        try:
            self._kqueue.control([self._select.kevent(
                pid, filter=self._select.KQ_FILTER_PROC, flags=self._select.KQ_EV_ADD,
                fflags=self._select.KQ_NOTE_FORK)], 0, 0)
        except OSError:
            pass

    def _children(self, pid):
        buffer = (self._ctypes.c_int * 4096)()
        count = self._libproc.proc_listchildpids(pid, buffer, self._ctypes.sizeof(buffer))
        return [buffer[i] for i in range(max(0, min(count, 4096))) if buffer[i] > 0]

    def _adopt(self, parent):
        """Add the parent's children, and theirs, watching each for forks of its own."""
        frontier = [parent]
        while frontier:
            for child in self._children(frontier.pop()):
                if child not in self.pids:
                    self.pids.add(child)
                    self._watch(child)
                    frontier.append(child)

    def run(self):
        last_scan = 0.0
        while not self._stop_event.is_set():
            if self._kqueue is not None:
                try:
                    for ev in self._kqueue.control(None, 64, 0.02):
                        self._adopt(ev.ident)
                except (OSError, ValueError):
                    # ValueError: stop() closed the queue under a thread that outlived its wait.
                    pass
            else:
                self._stop_event.wait(0.02)
            now = time.monotonic()
            if now - last_scan >= self.interval:
                last_scan = now
                self.poll()

    def poll(self):
        try:
            result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid='], capture_output=True, text=True)
        except OSError:
            return
        children = {}
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                children.setdefault(int(parts[1]), []).append(int(parts[0]))
        frontier = list(self.pids)
        while frontier:
            for child in children.get(frontier.pop(), []):
                if child not in self.pids:
                    self.pids.add(child)
                    if self._kqueue is not None:
                        self._watch(child)
                    frontier.append(child)

    def stop(self):
        self._stop_event.set()
        self.join(timeout=2)
        if self._kqueue is not None:
            self._kqueue.close()
        return self.pids


def process_log_and_stderr(log_file, pids, stderr_file, say, earlier_pids=frozenset()):
    """Process log file and stderr to extract violation paths.

    Returns (read, write, maybe_read, maybe_write). The first two are refusals of the command's
    own processes. The "maybe" ones come from a process that is not known to be the command's
    but did not exist before it started: a child too short-lived to be seen, or somebody else's
    new process. A process that existed before the command is somebody else's and is skipped."""
    read_paths = set()
    write_paths = set()
    maybe_read = set()
    maybe_write = set()
    total_lines = 0
    total_skipped_pid = 0
    total_file_violations = 0

    with open(log_file, errors='replace') as f:
        for line in f:
            total_lines += 1
            m = LINE_RE.search(line)
            if m is None:
                continue
            pid = int(m.group(1))
            operation = m.group(2)
            path = m.group(3).rstrip()

            certain = not pids or pid in pids
            if not certain and pid in earlier_pids:
                total_skipped_pid += 1
                continue

            if not operation.startswith('file-'):
                continue

            try:
                path = os.path.realpath(path)
            except OSError:
                pass

            total_file_violations += 1
            if operation.startswith('file-write'):
                (write_paths if certain else maybe_write).add(path)
            else:
                (read_paths if certain else maybe_read).add(path)

    pid_note = (f", {total_skipped_pid} skipped (other processes)"
                if total_skipped_pid else "")
    say(f"  {total_lines} log lines scanned, "
        f"{total_file_violations} file violation(s) from system log{pid_note}")

    stderr_read_count = 0
    stderr_write_count = 0

    try:
        with open(stderr_file, errors='replace') as f:
            for line in f:
                if not DENIED_RE.search(line):
                    continue
                for path in paths_in_error_line(line):
                    try:
                        path = os.path.realpath(path)
                    except OSError:
                        pass
                    if WRITE_OP_RE.search(line):
                        if path not in write_paths:
                            write_paths.add(path)
                            stderr_write_count += 1
                    else:
                        if path not in read_paths:
                            read_paths.add(path)
                            stderr_read_count += 1
    except OSError:
        pass

    stderr_total = stderr_read_count + stderr_write_count
    if stderr_total > 0:
        say(f"  {stderr_total} additional path(s) from stderr "
            f"({stderr_read_count} read, {stderr_write_count} write)")

    maybe_read -= read_paths | write_paths
    maybe_write -= write_paths
    if maybe_read or maybe_write:
        say(f"  {len(maybe_read | maybe_write)} of them from processes not seen as the command's own "
            "(candidates)")
    return read_paths, write_paths, maybe_read, maybe_write


def run_pass(command, native, tmpdir, read_dirs, write_dirs, verbose, say, folder_only=()):
    """One run of the command, and the paths it was refused. Returns (exit code, read paths,
    write paths, candidate read paths, candidate write paths)."""
    sbpl_file = os.path.join(tmpdir, 'sbpl')
    log_file = os.path.join(tmpdir, 'log')
    log_errors_file = os.path.join(tmpdir, 'log_errors')
    stderr_file = os.path.join(tmpdir, 'stderr')
    stdout_file = os.path.join(tmpdir, 'stdout')

    if native:
        cmd_args = command
    else:
        write_sbpl(sbpl_file, read_dirs, write_dirs, folder_only)
        cmd_args = ['/usr/bin/sandbox-exec', '-f', sbpl_file] + command

    log_handle = open(log_file, 'w')
    log_errors = open(log_errors_file, 'w')
    stream = None
    process = None
    watcher = None
    stdout_handle = None
    exit_code = 1
    tracked_pids = set()
    try:
        try:
            stream = subprocess.Popen(
                ['/usr/bin/log', 'stream', '--style', 'compact', '--predicate', LOG_PREDICATE],
                stdout=log_handle, stderr=log_errors)
        except OSError as error:
            raise DiscoverError(f"cannot read the system log: /usr/bin/log did not start ({error})")
        time.sleep(LOG_ATTACH_SECONDS)
        if stream.poll() is not None:
            # Without the stream every pass would report no violations and the profile would
            # come out empty, as if the command needed nothing. `log` refuses to run inside a
            # sandbox, for one.
            log_errors.flush()
            with open(log_errors_file, errors='replace') as f:
                reason = f.read().strip()
            raise DiscoverError("cannot read the system log: /usr/bin/log stream exited with status "
                                f"{stream.returncode}" + (f" ({reason})" if reason else ""))
        earlier_pids = all_pids()
        stdout_handle = open(stdout_file, 'w') if verbose else None
        with open(stderr_file, 'w') as sf:
            try:
                process = subprocess.Popen(
                    cmd_args,
                    stdout=stdout_handle if verbose else subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    text=True,
                    errors='replace'
                )
            except OSError as error:
                raise DiscoverError(f"cannot run {cmd_args[0]}: {error}")
            watcher = DescendantWatcher(process.pid)
            watcher.start()
            for line in process.stderr:
                print(line, end='', file=sf)
            exit_code = process.wait()
            tracked_pids = watcher.stop()
            watcher = None
        say("\nWaiting for the last violation records...")
        time.sleep(LOG_FLUSH_SECONDS)
    finally:
        # Reached on an interrupt or an error too: nothing started here is left running.
        if watcher is not None:
            watcher.stop()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        if stdout_handle:
            stdout_handle.close()
        if stream is not None and stream.poll() is None:
            stream.terminate()
            try:
                stream.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stream.kill()
        log_handle.close()
        log_errors.close()

    say("Processing violations...")
    return (exit_code,) + process_log_and_stderr(log_file, tracked_pids, stderr_file, say, earlier_pids)


def parse_loop(value):
    passes = int(value)
    if passes < 1:
        raise argparse.ArgumentTypeError("--loop takes a number of passes, 1 or more")
    return passes


def main():
    parser = argparse.ArgumentParser(
        description='Run a command under a minimal sandbox, capture any file access violations, '
                    'and emit a JSON sandbox policy profile that grants the required permissions. '
                    'The profile contains "read_only" directories (files the command reads) and '
                    '"read_write" directories (files the command creates or modifies). '
                    'Use this profile with replay/gate --sandbox-profile to grant permissions '
                    'without triggering sandbox violations.',
        usage='sandbox-discover.py [-o profile.json] [-v] [-n | --loop [N]] [--json] '
              '[--allow-read DIR]... [--allow-write DIR]... -- COMMAND [ARGS...]',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('-o', '--output', default='sandbox_profile.json',
                        help='Output JSON file with read_only and read_write directory lists '
                             '(default: sandbox_profile.json)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Print all violation paths and keep temp log files for inspection')
    parser.add_argument('-n', '--native', action='store_true',
                        help='Native mode: run the command without sandbox-exec wrapper. '
                             'Use this when the command itself applies its own sandbox '
                             '(e.g., replay/gate with --sandbox).')
    parser.add_argument('--loop', nargs='?', type=parse_loop, const=DEFAULT_LOOP_PASSES, default=None,
                        metavar='N',
                        help='Loop mode: run the command again under the folders found so far, '
                             'until it succeeds, a pass finds nothing new, '
                             f'or N passes ran (default {DEFAULT_LOOP_PASSES}). Not with --native.')
    parser.add_argument('--json', action='store_true',
                        help='Write progress as JSON events on standard error, one per line, '
                             'and nothing else: a "pass" event after each run and a "done" '
                             'event at the end. The command\'s own output is not shown.')
    parser.add_argument('--allow-read', action='append', default=[], metavar='DIR',
                        help='A folder granted read-only from the first pass (repeatable). '
                             'It is part of the profile written.')
    parser.add_argument('--allow-write', action='append', default=[], metavar='DIR',
                        help='A folder granted read-write from the first pass (repeatable).')

    if '--' not in sys.argv:
        parser.error("the '--' separator is required before COMMAND. "
                     "Use '--' to separate sandbox-discover options from the command and its arguments.")

    sep_idx = sys.argv.index('--')
    args = parser.parse_args(sys.argv[1:sep_idx])
    command = sys.argv[sep_idx + 1:]
    if not command:
        parser.error("COMMAND argument is required after '--'")
    if args.native and args.loop is not None:
        parser.error("--loop cannot be combined with --native: a command that sandboxes itself "
                     "takes its folders from its own arguments, which this tool cannot widen")
    if args.native and (args.allow_read or args.allow_write):
        parser.error("--allow-read and --allow-write cannot be combined with --native")

    args.output = os.path.abspath(args.output)

    def say(text=''):
        if not args.json:
            print(text)

    def event(obj):
        if args.json:
            print(json.dumps(obj, sort_keys=True), file=sys.stderr, flush=True)

    command_binary = command[0]
    if '/' not in command_binary:
        found = None
        for folder in os.environ.get('PATH', '').split(os.pathsep):
            candidate = os.path.join(folder, command_binary)
            if folder and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                found = candidate
                break
        if found is None:
            print(f"error: cannot find executable: {command[0]}", file=sys.stderr)
            sys.exit(1)
        command_binary = found

    if not os.access(command_binary, os.X_OK):
        print(f"error: not executable: {command_binary}", file=sys.stderr)
        sys.exit(1)

    wide = wide_folders(os.path.expanduser('~'))
    read_paths = set()
    write_paths = set()
    # Candidates: refused to a process that may or may not be the command's (run_pass).
    maybe_read = set()
    maybe_write = set()
    given_read = [os.path.realpath(d) for d in args.allow_read]
    given_write = [os.path.realpath(d) for d in args.allow_write]

    def grants(with_candidates):
        writes = write_paths | maybe_write if with_candidates else write_paths
        reads = read_paths | maybe_read if with_candidates else read_paths
        write_dirs = sorted(set(minimal_dirs(writes, wide)) | set(given_write))
        write_dirs = [d for d in write_dirs if not covered_by(d, [w for w in write_dirs if w != d])]
        read_dirs = sorted(set(minimal_dirs(reads, wide)) | set(given_read))
        read_dirs = [d for d in read_dirs
                     if not covered_by(d, write_dirs) and not covered_by(d, [r for r in read_dirs if r != d])]
        return read_dirs, write_dirs

    def folder_only(with_candidates):
        """Refused folders above a grant, given as that one path (folders_above_grants), less
        any that a granted folder covers anyway."""
        refused = read_paths | write_paths
        if with_candidates:
            refused = refused | maybe_read | maybe_write
        read_dirs, write_dirs = grants(with_candidates)
        return [f for f in folders_above_grants(refused, wide) if not covered_by(f, read_dirs + write_dirs)]

    max_passes = args.loop if args.loop is not None else 1
    tmpdir = tempfile.mkdtemp(prefix='sandbox_discover_')
    stopped = 'single-pass'
    exit_code = 0
    passes = 0
    unverified = []
    quiet = args.verbose and not args.json

    try:
        for number in range(1, max_passes + 1):
            passes = number
            # While looking, candidates are granted too: without them the command may never get
            # further. They are checked before they reach the profile (below).
            read_dirs, write_dirs = grants(args.loop is not None)
            only = folder_only(args.loop is not None)
            if args.loop is not None:
                say(f"Pass {number} of at most {max_passes}: "
                    f"{len(read_dirs)} read-only and {len(write_dirs)} read-write folder(s) granted so far")
            say(f"Running {'with native sandboxing' if args.native else 'under minimal sandbox'}: "
                f"{' '.join(command)}")
            say("(errors and failures are expected during discovery)\n")

            exit_code, new_read, new_write, new_maybe_read, new_maybe_write = run_pass(
                command, args.native, tmpdir, read_dirs, write_dirs, quiet, say, only)

            added_write = (new_write | new_maybe_write) - write_paths - maybe_write
            added_read = (new_read | new_maybe_read) - read_paths - maybe_read - new_write
            if args.loop is not None and exit_code == 0:
                # The command succeeded under what was granted. What it was refused on the way
                # it did not need, so it is reported and left out of the profile.
                not_needed = sorted(p for p in added_read | added_write
                                    if not covered_by(p, read_dirs + write_dirs))
                event({'event': 'pass', 'pass': number, 'exit': 0, 'new_read': [], 'new_write': [],
                       'read_only': read_dirs, 'read_write': write_dirs, 'not_needed': not_needed})
                if not_needed:
                    say(f"  {len(not_needed)} path(s) were refused in this pass and not needed; "
                        "they are left out of the profile")
                stopped = 'success'
                break
            write_paths |= new_write
            read_paths |= new_read
            maybe_write |= new_maybe_write - write_paths
            maybe_read |= new_maybe_read - read_paths - write_paths
            after_read, after_write = grants(args.loop is not None)
            grew = (after_read, after_write, folder_only(args.loop is not None)) != (read_dirs, write_dirs, only)
            event({'event': 'pass', 'pass': number, 'exit': exit_code,
                   'new_read': sorted(added_read), 'new_write': sorted(added_write),
                   'read_only': after_read, 'read_write': after_write})

            if args.loop is None:
                break
            if not grew:
                # The command still fails, but nothing new was refused: what stops it is not a
                # folder this tool can find (a service, the network, or the command itself).
                stopped = 'no-new-paths'
                break
            say()
        else:
            stopped = 'max-passes'

        # Candidates reach the profile only when the command needs them: run it once more under
        # the certain folders alone. If that works, the candidates were somebody else's (or not
        # needed) and are dropped; if not, they stay, named as unverified for a person to check.
        if args.loop is not None and grants(True) != grants(False):
            certain_read, certain_write = grants(False)
            # A folder is a candidate when the candidates added it, or raised it from read-only
            # to read-write.
            with_read, with_write = grants(True)
            candidates = sorted((set(with_write) - set(certain_write))
                                | (set(with_read) - set(certain_read) - set(certain_write)))
            if stopped == 'success':
                say(f"\nChecking {len(candidates)} candidate folder(s): running without them")
                passes += 1
                check_code = run_pass(command, False, tmpdir, certain_read, certain_write, quiet, say,
                                      folder_only(False))[0]
                event({'event': 'check', 'pass': passes, 'exit': check_code, 'without': candidates})
                if check_code == 0:
                    say("  the command succeeds without them; they are left out")
                    maybe_read.clear()
                    maybe_write.clear()
                elif len(candidates) > MAX_CANDIDATE_CHECKS:
                    say(f"  the command fails without them, and there are more than {MAX_CANDIDATE_CHECKS} "
                        "to try one by one; they stay in the profile, unverified")
                    unverified = candidates
                else:
                    # Some candidate is needed. Take them away one at a time: one the command
                    # succeeds without is dropped for good, one it fails without is its own.
                    say("  the command fails without them; trying each one")
                    for folder in candidates:
                        without_read = [d for d in grants(True)[0] if d != folder]
                        without_write = [d for d in grants(True)[1] if d != folder]
                        # A folder the candidates only raised to read-write stays readable.
                        if folder in certain_read and folder not in without_read:
                            without_read.append(folder)
                        passes += 1
                        check_code = run_pass(command, False, tmpdir, without_read, without_write, quiet, say,
                                              folder_only(True))[0]
                        event({'event': 'check', 'pass': passes, 'exit': check_code, 'without': [folder]})
                        if check_code == 0:
                            say(f"  not needed: {folder}")
                            for paths in (maybe_read, maybe_write):
                                for path in [p for p in paths if p == folder or covered_by(p, [folder])
                                             or os.path.dirname(p) == folder]:
                                    paths.discard(path)
                        else:
                            say(f"  needed: {folder}")
            else:
                unverified = candidates
            read_paths |= maybe_read
            write_paths |= maybe_write

        read_only_dirs, write_dirs = grants(False)

        if args.verbose and not args.json:
            print()
            print("Write violations:")
            for p in sorted(write_paths)[:30]:
                print(f"  {p}")
            if len(write_paths) > 30:
                print(f"  ... ({len(write_paths)} total)")
            print()
            if maybe_read or maybe_write:
                print("Candidates (a process not seen as the command's own):")
                for p in sorted(maybe_read | maybe_write)[:30]:
                    print(f"  {p}")
                print()
            print("Read violations:")
            for p in sorted(read_paths - write_paths)[:30]:
                print(f"  {p}")
            if len(read_paths - write_paths) > 30:
                print(f"  ... ({len(read_paths - write_paths)} total)")

        profile = {}
        if read_only_dirs:
            profile['read_only'] = read_only_dirs
        if write_dirs:
            profile['read_write'] = write_dirs
        # A folder above a grant, readable as that one path: replay's profile has no key for a
        # single path, so it goes in as a raw rule.
        only_folders = folder_only(False)
        if only_folders:
            profile['extra_rules'] = [folder_rule(d) for d in only_folders]

        with open(args.output, 'w') as f:
            json.dump(profile, f, indent=2)
            f.write('\n')

        event({'event': 'done', 'passes': passes, 'exit': exit_code, 'stopped': stopped,
               'profile': args.output, 'read_only': read_only_dirs, 'read_write': write_dirs,
               'folder_only': only_folders, 'unverified': unverified})

        say()
        if args.loop is not None:
            reasons = {'success': 'the command succeeded',
                       'no-new-paths': f'the command still fails (status {exit_code}), but nothing new was refused',
                       'max-passes': f'{max_passes} passes ran and the last still found something new'}
            say(f"Stopped after {passes} pass(es): {reasons[stopped]}.")
        say(f"Profile written to: {args.output}")
        if read_only_dirs:
            say(f"  read_only  ({len(read_only_dirs)} dirs):")
            for d in read_only_dirs:
                say(f"    {d}")
        if write_dirs:
            say(f"  read_write ({len(write_dirs)} dirs):")
            for d in write_dirs:
                say(f"    {d}")
        if only_folders:
            say(f"  the folder itself, not its contents ({len(only_folders)}):")
            for d in only_folders:
                say(f"    {d}")
        if not read_only_dirs and not write_dirs:
            say("  (no file violations recorded from system log or stderr)")
        if unverified:
            say(f"  unverified ({len(unverified)}): refused to a process that may not be the command's own;")
            say("  check that the command needs them:")
            for d in unverified:
                say(f"    {d}")
        elif args.loop is None and (maybe_read or maybe_write):
            say(f"  not included: {len(maybe_read | maybe_write)} path(s) refused to processes not seen "
                "as the command's own (use --loop to have them checked, -v to list them)")

        if args.verbose and not args.json:
            print()
            print(f"Raw log output: {tmpdir}/log")
            print(f"Stderr capture: {tmpdir}/stderr")
            print(f"Stdout capture: {tmpdir}/stdout")
            print("(temp directory not removed for inspection; the files are the last pass's)")
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(130)
    except DiscoverError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    finally:
        if not (args.verbose and not args.json):
            shutil.rmtree(tmpdir, ignore_errors=True)

    # A single run exits with the command's own status, as before. In loop mode the status says
    # whether a working profile was found: 0, or 3 when the loop stopped short.
    if args.loop is None:
        sys.exit(exit_code)
    sys.exit(0 if stopped == 'success' else 3)


if __name__ == '__main__':
    main()
