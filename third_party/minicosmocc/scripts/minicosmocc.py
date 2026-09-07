#!/usr/bin/env python3
"""minicosmocc build/test tool.

Usage:
  minicosmocc.py test            full clean, stage+build (reusing any
                                  cached cosmocc release), run the full
                                  test suite
  minicosmocc.py build           full clean, stage+build from scratch
                                  (reusing any cached cosmocc release)
  minicosmocc.py build-uncached  full clean, redownload the cosmocc
                                  release (ignoring any cache), stage+
                                  build from scratch

Consolidates what used to be separate scripts/stage-toolchain.sh,
_assemble.sh, build-blink-compile.sh, rebuild-from-scratch.sh,
embed-assets.py, zero-trim.py, clean-ape-loaders.sh, and
tests/{a-hello-world,a-tinycc,run-all}.sh into one file, since they
only ever ran as one pipeline. See scripts/strip-manifest.txt and
SUMMARY.md for the history and reasoning behind each step -- staging
choices, the zero-trim technique (and the loader-payload bug it had),
and the locally-built apelink/loader are all still explained there,
not repeated in full here.

Requires the full cosmopolitan monorepo checkout (not just this
third_party/minicosmocc directory): apelink and the ape loader stubs
are built from local source via the monorepo's own `make`.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # third_party/minicosmocc
MONOREPO = ROOT.parent.parent  # cosmopolitan/
BUILD = ROOT / "build"
DIST = ROOT / "dist"
WRAPPER_SRC = ROOT / "wrapper" / "minicosmocc.c"
VENDOR = ROOT / "vendor"
TESTS_WORK = ROOT / "tests" / "work"

COSMOCC_VERSION = os.environ.get("COSMOCC_VERSION", "4.0.2")
COSMOCC_STORE = MONOREPO / ".cosmocc"
COSMOCC = COSMOCC_STORE / COSMOCC_VERSION

# lib/ files to keep per target tree: the C-only cosmo runtime pieces
# the wrapper's link step needs. Everything else in the release's lib
# dirs (libstdc++.a, libcxx.a, libgomp.a/.spec, and the dbg/optlinux/
# tiny variant subdirs) is C++/OpenMP/alternate-libc-variant support
# this C-only, single-variant toolchain never uses.
AMD64_LIB_KEEP = [
    "ape-no-modify-self.o", "ape.lds", "ape.o", "crt.o", "libc.a",
    "libcosmo.a", "libcrypt.a", "libdl.a", "libgcc_s.a", "libm.a",
    "libpthread.a", "libresolv.a", "librt.a", "libunwind.a",
]
ARM64_LIB_KEEP = [
    "aarch64.lds", "crt.o", "libc.a", "libcosmo.a", "libcrypt.a",
    "libdl.a", "libgcc_s.a", "libm.a", "libpthread.a", "libresolv.a",
    "librt.a", "libunwind.a",
]

GOLD_NOTE = """# No gold linker in this toolchain

Cosmopolitan does not ship or build a patched `ld.gold`. Verified by
grepping the `cosmopolitan` monorepo (no gold sources/targets anywhere)
and inspecting the `cosmocc` release `bin/` directory (only `ld` and
`ld.bfd` are present, per architecture). Cosmopolitan builds itself with
`ld.bfd`.

Decision: `ld.bfd` substitutes for gold everywhere this plan calls for a
gold linker. The actual binaries are staged (amd64-native, zero+trimmed,
APE/PE structure preserved) at:

  build/gcc-amd64/bin/x86_64-linux-cosmo-ld.bfd
  build/gcc-arm64/bin/aarch64-linux-cosmo-ld.bfd
