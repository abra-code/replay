#!/usr/bin/env python3
"""
sandbox_terminal_check.py - used by test_sandbox_linux.sh (section 13).

Runs a sandboxed replay whose descriptors 0 to 2 are one pseudo-terminal ("own"), while
a second pseudo-terminal ("other") stands for another terminal of the user. A step
writes to its own terminal by name, which must work, and opens the other one for
writing and for reading, which the sandbox must refuse.

Usage: sandbox_terminal_check.py /path/to/replay /granted/folder
Prints the step's result lines (OWN-WRITE-..., OTHER-WRITE-..., OTHER-READ-...).
"""

import json
import os
import pty
import select
import subprocess
import sys


def main() -> int:
    replay, granted = sys.argv[1], sys.argv[2]
    other_master, other_slave = pty.openpty()
    other_name = os.ttyname(other_slave)
    own_master, own_slave = pty.openpty()
    own_name = os.ttyname(own_slave)

    # The markers are split with '' so that the command text itself never contains them,
    # should replay ever echo it (--verbose, an error message).
    command = (f"echo hello > {own_name} && echo OWN-WRITE-ALL''OWED || echo OWN-WRITE-REF''USED; "
               f"echo x > {other_name} && echo OTHER-WRITE-ALL''OWED || echo OTHER-WRITE-REF''USED; "
               f"head -c 0 < {other_name} && echo OTHER-READ-ALL''OWED || echo OTHER-READ-REF''USED")
    playlist = os.path.join(granted, "terminal_check.json")
    with open(playlist, "w") as f:
        json.dump([{"action": "execute", "tool": "/bin/sh", "arguments": ["-c", command]}], f)

    proc = subprocess.Popen([replay, "--allow-write", granted, playlist],
                            stdin=own_slave, stdout=own_slave, stderr=own_slave)
    os.close(own_slave)
    text = b""
    try:
        while True:
            ready, _, _ = select.select([own_master], [], [], 20)
            if not ready:
                break
            try:
                chunk = os.read(own_master, 4096)
            except OSError:
                break  # EIO: every writer of the terminal is gone
            if not chunk:
                break
            text += chunk
        proc.wait(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        for fd in (own_master, other_master, other_slave):
            os.close(fd)
    print(text.decode(errors="replace").replace("\r", ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
