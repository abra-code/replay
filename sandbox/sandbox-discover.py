#!/usr/bin/env python3
"""
sandbox-discover — capture sandbox violations for a command and emit a profile.

Two modes:

  Default (sandbox-exec mode):
    Wraps COMMAND with sandbox-exec using a minimal baseline-only policy.
    Every file access outside bsd.sb becomes a violation. Use this for
    arbitrary commands that have no built-in sandbox support.

  Native mode (-n / --native):
    Runs COMMAND directly without any wrapper. Use this when the command
    applies its own sandbox (e.g. replay/gate with --sandbox-profile or
    --allow-write). Violations from the tool's own sandbox appear
    in the system log just like those from sandbox-exec.

Usage:
  sandbox-discover.py [-o profile.json] [-v] [-n] -- COMMAND [ARGS...]

  The -- is required before COMMAND (to distinguish its args from sandbox-discover options).

Requirements:
  - sandbox-exec (/usr/bin/sandbox-exec, macOS built-in; default mode only)
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
import time

LINE_RE = re.compile(r'\((\d+)\) deny\(\d+\)\s+(\S+)\s+(/.+)')
DENIED_RE = re.compile(
    r'\b(?:not permitted|permission denied|don[\'\"]t have permission)\b',
    re.IGNORECASE
)
WRITE_OP_RE = re.compile(r'\b(?:creat|write|save)\w*\b', re.IGNORECASE)
PATH_RE = re.compile(r'"(/[^"]+)"')


def minimal_dirs(paths):
    """Collapse a set of file paths to the minimal set of parent directories."""
    dirs = sorted({os.path.dirname(p) for p in paths if p})
    result = []
    for d in dirs:
        if d and not any(d == r or d.startswith(r + '/') for r in result):
            result.append(d)
    return sorted(result)


def covered_by(path, dir_list):
    return any(path == d or path.startswith(d + '/') for d in dir_list)


def create_minimal_sbpl(path):
    with open(path, 'w') as f:
        f.write("""(version 1)
