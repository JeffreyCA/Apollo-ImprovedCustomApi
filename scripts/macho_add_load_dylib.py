#!/usr/bin/env python3
"""Append an LC_LOAD_DYLIB to a Mach-O binary, in place.

Used to wire ApolloOpenInFix.dylib into Apollo's OpenInUIExtension.appex.
`install_name_tool` cannot ADD a new load command, and insert_dylib/optool/LIEF
are not part of this build environment -- but the appex Mach-O has ~22 KB of zero
padding between the end of its load commands and its first section, so a new
LC_LOAD_DYLIB fits with no section shifting and no change in file/slice size.

Safety properties:
  * idempotent -- no-op if the dylib path is already a load command
  * hard-asserts there is room before writing (never produces a corrupt binary)
  * supports thin (arm64) and fat binaries (patches the arm64 slice in place)

Usage:
  macho_add_load_dylib.py <macho> <dylib-load-path>
  e.g. macho_add_load_dylib.py OpenInUIExtension @loader_path/ApolloOpenInFix.dylib
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_SEGMENT_64 = 0x19

DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}
CPU_TYPE_ARM64 = 0x0100000C


def patch_thin(buf, base, name):
    """Patch the thin Mach-O whose header starts at byte `base` in bytearray buf.

    Returns 'added' or 'present'.
    """
    magic = struct.unpack_from('<I', buf, base)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("only 64-bit little-endian Mach-O supported (magic=0x%08x)" % magic)

    # mach_header_64: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
    ncmds, sizeofcmds = struct.unpack_from('<II', buf, base + 16)
    header_size = 32
    lc_start = base + header_size

    off = lc_start
    min_sect_off = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmdsize < 8:
            raise SystemExit("corrupt load command (cmdsize=%d)" % cmdsize)
        if cmd in DYLIB_CMDS:
            name_off = struct.unpack_from('<I', buf, off + 8)[0]
            existing = bytes(buf[off + name_off:off + cmdsize]).split(b'\x00', 1)[0]
            if existing.decode('utf-8', 'replace') == name:
                return 'present'
        if cmd == LC_SEGMENT_64:
            # segment_command_64: ... nsects @ +64; sections start @ +72.
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            sect = off + 72
            for _i in range(nsects):
                # section_64: size @ +40, offset @ +48; stride 80.
                sect_size = struct.unpack_from('<Q', buf, sect + 40)[0]
                sect_off = struct.unpack_from('<I', buf, sect + 48)[0]
                if sect_off > 0 and sect_size > 0:
                    if min_sect_off is None or sect_off < min_sect_off:
                        min_sect_off = sect_off
                sect += 80
        off += cmdsize

    if min_sect_off is None:
        raise SystemExit("could not locate first section offset; refusing to patch")

    name_bytes = name.encode('utf-8') + b'\x00'
    cmdsize = (24 + len(name_bytes) + 7) & ~7  # dylib_command(24) + name, 8-byte aligned
    new_cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    new_cmd += name_bytes
    new_cmd += b'\x00' * (cmdsize - len(new_cmd))

    have = min_sect_off - header_size       # bytes available for load commands
    need = sizeofcmds + cmdsize             # bytes after adding ours
    if need > have:
        raise SystemExit("not enough header slack: need %d, have %d" % (need, have))

    write_at = lc_start + sizeofcmds
    buf[write_at:write_at + cmdsize] = new_cmd
    struct.pack_into('<II', buf, base + 16, ncmds + 1, sizeofcmds + cmdsize)
    return 'added'


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    path, name = sys.argv[1], sys.argv[2]
    with open(path, 'rb') as f:
        buf = bytearray(f.read())

    magic_be = struct.unpack_from('>I', buf, 0)[0]
    results = []
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from('>I', buf, 4)[0]
        is64 = magic_be == FAT_MAGIC_64
        entry = 8
        for _ in range(nfat):
            if is64:
                cputype, _sub, offset = struct.unpack_from('>iiQ', buf, entry)
                entry += 32
            else:
                cputype, _sub, offset = struct.unpack_from('>iiI', buf, entry)
                entry += 20
            if cputype == CPU_TYPE_ARM64:
                results.append(patch_thin(buf, offset, name))
        if not results:
            raise SystemExit("no arm64 slice found in fat binary")
    else:
        results.append(patch_thin(buf, 0, name))

    if all(r == 'present' for r in results):
        print("already present: %s" % name)
        return
    with open(path, 'wb') as f:
        f.write(buf)
    print("added LC_LOAD_DYLIB %s -> %s" % (name, path))


if __name__ == '__main__':
    main()