"""


def run_ape(argv, **kw):
    """Run an APE (MZ/shell/ELF/PE polyglot) binary via bash. A direct
    execve() of one -- which is what subprocess does without a shell in
    the loop -- fails with ENOEXEC; bash's automatic fallback to
    interpreting an ENOEXEC file as a shell script is what makes APE
    binaries runnable without any registered loader, and python's
    subprocess has no equivalent fallback."""
    return subprocess.run(["bash", *[str(a) for a in argv]], **kw)


def relink(link_path, target):
    link_path = Path(link_path)
    if link_path.exists() or link_path.is_symlink():
        link_path.unlink()
    link_path.symlink_to(target)


def du_sh(path):
    out = subprocess.run(["du", "-sh", str(path)], capture_output=True, text=True).stdout
    return out.split()[0] if out else "?"


# ---------------------------------------------------------------------
# zero-trim: `assimilate` (and Blink's own unstripped build) leave bytes
# physically present in a file that nothing loadable references any
# more. This truncates them away in the two shapes stage_toolchain()
# needs, without deleting a binary's own loader self-extraction
# payload, which sits outside every ELF segment and is referenced only
# by the file's embedded shell script (see DD_EXTRACT_RE below) -- see
# strip-manifest.txt / SUMMARY.md for the full history of both bugs
# found here.
# ---------------------------------------------------------------------
SEGMENT_RE = re.compile(
    r"\s*(LOAD|NOTE|TLS|GNU_\w+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)"
)
# Only a `dd if="$o" ... skip=N count=M` with NO `of=` on the same line
# is a loader-payload *extraction* (reads a range of "$o" and pipes it
# to gzip, writing a brand new file elsewhere) -- that range must
# survive truncation. A line with both `if=` and `of=` (usually on "$o"
# or a scratch file) is an in-place self-patch for --assimilate/macOS-
# Silicon support, reading and writing the SAME small region; its
# skip=/count= says nothing about where real payload data ends, and
# matching it produces false positives from small, early, in-file
# patch offsets (this bug briefly truncated a locally-built apelink
# down to 499 bytes before the `of=` exclusion was added).
DD_EXTRACT_RE = re.compile(rb'dd if="\$o"(?![^\n]*\bof=)[^\n]*?\bskip=(\d+)\s+count=(\d+)')
SHELL_SCRIPT_SCAN_BYTES = 1 << 20


def last_segment_end(path):
    out = subprocess.run(["readelf", "-lW", str(path)], capture_output=True, text=True).stdout
    end = 0
    for line in out.splitlines():
        m = SEGMENT_RE.match(line)
        if m:
            off = int(m.group(2), 16)
            filesiz = int(m.group(5), 16)
            end = max(end, off + filesiz)
    return end


def shell_script_refs(path):
    """Every (skip, count) referenced by a genuine loader-extraction
    `dd` in the file's own embedded self-extraction shell script --
    byte ranges the file needs intact regardless of what any ELF
    segment table says."""
    with open(path, "rb") as f:
        head = f.read(SHELL_SCRIPT_SCAN_BYTES)
    return [(int(m.group(1)), int(m.group(2))) for m in DD_EXTRACT_RE.finditer(head)]


def zero_trim_single(path):
    """Truncate to the end of the last loadable segment, but never
    below any shell-script-referenced loader payload."""
    path = Path(path)
    old_size = path.stat().st_size
    end = max(last_segment_end(path), *(s + c for s, c in shell_script_refs(path)), 0)
    if end == 0 or end >= old_size:
        print(f"{path.name}: nothing to trim ({old_size} bytes)")
        return
    mode = path.stat().st_mode
    with open(path, "r+b") as f:
        f.truncate(end)
    path.chmod(mode)
    print(f"{path.name}: {old_size} -> {end} (saved {old_size - end} bytes)")


def zero_trim_fat(fat_src, dst, cosmocc):
    """Assimilate a fat APE/ELF to both single-arch views purely to
    measure each view's last-segment end, then copy fat_src to dst and
    zero the byte range belonging to the *other* architecture's slice
    while truncating to the larger of that pair -- or to the shell-
    script-referenced minimum, if that reaches further -- preserving
    dst's APE/PE polyglot structure."""
    fat_src, dst, cosmocc = Path(fat_src), Path(dst), Path(cosmocc)
    assimilate = cosmocc / "bin" / "assimilate"
    ends = {}
    for flag in ("-x", "-a"):
        probe = dst.with_name(dst.name + ".probe")
        shutil.copy(fat_src, probe)
        run_ape([assimilate, flag, "-c", probe], check=True, capture_output=True)
        ends[flag] = last_segment_end(probe)
        probe.unlink()
    lo, hi = min(ends["-x"], ends["-a"]), max(ends["-x"], ends["-a"])

    refs = shell_script_refs(fat_src)
    min_end = max((skip + count for skip, count in refs), default=0)
    final_end = max(hi, min_end)
    overlaps = [(skip, count) for skip, count in refs if lo <= skip < hi]

    shutil.copy(fat_src, dst)
    orig_size = dst.stat().st_size
    mode = dst.stat().st_mode
    if overlaps:
        # A referenced range starts inside the [lo, hi) region we're
        # about to zero -- zeroing it would delete real loader payload.
        # Doesn't happen for any binary staged so far (payloads always
        # follow both architectures' segments), but refuse to guess if
        # it ever does: truncate safely, skip the zero-fill.
        print(f"{dst.name}: shell-script reference(s) {overlaps} overlap "
              f"[{lo},{hi}) -- skipping zero-fill, truncating only", file=sys.stderr)
        with open(dst, "r+b") as f:
            f.truncate(final_end)
        dst.chmod(mode)
        print(f"{dst.name}: {orig_size} -> {final_end} "
              f"(dropped trailing {orig_size - final_end} bytes, zero-fill skipped)")
        return

    with open(dst, "r+b") as f:
        f.seek(lo)
        f.write(b"\x00" * (hi - lo))
        f.truncate(final_end)
    dst.chmod(mode)
    extra = f", kept loader payload up to {final_end}" if final_end > hi else ""
    print(f"{dst.name}: {orig_size} -> {final_end} "
          f"(zeroed [{lo},{hi}), dropped trailing {orig_size - final_end} bytes{extra})")


