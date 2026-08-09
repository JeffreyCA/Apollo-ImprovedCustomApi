#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB command to a thin 64-bit Mach-O.

WHY THIS EXISTS. `scripts/run-in-sim.sh` used to load the tweak purely through
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES, which sets DYLD_INSERT_LIBRARIES in the
environment of the one process `simctl launch` spawns. Environment variables
belong to a process, not to an app, so quitting Apollo and relaunching it from
the home screen gave you stock Apollo with none of the tweak loaded. Writing a
real load command into the app binary makes the tweak load however the app is
started, which is what the device path already does.

`install_name_tool` can rewrite and add rpaths but cannot ADD a load command,
and this repo does not depend on insert_dylib/optool, so this does the edit
directly — in the same spirit as the LC_BUILD_VERSION platform patch the sim
script already applies.

The edit is written into the zero padding that sits between the end of the load
commands and the start of the first section, so nothing in the file moves and
every existing offset stays valid. That padding is finite: if there is not
enough room, this exits non-zero rather than corrupting the binary, and the
caller is expected to fall back.

Usage:  macho-add-load-dylib.py <binary> <dylib-path>
Exit:   0 added (or already present), 1 refused / not applicable.
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGICS = (0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA)

LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD

DYLIB_COMMAND_SIZE = 24  # cmd, cmdsize, name offset, timestamp, current, compat
HEADER_SIZE = 64  # mach_header_64


def fail(message):
    print(f"  macho-add-load-dylib: {message}", file=sys.stderr)
    return 1


def add_load_dylib(path, dylib_path):
    with open(path, "rb") as handle:
        data = bytearray(handle.read())

    if len(data) < HEADER_SIZE:
        return fail(f"{path}: too small to be a Mach-O")

    magic = struct.unpack("<I", data[0:4])[0]
    if magic in FAT_MAGICS:
        return fail(f"{path}: fat binary; thin it first")
    if magic != MH_MAGIC_64:
        return fail(f"{path}: not a 64-bit little-endian Mach-O")

    ncmds, sizeofcmds = struct.unpack("<II", data[16:24])

    # Walk the existing commands for two things: whether this dylib is already
    # loaded (so a re-run is a no-op), and where __TEXT's first section starts,
    # which is the hard ceiling for the padding we are about to write into.
    offset = 32
    first_section_offset = len(data)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
        if cmdsize == 0:
            return fail(f"{path}: zero-length load command; refusing to edit")

        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_offset = struct.unpack("<I", data[offset + 8:offset + 12])[0]
            start = offset + name_offset
            end = data.find(b"\x00", start, offset + cmdsize)
            existing = data[start:end if end != -1 else offset + cmdsize].decode(
                "utf-8", "replace")
            if existing == dylib_path:
                print(f"  {path.split('/')[-1]}: already loads {dylib_path}")
                return 0

        if cmd == LC_SEGMENT_64:
            segname = data[offset + 8:offset + 24].rstrip(b"\x00").decode("utf-8", "replace")
            if segname == "__TEXT":
                nsects = struct.unpack("<I", data[offset + 64:offset + 68])[0]
                sect = offset + 72
                for _ in range(nsects):
                    sect_offset = struct.unpack("<I", data[sect + 48:sect + 52])[0]
                    if sect_offset:
                        first_section_offset = min(first_section_offset, sect_offset)
                    sect += 80

        offset += cmdsize

    name_length = len(dylib_path.encode("utf-8")) + 1
    cmdsize = (DYLIB_COMMAND_SIZE + name_length + 7) & ~7

    insert_at = 32 + sizeofcmds
    if insert_at + cmdsize > first_section_offset:
        return fail(
            f"{path}: only {first_section_offset - insert_at} bytes of header padding, "
            f"need {cmdsize}")

    # Refuse unless the space really is unused. Anything non-zero here means the
    # file is not laid out the way this assumes, and overwriting it would corrupt
    # the binary in a way that is painful to diagnose.
    if any(data[insert_at:insert_at + cmdsize]):
        return fail(f"{path}: header padding is not zero-filled; refusing to edit")

    command = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        DYLIB_COMMAND_SIZE,  # name offset, immediately after the fixed fields
        0,                   # timestamp
        0x10000,             # current_version 1.0.0
        0x10000,             # compatibility_version 1.0.0
    ) + dylib_path.encode("utf-8") + b"\x00" * (cmdsize - DYLIB_COMMAND_SIZE - name_length + 1)

    data[insert_at:insert_at + cmdsize] = command
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)

    with open(path, "wb") as handle:
        handle.write(data)

    print(f"  {path.split('/')[-1]}: added LC_LOAD_DYLIB {dylib_path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(add_load_dylib(sys.argv[1], sys.argv[2]))
