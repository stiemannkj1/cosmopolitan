#!/usr/bin/env python3
# `assimilate` (and Blink's own unstripped build) leave bytes physically
# present in a file that nothing loadable references any more -- see
# scripts/strip-manifest.txt for how this was discovered and verified.
# This implements the two truncation shapes used by stage-toolchain.sh:
#
#   single <path>            truncate to the end of the last loadable
#                             (LOAD/NOTE/TLS/GNU_*) segment, but never
#                             below any byte range the file's own
#                             embedded self-extraction shell script
#                             references (see shell_script_min_end()
#                             below) -- that's a real, needed loader
#                             payload, not truncatable padding, even
#                             though it sits outside every ELF segment.
#
#   fat <fat> <out> <cosmocc> assimilate a fat APE/ELF to both single-arch
#                             views (via `assimilate -x` / `-a`) purely to
#                             measure each view's last-segment end, then
#                             copy <fat> to <out> and zero the byte range
#                             belonging to the *other* architecture's
#                             slice (whichever of the two ends is
#                             smaller, up to whichever is larger) while
#                             truncating the file to the larger of that
#                             pair -- or to the shell-script-referenced
#                             minimum below, if that reaches further --
#                             preserving <out>'s original APE/PE
#                             polyglot structure (unlike `assimilate`,
#                             which only patches which slice is active
#                             and never reclaims the other slice's bytes,
#                             and unlike plain truncation to one view's
#                             end, which would destroy the file's PE-ness
#                             for the still-needed larger view).
#
# Bug this guards against (found 2026-09-07): a fresh, from-scratch
# ~/.ape/ or ~/.ape-$VERSION state needs every APE_NO_MODIFY_SELF binary
# (cc1/as/ld.bfd, and any locally-built apelink/loader) to be able to
# self-extract its OWN embedded loader -- that payload is stored right
# after the last ELF segment ends, referenced only by the file's own
# shell-script header (`dd if="$o" skip=N count=M | gzip -dc`), which
# `readelf -lW`'s segment table knows nothing about. Truncating purely
# by segment end (the original version of this script) silently deleted
# that payload -- every zero-trimmed binary in this project was, until
# this fix, only working because *something else* (most often the
# wrapper's own self-extraction, sharing the same ~/.ape-$VERSION cache
# path) happened to populate the loader cache first every time it was
# actually tested from a cold state.
import os
import re
import shutil
import subprocess
import sys

SEGMENT_RE = re.compile(
    r"\s*(LOAD|NOTE|TLS|GNU_\w+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)"
)
# Only a `dd if="$o" ... skip=N count=M` with NO `of=` on the same line is
# a loader-payload *extraction* (reads a range of "$o" and pipes it to
# gzip, writing a brand new file elsewhere) -- that range must survive
# truncation. A line with both `if=` and `of=` (usually on "$o" or a
# scratch file) is an in-place self-patch for --assimilate/macOS-Silicon
# support, reading and writing the SAME small region; its `skip=`/`count=`
# says nothing about where real payload data ends and matching it would
# produce false positives from small, early, in-file patch offsets.
DD_EXTRACT_RE = re.compile(rb'dd if="\$o"(?![^\n]*\bof=)[^\n]*?\bskip=(\d+)\s+count=(\d+)')
# The embedded shell-script header (and everything it can reference via
# a "$o"-relative dd) always lives well within the first few hundred KB
# of an APE file; scanning generously more than that is cheap and safe.
SHELL_SCRIPT_SCAN_BYTES = 1 << 20


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


def shell_script_refs(path):
    """Every (skip, count) referenced by a `dd ... skip=N count=M` in the
    file's own embedded self-extraction shell script -- byte ranges the
    file itself needs to remain intact, regardless of what any ELF
    segment table says."""
    with open(path, "rb") as f:
        head = f.read(SHELL_SCRIPT_SCAN_BYTES)
    return [(int(m.group(1)), int(m.group(2))) for m in DD_EXTRACT_RE.finditer(head)]


def shell_script_min_end(path):
    refs = shell_script_refs(path)
    return max((skip + count for skip, count in refs), default=0)


def cmd_single(path):
    old_size = os.path.getsize(path)
    end = max(last_segment_end(path), shell_script_min_end(path))
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

    refs = shell_script_refs(fat_src)
    min_end = max((skip + count for skip, count in refs), default=0)
    final_end = max(hi, min_end)
    overlaps = [(skip, count) for skip, count in refs if lo <= skip < hi]
    if overlaps:
        # A referenced range starts inside the [lo, hi) region we're
        # about to zero -- zeroing it would delete real loader payload.
        # Doesn't happen for any binary staged so far (payloads always
        # follow both architectures' segments), but refuse to guess if
        # it ever does: truncate safely, skip the zero-fill.
        print(f"{os.path.basename(dst)}: shell-script reference(s) {overlaps} "
              f"overlap [{lo},{hi}) -- skipping zero-fill, truncating only", file=sys.stderr)
        shutil.copy(fat_src, dst)
        orig_size = os.path.getsize(dst)
        mode = os.stat(dst).st_mode
        with open(dst, "r+b") as f:
            f.truncate(final_end)
        os.chmod(dst, mode)
        print(f"{os.path.basename(dst)}: {orig_size} -> {final_end} "
              f"(dropped trailing {orig_size - final_end} bytes, zero-fill skipped)")
        return

    shutil.copy(fat_src, dst)
    orig_size = os.path.getsize(dst)
    mode = os.stat(dst).st_mode
    with open(dst, "r+b") as f:
        f.seek(lo)
        f.write(b"\x00" * (hi - lo))
        f.truncate(final_end)
    os.chmod(dst, mode)
    extra = f", kept loader payload up to {final_end}" if final_end > hi else ""
    print(f"{os.path.basename(dst)}: {orig_size} -> {final_end} "
          f"(zeroed [{lo},{hi}), dropped trailing {orig_size - final_end} bytes{extra})")


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