# ---------------------------------------------------------------------
# embed-assets: zip-appends the staged toolchain into an already-built
# fat-APE wrapper binary, under assets/<subdir>/..., matching
# minicosmocc's find_assets() lookup at /zip/assets. APE files are also
# valid zips, so appending via zipfile works directly on the finished
# binary.
# ---------------------------------------------------------------------
def embed_assets(out_path, build_dir, subdirs):
    out_path, build_dir = Path(out_path), Path(build_dir)
    skipped = 0
    with zipfile.ZipFile(out_path, "a", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for sub in subdirs:
            src_root = build_dir / sub
            for dirpath, _dirnames, filenames in os.walk(src_root):
                for fn in filenames:
                    full = Path(dirpath) / fn
                    # Symlinks (the plain-name tool aliases created
                    # during staging) are skipped: zipfile would
                    # otherwise follow them and store a full duplicate
                    # copy of the target's content under the link's
                    # name. minicosmocc recreates these aliases itself
                    # after extraction (see create_tool_aliases() in
                    # wrapper/minicosmocc.c).
                    if full.is_symlink():
                        skipped += 1
                        continue
                    arc = f"assets/{full.relative_to(build_dir)}"
                    z.write(full, arc)
    print(f"skipped {skipped} symlinks (recreated at runtime instead)", file=sys.stderr)
    print(f"embedded assets into {out_path}", file=sys.stderr)


# ---------------------------------------------------------------------
# clean-ape-loaders: removes every known APE loader install location,
# so tests can prove a binary needs no pre-installed loader. Global
# system paths and binfmt_misc entries need root; sudo is used only
# when something actually needs removing, and only for APE's own
# binfmt_misc entries (APE, APE-jart) -- never unrelated ones like
# qemu-aarch64's own binfmt registration.
# ---------------------------------------------------------------------
def have_sudo():
    if os.geteuid() == 0:
        return True
    return subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0


def remove_path(path, desc, state):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return
    if os.geteuid() == 0 or os.access(path.parent, os.W_OK):
        if path.is_symlink() or path.is_file():
            path.unlink()
        else:
            shutil.rmtree(path)
        print(f"removed {desc}: {path}")
    elif have_sudo():
        subprocess.run(["sudo", "rm", "-rf", str(path)], check=True)
        print(f"removed (sudo) {desc}: {path}")
    else:
        print(f"WARNING: {desc} exists at {path} but no permission "
              "(and no non-interactive sudo) to remove it", file=sys.stderr)
        state["unremovable"] = True


def unregister_binfmt(entry, state):
    bf = Path(f"/proc/sys/fs/binfmt_misc/{entry}")
    if not bf.exists():
        return
    if os.geteuid() == 0:
        bf.write_text("-1")
        print(f"unregistered binfmt_misc entry: {entry}")
    elif have_sudo():
        subprocess.run(["sudo", "sh", "-c", f"echo -1 > '{bf}'"], check=True)
        print(f"unregistered (sudo) binfmt_misc entry: {entry}")
    else:
        print(f"WARNING: binfmt_misc entry {entry} is registered but no permission "
              "(and no non-interactive sudo) to unregister it", file=sys.stderr)
        state["unremovable"] = True


def clean_ape_loaders(verbose=True):
    state = {"unremovable": False}
    home = Path.home()
    tmpdir = Path(os.environ.get("TMPDIR", "/tmp"))

    if verbose:
        print("==> cleaning APE loaders")
    remove_path("/usr/bin/ape", "global APE loader", state)
    remove_path("/usr/local/bin/ape", "global APE loader (local)", state)
    remove_path(home / ".ape", "user APE loader dir", state)
    remove_path(home / ".local/bin/ape", "user APE loader", state)
    for f in home.glob(".ape-*"):
        remove_path(f, "user APE loader", state)
    for d, pattern in ((Path("/tmp"), ".ape-*"), (tmpdir, "ape*"), (tmpdir, ".ape-*")):
        for f in d.glob(pattern):
            remove_path(f, "temp APE loader", state)
    unregister_binfmt("APE", state)
    unregister_binfmt("APE-jart", state)

    if verbose:
        print("==> verifying nothing remains (and nothing was silently reinstalled)")
    still_present = False
    for p in ("/usr/bin/ape", "/usr/local/bin/ape", home / ".ape", home / ".local/bin/ape"):
        if Path(p).exists():
            print(f"STILL PRESENT: {p}", file=sys.stderr)
            still_present = True
    for d, pattern in ((Path("/tmp"), ".ape-*"), (tmpdir, "ape*"), (tmpdir, ".ape-*"), (home, ".ape-*")):
        for f in d.glob(pattern):
            print(f"STILL PRESENT: {f}", file=sys.stderr)
            still_present = True
    for entry in ("APE", "APE-jart"):
        if Path(f"/proc/sys/fs/binfmt_misc/{entry}").exists():
            print(f"STILL REGISTERED: {entry}", file=sys.stderr)
            still_present = True

    if still_present or state["unremovable"]:
        if verbose:
            print("==> cleanup incomplete: APE loader remnants remain (see above)", file=sys.stderr)
        return False
    if verbose:
        print("==> confirmed: no APE loader present (global, user, temp, or binfmt_misc)")
    return True


def clean_wrapper_caches():
    """Cache state from a wine-hosted run and a plain Linux run can
    otherwise collide at overlapping paths with different ownership/
    attributes; clearing every known cache location keeps runs
    reproducible regardless of what earlier manual testing left
    behind."""
    shutil.rmtree(Path(os.environ.get("TMPDIR", "/tmp")) / "minicosmocc", ignore_errors=True)
    shutil.rmtree(Path.home() / ".cache/minicosmocc", ignore_errors=True)
    for p in Path.home().glob(".wine/drive_c/users/*/AppData/Local/Temp/minicosmocc*"):
        shutil.rmtree(p, ignore_errors=True) if p.is_dir() else p.unlink(missing_ok=True)


def full_clean():
    print("==> full clean")
    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(DIST, ignore_errors=True)
    shutil.rmtree(TESTS_WORK, ignore_errors=True)
    clean_wrapper_caches()
    clean_ape_loaders(verbose=False)


# ---------------------------------------------------------------------
# stage_toolchain: downloads (or reuses a cached) cosmocc release,
# assimilates every dual-arch tool to an amd64-native view with the
# zero+trim technique above, copies the filtered lib/ and include/
# trees, builds apelink + the ape loader from local source, and
# installs the vendored Blink binary. Re-run after a cosmocc version
# bump (set COSMOCC_VERSION) to re-derive build/ from the new release;
# the zero+trim math is re-measured from the fresh binaries each time,
# not hardcoded to today's offsets.
# ---------------------------------------------------------------------
def download_cosmocc(force=False):
    if force and COSMOCC.exists():
        print(f"==> removing cached cosmocc {COSMOCC_VERSION} (uncached build requested)")
        shutil.rmtree(COSMOCC)
    if not (COSMOCC / "bin" / "assimilate").exists():
        print(f"==> downloading cosmocc {COSMOCC_VERSION}")
        COSMOCC_STORE.mkdir(parents=True, exist_ok=True)
        fd, tmp_zip_name = tempfile.mkstemp(
            dir=os.environ.get("TMPDIR", "/tmp"), prefix=f"cosmocc-{COSMOCC_VERSION}.", suffix=".zip")
        os.close(fd)
        tmp_zip = Path(tmp_zip_name)
        try:
            subprocess.run(
                ["curl", "-fL", "-o", str(tmp_zip),
                 f"https://github.com/jart/cosmopolitan/releases/download/"
                 f"{COSMOCC_VERSION}/cosmocc-{COSMOCC_VERSION}.zip"],
                check=True)
            tmp_extract = COSMOCC.parent / (COSMOCC.name + ".tmp")
            shutil.rmtree(tmp_extract, ignore_errors=True)
            tmp_extract.mkdir(parents=True)
            # Use the system unzip (not python's zipfile) so Unix
            # executable permissions on every staged binary survive
            # extraction -- zipfile.extractall() doesn't restore them.
            subprocess.run(["unzip", "-q", str(tmp_zip)], cwd=tmp_extract, check=True)
            tmp_extract.rename(COSMOCC)
        finally:
            tmp_zip.unlink(missing_ok=True)
    current = COSMOCC_STORE / "current"
    if current.exists() or current.is_symlink():
        current.unlink()
    current.symlink_to(COSMOCC_VERSION)
    print(f"==> using cosmocc release: {COSMOCC}")


def stage_tree(tree, triple):
    dst_root = BUILD / tree
    cc1_src = COSMOCC / "libexec/gcc" / triple / "14.1.0/cc1"
    print(f"==> [{tree}] assimilating cc1/as/ld.bfd to amd64-native + zero-trim")
    zero_trim_fat(cc1_src, dst_root / "libexec/gcc" / triple / "14.1.0/cc1", COSMOCC)
    for tool in ("as", "ld.bfd"):
        src = COSMOCC / "bin" / f"{triple}-{tool}"
        dst = dst_root / "bin" / f"{triple}-{tool}"
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o", dst, src], check=True)
        zero_trim_fat(src, dst, COSMOCC)
    relink(dst_root / "bin/as", f"{triple}-as")
    relink(dst_root / "bin/ld.bfd", f"{triple}-ld.bfd")


def stage_toolchain():
    print(f"==> wiping and recreating {BUILD}")
    shutil.rmtree(BUILD, ignore_errors=True)
    for d in (
        BUILD / "gcc-amd64/bin", BUILD / "gcc-amd64/lib",
        BUILD / "gcc-amd64/libexec/gcc/x86_64-linux-cosmo/14.1.0",
        BUILD / "gcc-arm64/bin", BUILD / "gcc-arm64/lib",
        BUILD / "gcc-arm64/libexec/gcc/aarch64-linux-cosmo/14.1.0",
        BUILD / "apelink", BUILD / "blink", BUILD / "include", BUILD / "gold",
    ):
        d.mkdir(parents=True, exist_ok=True)

    stage_tree("gcc-amd64", "x86_64-linux-cosmo")
    stage_tree("gcc-arm64", "aarch64-linux-cosmo")

    print("==> [gcc-amd64] staging lib/")
    for f in AMD64_LIB_KEEP:
        shutil.copy(COSMOCC / "x86_64-linux-cosmo/lib" / f, BUILD / "gcc-amd64/lib" / f)
    print("==> [gcc-arm64] staging lib/")
    for f in ARM64_LIB_KEEP:
        shutil.copy(COSMOCC / "aarch64-linux-cosmo/lib" / f, BUILD / "gcc-arm64/lib" / f)

    # apelink and the ape-*.elf loader stubs are built from THIS repo's
    # local source (via the monorepo's own `make`, bootstrapped by the
    # same cosmocc release) rather than taken from the prebuilt cosmocc
    # release. The prebuilt cosmocc-4.0.2 release predates the "nest
    # ape loader self-extraction under .ape/" EDR-blocking fix, so a
    # prebuilt apelink would bake the old path into every binary this
    # project's wrapper produces. fixupobj/pecheck are unrelated to
    # that fix and still come from the prebuilt release. ape-m1.c/
    # ape-x86_64.macho (macOS support) are also still taken from the
    # prebuilt release: this project doesn't test or target macOS.
    make = COSMOCC_STORE / "current/bin/make"
    apelink_c = MONOREPO / "tool/build/apelink.c"
    if not apelink_c.exists():
        sys.exit(f"error: {apelink_c} not found -- building apelink and the ape "
                  "loader from source requires the full cosmopolitan monorepo "
                  "checkout, not just this third_party/minicosmocc directory.")
    print("==> building apelink + ape loader (ape.elf, x86_64 and aarch64) from local source")
    nproc = str(os.cpu_count() or 1)
    run_ape([make, "MODE=x86_64", "-j", nproc,
             "o/x86_64/tool/build/apelink", "o/x86_64/ape/ape.elf"],
            cwd=MONOREPO, check=True)
    run_ape([make, "MODE=aarch64", "-j", nproc, "o/aarch64/ape/ape.elf"],
            cwd=MONOREPO, check=True)

    shutil.copy(MONOREPO / "o/x86_64/tool/build/apelink", BUILD / "apelink/apelink-amd64")
    zero_trim_single(BUILD / "apelink/apelink-amd64")
    shutil.copy(MONOREPO / "o/x86_64/ape/ape.elf", BUILD / "apelink/ape-x86_64.elf")
    shutil.copy(MONOREPO / "o/aarch64/ape/ape.elf", BUILD / "apelink/ape-aarch64.elf")

    print("==> [apelink] assimilating fixupobj/pecheck to amd64-native + zero-trim")
    for tool in ("fixupobj", "pecheck"):
        dst = BUILD / "apelink" / f"{tool}-amd64"
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o", dst, COSMOCC / "bin" / tool], check=True)
        zero_trim_fat(COSMOCC / "bin" / tool, dst, COSMOCC)
    for f in ("ape-m1.c", "ape-x86_64.macho"):
        shutil.copy(COSMOCC / "bin" / f, BUILD / "apelink" / f)

    print("==> [blink] installing vendored blink-arm64.elf + trim")
    shutil.copy(VENDOR / "blink-arm64.elf", BUILD / "blink/blink-arm64.elf")
    (BUILD / "blink/blink-arm64.elf").chmod(0o755)
    zero_trim_single(BUILD / "blink/blink-arm64.elf")

    print("==> [include] staging shared headers")
    shutil.copytree(COSMOCC / "include", BUILD / "include", dirs_exist_ok=True)

    (BUILD / "gold/NOTE.md").write_text(GOLD_NOTE)

    du_before, du_after = du_sh(COSMOCC), du_sh(BUILD)
    print(f"\n==> stage_toolchain done. {BUILD} staged ({du_after}; cosmocc release was {du_before})")


# ---------------------------------------------------------------------
# assemble: builds dist/minicosmocc.com -- a fat APE wrapper +
# amd64/arm64 cosmo toolchains + Blink (for the wrapper's own internal
# cross-arch dispatch only; outputs it produces do not get Blink
# embedded).
# ---------------------------------------------------------------------
def assemble():
    for dep in (WRAPPER_SRC, BUILD / "gcc-amd64", BUILD / "gcc-arm64",
                BUILD / "apelink", BUILD / "blink", BUILD / "include"):
        if not dep.exists():
            sys.exit(f"==> missing dependency: {dep}")
    host_cc = shutil.which("cc") or shutil.which("gcc")
    if not host_cc:
        sys.exit("==> need a host C compiler (cc or gcc) to bootstrap")

    print("==> building bootstrap wrapper with the host compiler")
    bootstrap = BUILD / ".bootstrap-minicosmocc"
    subprocess.run([host_cc, "-std=c11", "-D_GNU_SOURCE", "-O2",
                    "-o", str(bootstrap), str(WRAPPER_SRC)], check=True)

    # The bootstrap above is a plain host-glibc binary, not cosmo-
    # linked, so its execv() can't launch cc1/as/ld.bfd in their real
    # fat/APE form (that only works from a cosmo-linked caller's
    # fork()+execv(), which the *shipped* wrapper is). Stage single-
    # arch-assimilated (plain ELF) copies just for this one self-
    # hosting step -- a build-time-only concern that never affects the
    # embedded runtime assets below.
    print("==> staging plain-ELF toolchain copies for bootstrap use only")
    bootstrap_assets = BUILD / ".bootstrap-assets"
    shutil.rmtree(bootstrap_assets, ignore_errors=True)
    bootstrap_assets.mkdir(parents=True)
    for tree in ("blink", "include"):
        (bootstrap_assets / tree).symlink_to(BUILD / tree)
    for tree, triple in (("gcc-amd64", "x86_64-linux-cosmo"), ("gcc-arm64", "aarch64-linux-cosmo")):
        target = bootstrap_assets / tree
        (target / "bin").mkdir(parents=True)
        (target / "libexec/gcc" / triple / "14.1.0").mkdir(parents=True)
        (target / "lib").mkdir(parents=True)
        for f in (BUILD / tree / "lib").iterdir():
            (target / "lib" / f.name).symlink_to(f)
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o",
                 target / "libexec/gcc" / triple / "14.1.0/cc1",
                 BUILD / tree / "libexec/gcc" / triple / "14.1.0/cc1"], check=True)
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o",
                 target / "bin" / f"{triple}-as", BUILD / tree / "bin" / f"{triple}-as"], check=True)
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o",
                 target / "bin" / f"{triple}-ld.bfd", BUILD / tree / "bin" / f"{triple}-ld.bfd"], check=True)
        relink(target / "bin/as", f"{triple}-as")
        relink(target / "bin/ld.bfd", f"{triple}-ld.bfd")

    # apelink here is $BUILD's locally-built copy (see stage_toolchain()
    # above), the same one used to link every program the wrapper
    # itself goes on to compile -- so the wrapper binary gets the
    # current ape-loader-path behavior too, not just its output.
    apelink_dir = bootstrap_assets / "apelink"
    apelink_dir.mkdir(parents=True)
    for f in ("ape-x86_64.elf", "ape-aarch64.elf", "ape-m1.c"):
        shutil.copy(BUILD / "apelink" / f, apelink_dir / f)
    run_ape([COSMOCC / "bin/assimilate", "-x", "-o",
             apelink_dir / "apelink-amd64", BUILD / "apelink/apelink-amd64"], check=True)
    for tool in ("fixupobj", "pecheck"):
        run_ape([COSMOCC / "bin/assimilate", "-x", "-o",
                 apelink_dir / f"{tool}-amd64", COSMOCC / "bin" / tool], check=True)

    # The wrapper checks its own runtime cache (keyed only by
    # WRAPPER_VERSION, not by content) before even looking at
    # COSMOCC_MIN_ASSETS -- a cache left "ready" by an unrelated
    # earlier run (e.g. of the built product, using the real fat/APE
    # assets) would otherwise get reused here instead of these plain-
    # ELF bootstrap assets, breaking the non-cosmo bootstrap's execv()
    # the same way a fat cc1 always does. Clear it so this step is
    # deterministic regardless of ambient /tmp state.
    shutil.rmtree(Path(os.environ.get("TMPDIR", "/tmp")) / "minicosmocc", ignore_errors=True)
    shutil.rmtree(Path.home() / ".cache/minicosmocc", ignore_errors=True)

    print("==> self-hosting: compiling the wrapper into a fat APE via the staged cosmo toolchain")
    out = DIST / "minicosmocc.com"
    DIST.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)
    env = dict(os.environ, COSMOCC_MIN_ASSETS=str(bootstrap_assets))
    subprocess.run([str(bootstrap), "-o", str(out), str(WRAPPER_SRC)], env=env, check=True)
    shutil.rmtree(bootstrap_assets, ignore_errors=True)

    subdirs = ["gcc-amd64", "gcc-arm64", "apelink", "blink", "include"]
    print(f"==> embedding toolchain assets ({','.join(subdirs)})")
    embed_assets(out, BUILD, subdirs)

    print("==> verifying the assembled binary executes")
    # bare invocation with no source file: expected to print usage and
    # exit 1; anything else (crash, exec failure) means assembly broke.
    r = run_ape([out], capture_output=True, text=True)
    if r.returncode != 1:
        print(f"==> self-check failed (exit {r.returncode}):", file=sys.stderr)
        print(r.stdout + r.stderr, file=sys.stderr)
        sys.exit(1)

    size_mb = out.stat().st_size // (1024 * 1024)
    print(f"==> Binary size: {size_mb} MB")


