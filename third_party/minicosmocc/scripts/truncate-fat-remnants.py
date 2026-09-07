#!/usr/bin/env python3
# `assimilate` (and Blink's own unstripped release build) leave the other
# architecture's ELF slice / debug sections physically present in the
# file even though nothing loadable references them -- it patches the
# active headers to select one slice/view but never truncates the rest
# away. This walks the staged toolchain and truncates every affected
# file to the end of its last loadable (PT_LOAD/TLS/NOTE) segment. See
# scripts/strip-manifest.txt for how this was discovered and verified.
#
# Re-run this after re-staging build/ from a fresh cosmocc release (e.g.
# a version bump), since a fresh `assimilate` run reintroduces the waste.
import os
import re
import subprocess
import sys

FILES = [
    "gcc-amd64/libexec/gcc/x86_64-linux-cosmo/14.1.0/cc1",
    "gcc-amd64/libexec/gcc/x86_64-linux-cosmo/14.1.0/collect2",
    "gcc-amd64/bin/x86_64-linux-cosmo-gcc",
    "gcc-amd64/bin/x86_64-linux-cosmo-as",
    "gcc-amd64/bin/x86_64-linux-cosmo-ld.bfd",
    "gcc-arm64/libexec/gcc/aarch64-linux-cosmo/14.1.0/cc1",
    "gcc-arm64/libexec/gcc/aarch64-linux-cosmo/14.1.0/collect2",
    "gcc-arm64/bin/aarch64-linux-cosmo-gcc",
    "gcc-arm64/bin/aarch64-linux-cosmo-as",
    "gcc-arm64/bin/aarch64-linux-cosmo-ld.bfd",
    "apelink/apelink-amd64",
    "apelink/apelink-arm64",
    "apelink/fixupobj-amd64",
    "apelink/fixupobj-arm64",
    "apelink/pecheck-amd64",
    "apelink/pecheck-arm64",
    "blink/blink-arm64.elf",
]

SEGMENT_RE = re.compile(
    r"\s*(LOAD|NOTE|TLS|GNU_\w+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)"
)


def last_segment_end(path):
    out = subprocess.run(["readelf", "-lW", path], capture_output=True, text=True).stdout
    max_end = 0
    for line in out.splitlines():
        m = SEGMENT_RE.match(line)
        if m:
            off = int(m.group(2), 16)
            filesiz = int(m.group(5), 16)
            max_end = max(max_end, off + filesiz)
    return max_end


def main():
    build_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build"
    )
    total_before = total_after = 0
    for rel in FILES:
        path = os.path.join(build_dir, rel)
        if not os.path.exists(path):
            print(f"skip (missing): {rel}", file=sys.stderr)
            continue
        end = last_segment_end(path)
        old_size = os.path.getsize(path)
        if end == 0 or end >= old_size:
            print(f"skip (nothing to trim): {rel}", file=sys.stderr)
            continue
        mode = os.stat(path).st_mode
        with open(path, "r+b") as f:
            f.truncate(end)
        os.chmod(path, mode)
        total_before += old_size
        total_after += end
        print(f"{rel}: {old_size} -> {end}")
    if total_before:
        print(f"\nTOTAL: {total_before/1e6:.1f}MB -> {total_after/1e6:.1f}MB "
              f"(saved {(total_before-total_after)/1e6:.1f}MB)")


if __name__ == "__main__":
    main()
