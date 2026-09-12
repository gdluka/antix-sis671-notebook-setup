#!/usr/bin/env python3
"""Prepare the text VT used by Linux hibernation, without starting hibernation."""
import argparse
import fcntl
import os
import struct
import subprocess
import sys
import time

VT_GETMODE, VT_SETMODE, VT_GETSTATE = 0x5601, 0x5602, 0x5603
VT_ACTIVATE, VT_UNLOCKSWITCH = 0x5606, 0x560C
KDSETMODE, KDGETMODE = 0x4B3A, 0x4B3B
# Linux MAX_NR_CONSOLES is 63; pm_prepare_console uses its last VT.
HIBERNATE_VT = 63


def read_ioctl(fd, request, fmt):
    data = bytearray(struct.calcsize(fmt))
    fcntl.ioctl(fd, request, data, True)
    return struct.unpack(fmt, data)


def graphics_running():
    for name in ("Xorg", "X", "Xwayland"):
        result = subprocess.run(["pgrep", "-x", name], stdout=subprocess.DEVNULL,
                                timeout=2, check=False)
        if result.returncode == 0:
            return True
        if result.returncode != 1:
            raise RuntimeError("No se pudo comprobar si X sigue activo")
    return False


def switch_to_text(target, wait_seconds=5):
    if graphics_running():
        raise RuntimeError("X sigue activo; no se modifica su consola")
    fd = os.open("/dev/tty0", os.O_RDWR | os.O_NOCTTY)
    try:
        # A dead display server can leave VT_PROCESS / KD_GRAPHICS behind.
        fcntl.ioctl(fd, VT_SETMODE, struct.pack("BBhhh", 0, 0, 0, 0, 0))
        fcntl.ioctl(fd, KDSETMODE, 0)
        fcntl.ioctl(fd, VT_UNLOCKSWITCH, 0)
        target_fd = os.open(f"/dev/tty{target}", os.O_RDWR | os.O_NOCTTY)
        try:
            fcntl.ioctl(target_fd, VT_SETMODE, struct.pack("BBhhh", 0, 0, 0, 0, 0))
            fcntl.ioctl(target_fd, KDSETMODE, 0)
            fcntl.ioctl(fd, VT_ACTIVATE, target)
            deadline = time.monotonic() + wait_seconds
            # Never use VT_WAITACTIVE: it can wait indefinitely on this machine.
            while read_ioctl(fd, VT_GETSTATE, "HHH")[0] != target:
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"No se pudo activar tty{target} en plazo")
                time.sleep(0.1)
            if read_ioctl(target_fd, VT_GETMODE, "BBhhh")[0] != 0:
                raise RuntimeError("La consola no quedo en VT_AUTO")
            if read_ioctl(target_fd, KDGETMODE, "i")[0] != 0:
                raise RuntimeError("La consola no quedo en KD_TEXT")
        finally:
            os.close(target_fd)
    finally:
        os.close(fd)
    print(f"Consola tty{target} activa, VT_AUTO y KD_TEXT verificados", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "restore"))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Se necesitan permisos de administrador")
    try:
        switch_to_text(HIBERNATE_VT if args.action == "prepare" else 1)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