(debug deny)
(import "bsd.sb")
(allow process-exec*)
(allow process-fork)
(allow network*)
""")


def collect_pids(root_pid):
    """Recursively collect child PIDs."""
    pids = {root_pid}
    try:
        result = subprocess.run(
            ['pgrep', '-P', str(root_pid)],
            capture_output=True,
            text=True
        )
        for line in result.stdout.split():
            if line.strip().isdigit():
                child = int(line.strip())
                pids.add(child)
                pids.update(collect_pids(child))
    except subprocess.CalledProcessError:
        pass
    return pids


def run_command(command, native_mode, sbpl_file):
    """Run the command and return exit code."""
    if native_mode:
        cmd_args = command
    else:
        cmd_args = ['/usr/bin/sandbox-exec', '-f', sbpl_file] + command

    print(f"Running {'with native sandboxing' if native_mode else 'under minimal sandbox'}: "
          f"{' '.join(command)}")
    print("(errors and failures are expected during discovery)\n")

    result = subprocess.run(cmd_args)
    return result.returncode


def process_log_and_stderr(log_file, pids, stderr_file, verbose):
    """Process log file and stderr to extract violation paths."""
    read_paths = set()
    write_paths = set()
    total_lines = 0
    total_skipped_pid = 0
    total_file_violations = 0

    with open(log_file) as f:
        for line in f:
            total_lines += 1
            m = LINE_RE.search(line)
            if m is None:
                continue
            pid = int(m.group(1))
            operation = m.group(2)
            path = m.group(3).rstrip()

            if pids and pid not in pids:
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
                write_paths.add(path)
            else:
                read_paths.add(path)

    pid_note = (f", {total_skipped_pid} skipped (other processes)"
                if total_skipped_pid else "")
    print(f"  {total_lines} log lines scanned, "
          f"{total_file_violations} file violation(s) from system log{pid_note}")

    stderr_read_count = 0
    stderr_write_count = 0

    try:
        with open(stderr_file) as f:
            for line in f:
                if not DENIED_RE.search(line):
                    continue
                for m in PATH_RE.finditer(line):
                    path = m.group(1)
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
        print(f"  {stderr_total} additional path(s) from stderr "
              f"({stderr_read_count} read, {stderr_write_count} write)")

    return read_paths, write_paths


def main():
    parser = argparse.ArgumentParser(
        description='Run a command under a minimal sandbox, capture any file access violations, '
                    'and emit a JSON sandbox policy profile that grants the required permissions. '
                    'The profile contains "read_only" directories (files the command reads) and '
                    '"read_write" directories (files the command creates or modifies). '
                    'Use this profile with replay/gate --sandbox-profile to grant permissions '
                    'without triggering sandbox violations.',
        usage='sandbox-discover.py [-o profile.json] [-v] [-n] -- COMMAND [ARGS...]',
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

    args, unknown = parser.parse_known_args()

    if '--' not in sys.argv:
        parser.error("the '--' separator is required before COMMAND. "
                     "Use '--' to separate sandbox-discover options from the command and its arguments.")

    sep_idx = sys.argv.index('--')
    command = sys.argv[sep_idx + 1:]
    if not command:
        parser.error("COMMAND argument is required after '--'")

    args.output = os.path.abspath(args.output)

    command_binary = command[0]
    if not command_binary.startswith('/'):
        result = subprocess.run(
            ['command', '-v', command_binary],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            command_binary = result.stdout.strip()
        else:
            print(f"error: cannot find executable: {command[0]}", file=sys.stderr)
            sys.exit(1)

    if not os.access(command_binary, os.X_OK):
        print(f"error: not executable: {command_binary}", file=sys.stderr)
        sys.exit(1)

    tmpdir = tempfile.mkdtemp(prefix='sandbox_discover_')

    try:
        sbpl_file = os.path.join(tmpdir, 'sbpl')
        log_file = os.path.join(tmpdir, 'log')
        pids_file = os.path.join(tmpdir, 'pids')
        stderr_file = os.path.join(tmpdir, 'stderr')
        stdout_file = os.path.join(tmpdir, 'stdout')

        if not args.native:
            create_minimal_sbpl(sbpl_file)

        import time
        log_start = time.strftime('%Y-%m-%d %H:%M:%S')

        if args.native:
            cmd_args = command
        else:
            cmd_args = ['/usr/bin/sandbox-exec', '-f', sbpl_file] + command

        print(f"Running {'with native sandboxing' if args.native else 'under minimal sandbox'}: "
              f"{' '.join(command)}")
        print("(errors and failures are expected during discovery)\n")

        stdout_handle = open(stdout_file, 'w') if args.verbose else None

        with open(pids_file, 'w') as pf, open(stderr_file, 'w') as sf:
            process = subprocess.Popen(
                cmd_args,
                stdout=stdout_handle if args.verbose else subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True
            )
            print(process.pid, file=pf)
            pf.flush()

            stderr_lines = []
            for line in process.stderr:
                print(line, end='', file=sf)
                stderr_lines.append(line)

            exit_code = process.wait()

        if stdout_handle:
            stdout_handle.close()

        print("\nWaiting for the kernel to flush violation records to the unified log...")
        time.sleep(4)

        print("\nCollecting violations from system log...")
        with open(log_file, 'w') as lf:
            subprocess.run(
                [
                    '/usr/bin/log', 'show',
                    '--predicate', 'subsystem == "com.apple.sandbox" || sender == "Sandbox"',
                    '--start', log_start,
                    '--style', 'compact'
                ],
                stdout=lf,
                stderr=subprocess.DEVNULL
            )

        print("Processing violations...")

        root_pid = None
        try:
            with open(pids_file) as f:
                first_line = f.readline().strip()
                if first_line.isdigit():
                    root_pid = int(first_line)
        except OSError:
            pass

        tracked_pids = set()
        if root_pid:
            tracked_pids = collect_pids(root_pid)

        read_paths, write_paths = process_log_and_stderr(
            log_file,
            tracked_pids,
            stderr_file,
            args.verbose
        )

        write_dirs = minimal_dirs(write_paths)
        read_only_dirs = [
            d for d in minimal_dirs(read_paths)
            if not covered_by(d, write_dirs)
        ]

        if args.verbose:
            print()
            print("Write violations:")
            for p in sorted(write_paths)[:30]:
                print(f"  {p}")
            if len(write_paths) > 30:
                print(f"  ... ({len(write_paths)} total)")
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

        with open(args.output, 'w') as f:
            json.dump(profile, f, indent=2)
            f.write('\n')

        print()
        print(f"Profile written to: {args.output}")
        if read_only_dirs:
            print(f"  read_only  ({len(read_only_dirs)} dirs):")
            for d in read_only_dirs:
                print(f"    {d}")
        if write_dirs:
            print(f"  read_write ({len(write_dirs)} dirs):")
            for d in write_dirs:
                print(f"    {d}")
        if not read_only_dirs and not write_dirs:
            print("  (no file violations recorded from system log or stderr)")

        if args.verbose:
            print()
            print(f"Raw log output: {log_file}")
            print(f"Stderr capture: {stderr_file}")
            print(f"Stdout capture: {stdout_file}")
            print(f"(temp directory not removed for inspection)")
            sys.exit(exit_code)

        sys.exit(exit_code)
    finally:
        if not args.verbose:
            shutil.rmtree(tmpdir)


if __name__ == '__main__':
    main()