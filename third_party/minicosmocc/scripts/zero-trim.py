#!/usr/bin/env python3
# `assimilate` (and Blink's own unstripped build) leave bytes physically
# present in a file that nothing loadable references any more -- see
# scripts/strip-manifest.txt for how this was discovered and verified.
# This implements the two truncation shapes used by stage-toolchain.sh:
#
#   single <path>            truncate to the end of the last loadable
#                             (LOAD/NOTE/TLS/GNU_*) segment. For a file
#                             that already has only one ELF view (e.g.
#                             blink-arm64.elf), this drops unstripped
#                             debug sections/.symtab with nothing more
#                             to do.
#
#   fat <fat> <out> <cosmocc> assimilate a fat APE/ELF to both single-arch
#                             views (via `assimilate -x` / `-a`) purely to
#                             measure each view's last-segment end, then
#                             copy <fat> to <out> and zero the byte range
#                             belonging to the *other* architecture's
#                             slice (whichever of the two ends is larger)
#                             while truncating the file to that larger
#                             end -- preserving <out>'s original APE/PE
#                             polyglot structure (unlike `assimilate`,
#                             which only patches which slice is active
#                             and never reclaims the other slice's bytes,
#                             and unlike plain truncation to one view's
#                             end, which would destroy the file's PE-ness
#                             for the still-needed larger view).
import os
import re
import shutil
import subprocess
import sys

SEGMENT_RE = re.compile(
    r"\s*(LOAD|NOTE|TLS|GNU_\w+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)"
)


def last_segment_end(path):
    out = subprocess.run(["readelf", "-lW", path], capture_output=True, text=True).stdout
    end = 0
    for line in out.splitlines():
        m = SEGMENT_RE.match(line)
        if m:
            off = int(m.group(2), 16)
            filesiz = int(m.group(5), 16)
            end = max(end, off + filesiz)
    return end


def cmd_single(path):
    old_size = os.path.getsize(path)
    end = last_segment_end(path)
    if end == 0 or end >= old_size:
        print(f"{os.path.basename(path)}: nothing to trim ({old_size} bytes)")
        return
    mode = os.stat(path).st_mode
    with open(path, "r+b") as f:
        f.truncate(end)
    os.chmod(path, mode)
    print(f"{os.path.basename(path)}: {old_size} -> {end} (saved {old_size - end} bytes)")


def cmd_fat(fat_src, dst, cosmocc):
    # assimilate is itself an APE file (a shell-script/ELF/PE polyglot);
    # subprocess can't execve() it directly without the APE binfmt_misc
    # loader registered (which build/test scripts deliberately remove --
    # see clean-ape-loaders.sh), but its leading bytes are a valid shell
    # script, so running it through bash always works.
    assimilate = os.path.join(cosmocc, "bin", "assimilate")
    ends = {}
    for flag in ("-x", "-a"):
        probe = dst + ".probe"
        shutil.copy(fat_src, probe)
        subprocess.run(
            ["bash", assimilate, flag, "-c", probe],
            check=True, capture_output=True,
        )
        ends[flag] = last_segment_end(probe)
        os.remove(probe)
    lo, hi = min(ends["-x"], ends["-a"]), max(ends["-x"], ends["-a"])
    shutil.copy(fat_src, dst)
    orig_size = os.path.getsize(dst)
    mode = os.stat(dst).st_mode
    with open(dst, "r+b") as f:
        f.seek(lo)
        f.write(b"\x00" * (hi - lo))
        f.truncate(hi)
    os.chmod(dst, mode)
    print(f"{os.path.basename(dst)}: {orig_size} -> {hi} "
          f"(zeroed [{lo},{hi}), dropped trailing {orig_size - hi} bytes)")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: zero-trim.py single <path> | fat <fat_src> <dst> <cosmocc>")
    mode = sys.argv[1]
    if mode == "single" and len(sys.argv) == 3:
        cmd_single(sys.argv[2])
    elif mode == "fat" and len(sys.argv) == 5:
        cmd_fat(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit("usage: zero-trim.py single <path> | fat <fat_src> <dst> <cosmocc>")


if __name__ == "__main__":
    main()
