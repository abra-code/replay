"""Extended attribute access for the Python test suites, on macOS and Linux.

The tests name xattrs by their macOS names (public.fingerprint.crc32c and so
on). On Linux replay stores the same names with the "user." prefix, which the
kernel requires for unprivileged attributes; these helpers add and strip it, so
callers compare macOS names on both platforms.

macOS has no os.getxattr, so there the helpers read through /usr/bin/xattr.
Both routes follow symlinks, as /usr/bin/xattr does without -s.
"""

import os
import subprocess
import sys

IS_LINUX = sys.platform.startswith("linux")
PLATFORM_PREFIX = "user." if IS_LINUX else ""


def xattr_names(path) -> list:
    """The xattr names on path, by their macOS names; [] if there are none or
    the file cannot be read."""
    if IS_LINUX:
        try:
            names = os.listxattr(str(path))
        except OSError:
            return []
        return [n[len(PLATFORM_PREFIX):] for n in names if n.startswith(PLATFORM_PREFIX)]
    proc = subprocess.run(["/usr/bin/xattr", str(path)],
                          capture_output=True, text=True, timeout=10)
    return proc.stdout.split()


def get_xattr(path, name: str):
    """The value of the xattr with macOS name `name` on path, as bytes, or None
    when it is missing or cannot be read."""
    if IS_LINUX:
        try:
            return os.getxattr(str(path), PLATFORM_PREFIX + name)
        except OSError:
            return None
    proc = subprocess.run(["/usr/bin/xattr", "-px", name, str(path)],
                          capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        return None
    try:
        return bytes.fromhex(proc.stdout.replace(" ", "").replace("\n", ""))
    except ValueError:
        return None
