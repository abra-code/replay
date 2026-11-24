#!/usr/bin/env python3
"""
sandbox_shm_probe.py - used by test_sandbox_linux.sh (section 15).

Runs inside the sandbox as a step's command. Uses POSIX shared memory and named
semaphores, which live in /dev/shm, the way Python's multiprocessing does, and tries
to make a folder there, which the sandbox must refuse (it grants files only).

Usage: sandbox_shm_probe.py
Prints one line per check: LOCK-OK or LOCK-FAILED, SHM-OK or SHM-FAILED,
DIR-REFUSED, DIR-MADE or DIR-FAILED.
"""

import errno
import multiprocessing
import os
from multiprocessing import shared_memory


def main() -> int:
    # The markers are split with '' so that the command text itself never contains them.
    try:
        lock = multiprocessing.Lock()
        lock.acquire()
        lock.release()
        print("LOCK" + "-OK")
    except OSError as error:
        print("LOCK" + "-FAILED " + str(error))

    try:
        block = shared_memory.SharedMemory(create=True, size=64)
        block.buf[0] = 42
        again = shared_memory.SharedMemory(name=block.name)
        value = again.buf[0]
        again.close()
        block.close()
        block.unlink()
        print("SHM" + ("-OK" if value == 42 else "-FAILED read back " + str(value)))
    except OSError as error:
        print("SHM" + "-FAILED " + str(error))

    folder = "/dev/shm/replay-sandbox-probe-" + str(os.getpid())
    try:
        os.mkdir(folder)
        os.rmdir(folder)
        print("DIR" + "-MADE")
    except OSError as error:
        print("DIR" + ("-REFUSED" if error.errno == errno.EACCES else "-FAILED " + str(error)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
