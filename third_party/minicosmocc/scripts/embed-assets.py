#!/usr/bin/env python3
# Zip-appends the staged toolchain assets into an already-built fat-APE
# wrapper binary, under assets/<subdir>/..., matching cosmocc-min's
# find_assets() lookup at /zip/assets. APE files are also valid zips, so
# appending via zipfile works directly on the finished binary.
import sys
import os
import zipfile

out_path = sys.argv[1]
build_dir = sys.argv[2]
SUBDIRS = sys.argv[3].split(",")

# Symlinks (the plain-name tool aliases like bin/ld -> bin/x86_64-linux-cosmo-ld,
# created during staging) are skipped here rather than embedded: zipfile.write()
# would otherwise follow them and store a full duplicate copy of the target's
# content under the link's name, which is where a large chunk of embedded size
# was going. cosmocc-min recreates these aliases itself after extraction
# (see create_tool_aliases() in wrapper/cosmocc-min.c) instead.
skipped = 0
with zipfile.ZipFile(out_path, "a", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
    for sub in SUBDIRS:
        src_root = os.path.join(build_dir, sub)
        for dirpath, _dirnames, filenames in os.walk(src_root):
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                if os.path.islink(full):
                    skipped += 1
                    continue
                rel = os.path.relpath(full, build_dir)
                arc = "assets/" + rel
                z.write(full, arc)

print(f"skipped {skipped} symlinks (recreated at runtime instead)", file=sys.stderr)

print(f"embedded assets into {out_path}", file=sys.stderr)