# ---------------------------------------------------------------------
# tests/a-hello-world: the full 3x3 matrix -- compile a malloc/free
# hello-world on {amd64-native, arm64-via-qemu+Blink, windows-via-wine},
# then run each resulting binary on all three of the same platforms (9
# combinations), plus a cross-compiler-host byte-identical-output check
# and the loader-reinstallation cross-check. Runs to completion even if
# individual cells fail, so the final report always shows the full
# matrix, not just the first failure.
# ---------------------------------------------------------------------
def test_hello_world():
    work = TESTS_WORK / "a-hello-world"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / "hello.c").write_text(
        "#include <stdio.h>\n#include <stdlib.h>\n"
        "int main(void) {\n"
        "  char *buf = malloc(32);\n"
        '  snprintf(buf, 32, "hello from %s", "cosmo");\n'
        "  puts(buf);\n"
        "  free(buf);\n"
        "  return 0;\n"
        "}\n"
    )
    expected = "hello from cosmo"
    results, counts = {}, {"pass": 0, "fail": 0}

    def record(label, ok):
        results[label] = "PASS" if ok else "FAIL"
        counts["pass" if ok else "fail"] += 1
        print(f"  {'PASS' if ok else 'FAIL'}: {label}")

    def check_output(label, actual):
        ok = actual == expected
        if not ok:
            print(f"    (got: '{actual}', want: '{expected}')", file=sys.stderr)
        record(label, ok)

    def run_output_matrix(binpath, prefix):
        binpath = Path(binpath)
        if not binpath.exists():
            record(f"{prefix} run=amd64-native", False)
            record(f"{prefix} run=arm64-qemu", False)
            record(f"{prefix} run=windows-wine", False)
            return
        # Wine's Windows-translation layer doesn't preserve the Unix
        # executable bit on file creation; a wine-compiled binary
        # needs this the same way a real cross-platform transfer would.
        binpath.chmod(0o755)

        r = run_ape([binpath], capture_output=True, text=True)
        if r.returncode == 0:
            check_output(f"{prefix} run=amd64-native", r.stdout.strip())
        else:
            record(f"{prefix} run=amd64-native", False)

        arm64_elf = binpath.with_name(binpath.name + ".arm64.elf")
        ra = run_ape([COSMOCC / "bin/assimilate", "-a", "-o", arm64_elf, binpath], capture_output=True)
        if ra.returncode == 0:
            rq = subprocess.run(["qemu-aarch64", str(arm64_elf)], capture_output=True, text=True)
            if rq.returncode == 0:
                check_output(f"{prefix} run=arm64-qemu", rq.stdout.strip())
            else:
                record(f"{prefix} run=arm64-qemu", False)
        else:
            record(f"{prefix} run=arm64-qemu", False)

        rw = subprocess.run(["wine", str(binpath)], capture_output=True, text=True)
        if rw.returncode == 0:
            check_output(f"{prefix} run=windows-wine", rw.stdout.replace("\r", "").strip())
        else:
            record(f"{prefix} run=windows-wine", False)

    print("=== Scenario 1: compile on amd64 (native) ===")
    clean_ape_loaders(verbose=False)
    clean_wrapper_caches()
    hello_native = work / "hello_native"
    r = run_ape([DIST / "minicosmocc.com", "-o", "hello_native", "hello.c"], cwd=work)
    if r.returncode == 0:
        run_output_matrix(hello_native, "compile=amd64-native,")
    else:
        print("  compile FAILED", file=sys.stderr)
        run_output_matrix(Path("/nonexistent"), "compile=amd64-native,")

    print()
    print("=== Scenario 2: compile on arm64 (qemu-aarch64 + Blink dispatch) ===")
    clean_ape_loaders(verbose=False)
    clean_wrapper_caches()
    arm64_wrapper = work / "blink-compile.arm64.elf"
    hello_from_arm64 = work / "hello_from_arm64"
    ra = run_ape([COSMOCC / "bin/assimilate", "-a", "-o", arm64_wrapper, DIST / "minicosmocc.com"])
    ok = False
    if ra.returncode == 0:
        rq = subprocess.run(["qemu-aarch64", "-E", f"HOME={Path.home()}", str(arm64_wrapper),
                              "-o", "hello_from_arm64", "hello.c"], cwd=work)
        ok = rq.returncode == 0
    if ok:
        run_output_matrix(hello_from_arm64, "compile=arm64-qemu,")
    else:
        print("  compile FAILED", file=sys.stderr)
        run_output_matrix(Path("/nonexistent"), "compile=arm64-qemu,")

    print()
    print("=== Scenario 3: compile on windows (wine) ===")
    clean_ape_loaders(verbose=False)
    clean_wrapper_caches()
    wine_exe = work / "blink-compile-wine.exe"
    shutil.copy(DIST / "minicosmocc.com", wine_exe)
    hello_from_wine = work / "hello_from_wine"
    rw = subprocess.run(["wine", str(wine_exe), "-o", "hello_from_wine", "hello.c"],
                         cwd=work, capture_output=True, text=True)
    for line in (rw.stdout + rw.stderr).splitlines():
        if "fixme" not in line and "semi-stub" not in line:
            print(line)
    if hello_from_wine.exists():
        run_output_matrix(hello_from_wine, "compile=windows-wine,")
    else:
        print("  compile FAILED", file=sys.stderr)
        run_output_matrix(Path("/nonexistent"), "compile=windows-wine,")

    print()
    print("=== Determinism check: are all three outputs byte-identical? ===")
    try:
        ident = (hello_native.read_bytes() == hello_from_arm64.read_bytes() == hello_from_wine.read_bytes())
    except OSError:
        ident = False
    record("cross-compiler-host byte-identical output", ident)

    print()
    print("=== Cross-check: no APE loader silently reinstalled ===")
    record("no loader silently reinstalled", clean_ape_loaders())

    print()
    print(f"=== a-hello-world SUMMARY: {counts['pass']} passed, {counts['fail']} failed "
          f"(of {counts['pass'] + counts['fail']}) ===")
    for label in sorted(results):
        print(f"  {results[label]}: {label}")
    return counts["fail"] == 0


# ---------------------------------------------------------------------
# tests/a-tinycc: builds tinycc (a real ~30K-line, 24-file C project,
# a unity build that suits this wrapper's one-source-file-per-
# invocation design well) with dist/minicosmocc.com, confirms the
# built tcc reports its version correctly on all three platforms, and
# validates self-compile determinism between amd64-native and windows-
# wine. arm64-qemu self-compile is intentionally excluded: an
# aarch64-native tcc slice reading this host's x86_64-specific glibc
# headers hits an architecture-mismatched macro path in gnu/stubs.h --
# a tinycc+glibc header limitation, not a wrapper defect; the "tcc -v"
# check already separately confirms the arm64 slice works. tinycc's
# own bounds-checking runtime (lib/bcheck.c) also fails to build here
# (__malloc_hook was removed from modern glibc) -- unrelated to this
# wrapper, so this only exercises -c (compile-only) mode, which needs
# no runtime.
# ---------------------------------------------------------------------
def test_tinycc():
    tinycc_src = Path.home() / "Projects/work/tinycc"
    work = TESTS_WORK / "a-tinycc"
    results, counts = {}, {"pass": 0, "fail": 0}

    def record(label, ok):
        results[label] = "PASS" if ok else "FAIL"
        counts["pass" if ok else "fail"] += 1
        print(f"  {'PASS' if ok else 'FAIL'}: {label}")

    if not (tinycc_src / "tcc.c").exists():
        print(f"tinycc source not found at {tinycc_src}", file=sys.stderr)
        return False
    if not (tinycc_src / "config.h").exists():
        print("=== generating tinycc's config.h (host tool, unrelated to minicosmocc.com) ===")
        subprocess.run(["./configure", "--prefix=/usr/local"], cwd=tinycc_src,
                        check=True, stdout=subprocess.DEVNULL)

    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    print("=== Build tinycc with minicosmocc.com (native amd64) ===")
    clean_ape_loaders(verbose=False)
    clean_wrapper_caches()
    tcc_bin = work / "tcc"
    run_ape([DIST / "minicosmocc.com", "-o", tcc_bin, "tcc.c"], cwd=tinycc_src)
    record("build tinycc", tcc_bin.exists())

    if not tcc_bin.exists():
        print("cannot continue without a built tcc", file=sys.stderr)
        print(f"=== a-tinycc SUMMARY: {counts['pass']} passed, {counts['fail']} failed "
              f"(of {counts['pass'] + counts['fail']}) ===")
        return False

    print()
    print("=== tcc -v runs correctly on all three platforms ===")
    tcc_bin.chmod(0o755)
    r = run_ape([tcc_bin, "-v"], capture_output=True, text=True)
    record("tcc -v, run=amd64-native", r.returncode == 0 and "tcc version" in r.stdout)

    tcc_arm64 = work / "tcc.arm64.elf"
    ra = run_ape([COSMOCC / "bin/assimilate", "-a", "-o", tcc_arm64, tcc_bin], capture_output=True)
    if ra.returncode == 0:
        rq = subprocess.run(["qemu-aarch64", str(tcc_arm64), "-v"], capture_output=True, text=True)
        record("tcc -v, run=arm64-qemu", rq.returncode == 0 and "tcc version" in rq.stdout)
    else:
        record("tcc -v, run=arm64-qemu", False)

    rw = subprocess.run(["wine", str(tcc_bin), "-v"], capture_output=True, text=True)
    record("tcc -v, run=windows-wine", "tcc version" in rw.stdout.replace("\r", ""))

    print()
    print("=== Determinism: tcc -c tcc.c -o out.o, byte-compared across amd64-native and windows-wine ===")
    print("    (arm64-qemu is intentionally excluded here: an aarch64-native tcc slice reading")
    print("     this host's x86_64-specific glibc headers hits an architecture-mismatched macro")
    print("     path in gnu/stubs.h -- a tinycc+glibc header limitation, not a wrapper defect;")
    print("     the 'tcc -v' check above already validates the arm64 slice works correctly.)")
    for p in tinycc_src.glob("tcc_self.*.o"):
        p.unlink()

    out_native = work / "tcc_self.amd64-native.o"
    run_ape([tcc_bin, "-B.", "-Iinclude", "-c", "tcc.c", "-o", out_native], cwd=tinycc_src)
    record("self-compile (-c), run=amd64-native", out_native.exists())

    tcc_wine = work / "tcc-wine.exe"
    shutil.copy(tcc_bin, tcc_wine)
    out_wine = work / "tcc_self.windows-wine.o"
    subprocess.run(["wine", str(tcc_wine), "-B.", "-Iinclude", "-c", "tcc.c", "-o", str(out_wine)],
                    cwd=tinycc_src)
    record("self-compile (-c), run=windows-wine", out_wine.exists())

    try:
        ident = out_native.read_bytes() == out_wine.read_bytes()
    except OSError:
        ident = False
    record("self-compile output byte-identical (amd64-native vs windows-wine)", ident)

    print()
    print("=== Cross-check: no APE loader silently reinstalled ===")
    record("no loader silently reinstalled", clean_ape_loaders())

    print()
    print(f"=== a-tinycc SUMMARY: {counts['pass']} passed, {counts['fail']} failed "
          f"(of {counts['pass'] + counts['fail']}) ===")
    for label in sorted(results):
        print(f"  {results[label]}: {label}")
    return counts["fail"] == 0


def run_tests():
    scenarios = [("a-hello-world", test_hello_world), ("a-tinycc", test_tinycc)]
    results = {}
    for name, fn in scenarios:
        print()
        print("#" * 60)
        print(f"# Running {name}")
        print("#" * 60)
        clean_ape_loaders(verbose=False)
        results[name] = fn()
    print()
    print("#" * 60)
    print("# FINAL SUMMARY")
    print("#" * 60)
    for name, _ in scenarios:
        print(f"  {'PASS' if results[name] else 'FAIL'}: {name}")
    return all(results.values())


# ---------------------------------------------------------------------
# top-level commands
# ---------------------------------------------------------------------
def cmd_build(uncached=False):
    full_clean()
    download_cosmocc(force=uncached)
    stage_toolchain()
    assemble()


def cmd_test():
    full_clean()
    download_cosmocc(force=False)
    stage_toolchain()
    assemble()
    return run_tests()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["test", "build", "build-uncached"])
    args = parser.parse_args()

    if args.action == "test":
        sys.exit(0 if cmd_test() else 1)
    elif args.action == "build":
        cmd_build(uncached=False)
    elif args.action == "build-uncached":
        cmd_build(uncached=True)


if __name__ == "__main__":
    main()
