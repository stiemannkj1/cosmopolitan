/*
 * minicosmocc.c - minimal Cosmopolitan/APE C-only compiler wrapper
 * ("minicosmocc"). Produces fat (amd64+arm64 native) APE binaries.
 *
 * Pipeline per target architecture:
 *   compile (cc1 directly) -> assemble (as directly) -> fixupobj ->
 *   link (ld.bfd directly) -> fixupobj
 * then, once every requested target has an ELF:
 *   apelink (join into one APE) -> pecheck
 *
 * cc1/as/ld.bfd are invoked directly rather than through gcc's driver
 * (which would normally orchestrate them, along with collect2 for
 * linking). This is deliberate, not an optimization: gcc's own bundled
 * spawn helpers request POSIX_SPAWN_USEVFORK, and Cosmopolitan's
 * posix_spawn() unconditionally routes that into a broken vfork-nt.c
 * mechanism on Windows, which breaks any gcc-orchestrated sub-tool
 * launch under Wine. Plain fork()+execv() (what run_or_die() uses) does
 * not hit this path and is reliable there, so bypassing gcc/collect2
 * sidesteps the bug -- identically on Linux and Windows, no branching.
 * gcc and collect2 themselves are consequently unused and unstaged.
 *
 * Host/target dispatch: both the amd64-target and arm64-target
 * toolchains are amd64-native binaries only (no arm64-native build is
 * staged at all). On an amd64 host both run directly; on an arm64 host
 * both run under Blink, which emulates the compiler's own amd64
 * execution -- independent of which architecture it's compiling for.
 * libcosmo.a/crt.o/etc. are architecture-specific link-time archives,
 * not executables, so both amd64 and arm64 copies are always needed
 * regardless of host, to build the fat (dual-native) output.
 *
 * The exact compiler/linker flags below were captured by running the
 * upstream `cosmocc` driver with BUILDLOG=1 and are required for ABI
 * compatibility with the prebuilt cosmo crt/libc objects; don't drop any
 * of them without re-verifying against a fresh BUILDLOG capture. This
 * wrapper only ever targets one cosmo runtime configuration (no
 * -mtiny/-mdbg/-moptlinux support), so this is a fixed, closed flag
 * set, not a general gcc-flag translation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>
#include <libgen.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <dirent.h>

#define WRAPPER_VERSION "0.1.0"
#define GCC_VER "14.1.0"
#define MAX_ARGS 512

typedef struct {
  int argc;
  char *argv[MAX_ARGS];
} Cmd;

static void cmd_init(Cmd *c) { c->argc = 0; }

static void cmd_add(Cmd *c, const char *arg) {
  if (c->argc >= MAX_ARGS - 1) {
    fprintf(stderr, "minicosmocc: too many arguments\n");
    exit(1);
  }
  c->argv[c->argc++] = (char *)arg;
}

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "minicosmocc: ");
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

static int dir_exists(const char *p) {
  struct stat st;
  return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int file_exists(const char *p) {
  struct stat st;
  return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static void run_or_die(Cmd *c) {
  c->argv[c->argc] = NULL;
  fflush(stdout);
  pid_t pid = fork();
  if (pid < 0) die("fork failed: %s", strerror(errno));
  if (pid == 0) {
    execv(c->argv[0], c->argv);
    fprintf(stderr, "minicosmocc: exec failed for %s: %s\n", c->argv[0], strerror(errno));
    _exit(127);
  }
  int status;
  if (waitpid(pid, &status, 0) < 0) die("waitpid failed: %s", strerror(errno));
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "minicosmocc: command failed:");
    for (int i = 0; i < c->argc; i++) fprintf(stderr, " %s", c->argv[i]);
    fputc('\n', stderr);
    exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
  }
}

typedef enum { HOST_AMD64, HOST_ARM64 } HostArch;

static HostArch detect_host(void) {
  struct utsname u;
  if (uname(&u) != 0) die("uname failed: %s", strerror(errno));
  if (!strcmp(u.machine, "x86_64")) return HOST_AMD64;
  if (!strcmp(u.machine, "aarch64") || !strcmp(u.machine, "arm64")) return HOST_ARM64;
  die("unsupported host architecture: %s", u.machine);
  return HOST_AMD64; /* unreachable */
}

typedef struct {
  const char *name;        /* "amd64" | "arm64" */
  const char *triple;      /* "x86_64-linux-cosmo" | "aarch64-linux-cosmo" */
  const char *lds;         /* linker script filename inside lib/ */
  const char *common_page; /* -Wl,-z,common-page-size=... */
  int has_ape_o;           /* amd64 links start with lib/ape.o; arm64 doesn't */
} TargetSpec;

static const TargetSpec TARGET_AMD64 = {"amd64", "x86_64-linux-cosmo", "ape.lds", "4096", 1};
static const TargetSpec TARGET_ARM64 = {"arm64", "aarch64-linux-cosmo", "aarch64.lds", "16384", 0};

static char g_assets[PATH_MAX];
static char g_cache[PATH_MAX];
static int g_save_temps;

/* ---- locate bundled toolchain assets, then extract/link them into a
 * real on-disk cache dir (Phase 2 spec: "header extraction on first
 * run"). When assets are already a plain directory (dev/test mode) we
 * symlink instead of copying ~800MB; a real embedded-APE run (assets
 * under /zip) gets a real one-time extraction, since exec() needs a
 * real file, not a virtual /zip entry. */

static void find_assets(const char *argv0) {
  const char *env = getenv("COSMOCC_MIN_ASSETS");
  if (env && dir_exists(env)) {
    snprintf(g_assets, sizeof g_assets, "%s", env);
    return;
  }
  if (dir_exists("/zip/assets")) {
    snprintf(g_assets, sizeof g_assets, "/zip/assets");
    return;
  }
  char dirbuf[PATH_MAX];
  snprintf(dirbuf, sizeof dirbuf, "%s", argv0);
  char *dir = dirname(dirbuf);
  char cand[PATH_MAX];
  snprintf(cand, sizeof cand, "%s/assets", dir);
  if (dir_exists(cand)) {
    snprintf(g_assets, sizeof g_assets, "%s", cand);
    return;
  }
  die("cannot locate toolchain assets (set COSMOCC_MIN_ASSETS to the staged build/ dir)");
}

static void mkdir_p(const char *path) {
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof tmp, "%s", path);
  size_t len = strlen(tmp);
  if (len && tmp[len - 1] == '/') tmp[len - 1] = '\0';
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = '\0';
      mkdir(tmp, 0755);
      *p = '/';
    }
  }
  mkdir(tmp, 0755);
}

static void copy_file(const char *src, const char *dst, mode_t mode) {
  FILE *in = fopen(src, "rb");
  if (!in) die("cannot open %s for reading: %s", src, strerror(errno));
  FILE *out = fopen(dst, "wb");
  if (!out) die("cannot open %s for writing: %s", dst, strerror(errno));
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
    if (fwrite(buf, 1, n, out) != n) die("write error to %s", dst);
  }
  fclose(in);
  fclose(out);
  chmod(dst, mode & 0777);
}

/* /zip/... is a virtual filesystem the cosmo runtime serves out of THIS
 * process's own embedded zip payload; it is not a real mount, so other
 * processes (like /bin/cp) can't see it. Extraction has to happen via
 * our own process's file I/O, which cosmo does intercept for /zip
 * paths. Symlinks inside the embedded zip were stored as plain regular
 * files by the build-time packer (embed-assets.py follows symlinks), so
 * this only ever sees regular files and directories, never S_ISLNK. */
static void recursive_copy(const char *src, const char *dst) {
  struct stat st;
  if (stat(src, &st) != 0) die("cannot stat %s: %s", src, strerror(errno));
  if (S_ISDIR(st.st_mode)) {
    mkdir_p(dst);
    DIR *d = opendir(src);
    if (!d) die("cannot opendir %s: %s", src, strerror(errno));
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
      if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
      char s2[PATH_MAX], d2[PATH_MAX];
      snprintf(s2, sizeof s2, "%s/%s", src, e->d_name);
      snprintf(d2, sizeof d2, "%s/%s", dst, e->d_name);
      recursive_copy(s2, d2);
    }
    closedir(d);
  } else {
    copy_file(src, dst, st.st_mode);
  }
}

/* $TMPDIR, not $HOME: cosmo's Windows path translation reliably handles
 * /tmp-rooted absolute paths for exec(), but NOT arbitrary $HOME-derived
 * paths like /home/user/... (a Linux-FHS convention with no clean
 * Windows equivalent) -- confirmed empirically: execv() on the exact
 * same file succeeds from a /tmp/... path and fails with "Exec format
 * error" from a /home/user/... path, under Wine. Using $TMPDIR avoids
 * that gap entirely. Downside: unlike ~/.cache, /tmp is commonly
 * cleared on reboot, so the toolchain gets re-extracted more often --
 * a worthwhile trade for actually working on Windows. */
static const char *cache_base_dir(void) {
  const char *t = getenv("TMPDIR");
  return (t && *t) ? t : "/tmp";
}

/* sets g_cache and reports whether it's already populated, without
 * needing to resolve assets at all on the (common) warm-cache path. */
static int cache_is_ready(void) {
  snprintf(g_cache, sizeof g_cache, "%s/minicosmocc/%s", cache_base_dir(), WRAPPER_VERSION);
  char ready[PATH_MAX];
  snprintf(ready, sizeof ready, "%s/minicosmocc/%s.ready", cache_base_dir(), WRAPPER_VERSION);
  return dir_exists(g_cache) && file_exists(ready);
}

/* embed-assets.py deliberately skips symlinks (like bin/ld ->
 * bin/x86_64-linux-cosmo-ld) to avoid storing a full duplicate copy of
 * the target's content for every alias name; recreate them here after
 * extraction instead. Harmless no-op when assets came from a plain
 * directory (dev/test mode), since those symlinks already exist for
 * real on disk in that case. */
static void create_tool_aliases(void) {
  /* only as/ld.bfd are ever actually invoked (gcc's own driver looks
   * them up via -B); every other binutils tool (ar, nm, objcopy, ...)
   * is unused by this pipeline and isn't staged at all. -fuse-ld=bfd
   * means plain "ld" is unused too. */
  static const char *ALIASES[] = {"as", "ld.bfd"};
  static const char *TREES[] = {"gcc-amd64", "gcc-arm64"};
  static const char *TRIPLES[] = {"x86_64-linux-cosmo", "aarch64-linux-cosmo"};

  for (size_t t = 0; t < sizeof TREES / sizeof TREES[0]; t++) {
    char bindir[PATH_MAX];
    snprintf(bindir, sizeof bindir, "%s/%s/bin", g_cache, TREES[t]);
    if (!dir_exists(bindir)) continue;
    for (size_t i = 0; i < sizeof ALIASES / sizeof ALIASES[0]; i++) {
      char target[PATH_MAX], link[PATH_MAX];
      snprintf(target, sizeof target, "%s-%s", TRIPLES[t], ALIASES[i]);
      snprintf(link, sizeof link, "%s/%s", bindir, ALIASES[i]);
      char target_full[PATH_MAX];
      snprintf(target_full, sizeof target_full, "%s/%s", bindir, target);
      if (file_exists(target_full)) {
        unlink(link); /* idempotent: fine if it's already a real symlink */
        symlink(target, link);
      }
    }
  }
}

static void populate_cache(void) {
  char ready[PATH_MAX];
  snprintf(ready, sizeof ready, "%s/minicosmocc/%s.ready", cache_base_dir(), WRAPPER_VERSION);

  char parent[PATH_MAX];
  snprintf(parent, sizeof parent, "%s/minicosmocc", cache_base_dir());
  mkdir_p(parent);

  if (!strncmp(g_assets, "/zip/", 5)) {
    fprintf(stderr, "minicosmocc: extracting embedded toolchain to %s (first run)...\n", g_cache);
    recursive_copy(g_assets, g_cache);
  } else if (!dir_exists(g_cache)) {
    /* dev/test mode (plain directory assets): try a symlink first (fast,
     * no ~250MB copy); fall back to a real recursive copy on platforms
     * without symlink support (e.g. some Windows configurations). */
    if (symlink(g_assets, g_cache) != 0) {
      recursive_copy(g_assets, g_cache);
    }
  }
  create_tool_aliases();
  FILE *f = fopen(ready, "w");
  if (f) fclose(f);
}

/* Both the amd64-target and arm64-target GCC toolchains are staged as
 * amd64-native binaries only (there is no arm64-native GCC at all): on
 * an arm64 host, Blink emulates whichever one is needed, regardless of
 * which architecture it's targeting -- Blink emulates the compiler's
 * own (amd64) execution, which is independent of what machine code the
 * compiler happens to emit as output. This is why only one toolchain
 * tree per target exists, and why needs_blink depends only on host. */
static void resolve_tooldir(const TargetSpec *t, HostArch host, char *out, size_t n, int *needs_blink) {
  snprintf(out, n, "%s/gcc-%s", g_cache, t->name);
  *needs_blink = (host == HOST_ARM64);
}

/* needs_blink (see resolve_tooldir) is only ever true for the
 * amd64-target toolchain on an arm64 host, so the only Blink build ever
 * invoked here is the one that runs natively on arm64 and emulates
 * amd64 guest code; a blink-amd64.elf would never be exercised, so it
 * isn't staged at all. */
static void blink_prefix(Cmd *c) {
  static char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/blink/blink-arm64.elf", g_cache);
  cmd_add(c, path);
}

/* apelink/fixupobj/pecheck are staged amd64-native only (same reasoning
 * as the gcc-* trees: no arm64-native variant is kept, so there is
 * nothing to select between -- Blink runs the one amd64-native copy of
 * each on an arm64 host). This also matters for a subtler reason: these
 * tools' "other" (arm64) slice was zeroed out during size trimming (see
 * strip-manifest.txt), so an arm64-native variant of the same file
 * would need ITS arm64 slice kept live instead, which staging doesn't
 * produce -- keeping a single amd64-only copy avoids that mismatch
 * entirely, not just duplicated files. */
static void add_host_tool(Cmd *c, HostArch host, const char *base) {
  if (host == HOST_ARM64) blink_prefix(c);
  static char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/apelink/%s-amd64", g_cache, base);
  cmd_add(c, path);
}

/* cc1/as are invoked directly here rather than through gcc's driver
 * (and ld.bfd directly rather than through collect2, in link_one
 * below). gcc's own bundled spawn helpers set POSIX_SPAWN_USEVFORK,
 * which Cosmopolitan's posix_spawn() unconditionally routes into a
 * broken vfork-nt.c mechanism on Windows -- confirmed by isolating
 * posix_spawn() from GCC entirely: even a trivial cosmo program spawning
 * a known-good APE binary via posix_spawn() fails under Wine, while
 * plain fork()+execv() (what run_or_die() uses) is reliable there.
 * Bypassing gcc/collect2 sidesteps the bug on Windows and behaves
 * identically on Linux, so there's exactly one code path for both.
 * This is a closed, not general-purpose, flag set: this wrapper only
 * ever targets one cosmo runtime configuration (no -mtiny/-mdbg/
 * -moptlinux support), so what gcc's driver would normally compute
 * dynamically is fixed here as constants captured via BUILDLOG. */
static void compile_one(const TargetSpec *t, HostArch host, const char *src,
                         const char *obj, int fat_build, char **extra, int nextra) {
  char tooldir[PATH_MAX];
  int needs_blink;
  resolve_tooldir(t, host, tooldir, sizeof tooldir, &needs_blink);

  char cc1_path[PATH_MAX], as_path[PATH_MAX], isys[PATH_MAX], asm_tmp[PATH_MAX];
  snprintf(cc1_path, sizeof cc1_path, "%s/libexec/gcc/%s/" GCC_VER "/cc1", tooldir, t->triple);
  snprintf(as_path, sizeof as_path, "%s/bin/%s-as", tooldir, t->triple);
  snprintf(isys, sizeof isys, "%s/include", g_cache);
  snprintf(asm_tmp, sizeof asm_tmp, "%s.s", obj);

  Cmd c;
  cmd_init(&c);
  if (needs_blink) blink_prefix(&c);
  cmd_add(&c, cc1_path);
  cmd_add(&c, "-quiet");
  cmd_add(&c, "-D__COSMOPOLITAN__");
  cmd_add(&c, "-D__COSMOCC__");
  if (fat_build) cmd_add(&c, "-D__FATCOSMOCC__");
  cmd_add(&c, "-include");
  cmd_add(&c, "libc/integral/normalize.inc");
  cmd_add(&c, "-fportcosmo");
  cmd_add(&c, "-fno-semantic-interposition");
  cmd_add(&c, "-fno-optimize-sibling-calls");
  cmd_add(&c, "-mno-omit-leaf-frame-pointer");
  cmd_add(&c, "-fno-schedule-insns2");
  cmd_add(&c, "-Wno-implicit-int");
  if (!strcmp(t->name, "amd64")) {
    cmd_add(&c, "-mno-tls-direct-seg-refs");
    cmd_add(&c, "-fpatchable-function-entry=18,16");
  } else {
    cmd_add(&c, "-ffixed-x18");
    cmd_add(&c, "-ffixed-x28");
    cmd_add(&c, "-fpatchable-function-entry=7,6");
    cmd_add(&c, "-fsigned-char");
  }
  cmd_add(&c, "-fno-inline-functions-called-once");
  cmd_add(&c, "-DFTRACE");
  cmd_add(&c, "-DSYSDEBUG");
  cmd_add(&c, "-fno-pie");
  cmd_add(&c, "-nostdinc");
  cmd_add(&c, "-isystem");
  cmd_add(&c, isys);
  cmd_add(&c, "-fno-omit-frame-pointer");
  for (int i = 0; i < nextra; i++) cmd_add(&c, extra[i]);
  cmd_add(&c, src);
  cmd_add(&c, "-o");
  cmd_add(&c, asm_tmp);
  run_or_die(&c);

  /* --64 selects the amd64-target assembler's 64-bit mode; the
   * arm64-target assembler has no analogous switch (AArch64 is always
   * 64-bit), so it's only added for the amd64 target. */
  Cmd ac;
  cmd_init(&ac);
  if (needs_blink) blink_prefix(&ac);
  cmd_add(&ac, as_path);
  if (!strcmp(t->name, "amd64")) cmd_add(&ac, "--64");
  cmd_add(&ac, "-o");
  cmd_add(&ac, obj);
  cmd_add(&ac, asm_tmp);
  run_or_die(&ac);
  unlink(asm_tmp);

  Cmd fx;
  cmd_init(&fx);
  add_host_tool(&fx, host, "fixupobj");
  cmd_add(&fx, obj);
  run_or_die(&fx);
}

/* ld.bfd directly, bypassing gcc's driver and collect2 -- same
 * reasoning as compile_one() above. collect2's constructor/destructor
 * collection is a non-issue here: this GCC was configured with
 * --enable-initfini-array, and this wrapper only ever links against its
 * own fixed crt.o/libcosmo.a, never arbitrary user static libraries
 * that might need legacy collect2 handling. */
static void link_one(const TargetSpec *t, HostArch host, const char *obj,
                      const char *elf_out, char **extra, int nextra) {
  char tooldir[PATH_MAX];
  int needs_blink;
  resolve_tooldir(t, host, tooldir, sizeof tooldir, &needs_blink);

  char ld_path[PATH_MAX], libdir[PATH_MAX], lds[PATH_MAX], apeo[PATH_MAX], crto[PATH_MAX];
  snprintf(ld_path, sizeof ld_path, "%s/bin/%s-ld.bfd", tooldir, t->triple);
  snprintf(libdir, sizeof libdir, "%s/lib", tooldir);
  snprintf(lds, sizeof lds, "%s/lib/%s", tooldir, t->lds);
  snprintf(apeo, sizeof apeo, "%s/lib/ape.o", tooldir);
  snprintf(crto, sizeof crto, "%s/lib/crt.o", tooldir);

  Cmd c;
  cmd_init(&c);
  if (needs_blink) blink_prefix(&c);
  cmd_add(&c, ld_path);
  cmd_add(&c, "-o");
  cmd_add(&c, elf_out);
  if (t->has_ape_o) cmd_add(&c, apeo);
  cmd_add(&c, crto);
  cmd_add(&c, "-static");
  cmd_add(&c, "--gc-sections");
  cmd_add(&c, "-z");
  cmd_add(&c, "noexecstack");
  cmd_add(&c, "-z");
  cmd_add(&c, "norelro");
  cmd_add(&c, "-L");
  cmd_add(&c, libdir);
  cmd_add(&c, "-T");
  cmd_add(&c, lds);
  static char pgsz[64];
  snprintf(pgsz, sizeof pgsz, "common-page-size=%s", t->common_page);
  cmd_add(&c, "-z");
  cmd_add(&c, pgsz);
  cmd_add(&c, "-z");
  cmd_add(&c, "max-page-size=16384");
  for (int i = 0; i < nextra; i++) cmd_add(&c, extra[i]);
  cmd_add(&c, obj);
  cmd_add(&c, "-lcosmo");
  run_or_die(&c);

  Cmd fx;
  cmd_init(&fx);
  add_host_tool(&fx, host, "fixupobj");
  cmd_add(&fx, elf_out);
  run_or_die(&fx);
}

static void apelink_join(HostArch host, const char *out_path, const char *elf_amd64, const char *elf_arm64) {
  char ape_x86[PATH_MAX], ape_arm[PATH_MAX], ape_m1[PATH_MAX];
  snprintf(ape_x86, sizeof ape_x86, "%s/apelink/ape-x86_64.elf", g_cache);
  snprintf(ape_arm, sizeof ape_arm, "%s/apelink/ape-aarch64.elf", g_cache);
  snprintf(ape_m1, sizeof ape_m1, "%s/apelink/ape-m1.c", g_cache);

  /* apelink wants exactly one -l loader stub per ELF slice actually
   * provided, in the same order; passing an extra loader for an arch
   * that has no matching ELF input produces a broken (non-MZ) output. */
  Cmd c;
  cmd_init(&c);
  add_host_tool(&c, host, "apelink");
  if (elf_amd64) {
    cmd_add(&c, "-l");
    cmd_add(&c, ape_x86);
  }
  if (elf_arm64) {
    cmd_add(&c, "-l");
    cmd_add(&c, ape_arm);
  }
  if (elf_arm64) {
    /* the macOS Apple Silicon loader source is only meaningful when the
     * output also carries a native aarch64 ELF slice for it to load. */
    cmd_add(&c, "-M");
    cmd_add(&c, ape_m1);
  }
  cmd_add(&c, "-o");
  cmd_add(&c, out_path);
  if (elf_amd64) cmd_add(&c, (char *)elf_amd64);
  if (elf_arm64) cmd_add(&c, (char *)elf_arm64);
  run_or_die(&c);

  Cmd pc;
  cmd_init(&pc);
  add_host_tool(&pc, host, "pecheck");
  cmd_add(&pc, out_path);
  run_or_die(&pc);
}

static void maybe_recommend_flags(char **extra, int nextra) {
  int have_ffs = 0, have_fds = 0, have_gcs = 0, have_icf = 0;
  for (int i = 0; i < nextra; i++) {
    if (!strcmp(extra[i], "-ffunction-sections")) have_ffs = 1;
    if (!strcmp(extra[i], "-fdata-sections")) have_fds = 1;
    if (!strcmp(extra[i], "--gc-sections") || !strcmp(extra[i], "-Wl,--gc-sections")) have_gcs = 1;
    if (!strcmp(extra[i], "--icf=all") || !strcmp(extra[i], "-Wl,--icf=all")) have_icf = 1;
  }
  if (!(have_ffs && have_fds && have_gcs && have_icf)) {
    fprintf(stderr,
            "minicosmocc: note: consider adding -ffunction-sections -fdata-sections "
            "--gc-sections --icf=all for smaller binaries\n");
  }
}

static void unlink_if_not_saving(const char *path) {
  if (!g_save_temps) unlink(path);
}

static void usage(void) {
  fprintf(stderr,
          "usage: minicosmocc.com [-c] [-o OUTPUT] [--target=amd64|arm64] [-save-temps] "
          "[-I DIR] [-L DIR] [-l LIB] [-D DEF] [flags...] FILE.c...\n");
  exit(1);
}

int main(int argc, char **argv) {
  if (!cache_is_ready()) {
    find_assets(argv[0]);
    populate_cache();
  }

  HostArch host = detect_host();

  char *sources[MAX_ARGS];
  int nsources = 0;
  char *extra[MAX_ARGS];
  int nextra = 0;
  char *link_extra[MAX_ARGS];
  int nlink_extra = 0;
  char *output = NULL;
  int compile_only = 0;
  const char *explicit_target = NULL;

  for (int i = 1; i < argc; i++) {
    char *a = argv[i];
    if (!strcmp(a, "-c")) {
      compile_only = 1;
    } else if (!strcmp(a, "-save-temps")) {
      g_save_temps = 1;
    } else if (!strcmp(a, "-o")) {
      if (++i >= argc) usage();
      output = argv[i];
    } else if (!strncmp(a, "-o", 2) && a[2]) {
      output = a + 2;
    } else if (!strncmp(a, "--target=", 9)) {
      explicit_target = a + 9;
      if (strcmp(explicit_target, "amd64") && strcmp(explicit_target, "arm64"))
        die("--target must be amd64 or arm64, got %s", explicit_target);
    } else if (!strncmp(a, "-L", 2) || !strncmp(a, "-l", 2)) {
      link_extra[nlink_extra++] = a;
    } else if (a[0] == '-') {
      extra[nextra++] = a;
    } else if (strlen(a) > 2 && !strcmp(a + strlen(a) - 2, ".c")) {
      sources[nsources++] = a;
    } else {
      /* pre-built .o or other input: forward to the link step */
      link_extra[nlink_extra++] = a;
    }
  }
  if (nsources == 0) {
    fprintf(stderr, "minicosmocc: no input .c files\n");
    usage();
  }
  if (nsources > 1) die("this minimal wrapper supports exactly one source file per invocation");

  maybe_recommend_flags(extra, nextra);

  int fat_build = (explicit_target == NULL);
  int want_amd64 = fat_build || !strcmp(explicit_target, "amd64");
  int want_arm64 = fat_build || !strcmp(explicit_target, "arm64");

  char scratch_dir[] = "/tmp/minicosmocc.XXXXXX";
  if (!mkdtemp(scratch_dir)) die("mkdtemp failed: %s", strerror(errno));

  char obj_amd64[PATH_MAX] = "", obj_arm64[PATH_MAX] = "";
  if (want_amd64) snprintf(obj_amd64, sizeof obj_amd64, "%s/out.amd64.o", scratch_dir);
  if (want_arm64) snprintf(obj_arm64, sizeof obj_arm64, "%s/out.arm64.o", scratch_dir);

  if (compile_only) {
    /* -c: compile-only builds just the host's own target unless
     * --target= was given explicitly; a single .o isn't a fat artifact. */
    const TargetSpec *t = (host == HOST_AMD64) ? &TARGET_AMD64 : &TARGET_ARM64;
    if (explicit_target) t = !strcmp(explicit_target, "amd64") ? &TARGET_AMD64 : &TARGET_ARM64;
    char *obj = !strcmp(t->name, "amd64") ? obj_amd64 : obj_arm64;
    if (!obj[0]) snprintf(obj, PATH_MAX, "%s/out.o", scratch_dir);
    compile_one(t, host, sources[0], obj, 0, extra, nextra);
    const char *dest = output ? output : "a.o";
    struct stat st;
    if (stat(obj, &st) != 0) die("cannot stat %s: %s", obj, strerror(errno));
    copy_file(obj, dest, st.st_mode);
    unlink_if_not_saving(obj);
    rmdir(scratch_dir);
    return 0;
  }

  char elf_amd64[PATH_MAX] = "", elf_arm64[PATH_MAX] = "";
  if (want_amd64) {
    snprintf(elf_amd64, sizeof elf_amd64, "%s/out.amd64.elf", scratch_dir);
    compile_one(&TARGET_AMD64, host, sources[0], obj_amd64, fat_build, extra, nextra);
    link_one(&TARGET_AMD64, host, obj_amd64, elf_amd64, link_extra, nlink_extra);
  }
  if (want_arm64) {
    snprintf(elf_arm64, sizeof elf_arm64, "%s/out.arm64.elf", scratch_dir);
    compile_one(&TARGET_ARM64, host, sources[0], obj_arm64, fat_build, extra, nextra);
    link_one(&TARGET_ARM64, host, obj_arm64, elf_arm64, link_extra, nlink_extra);
  }

  const char *out_path = output ? output : "a.out";
  apelink_join(host, out_path, want_amd64 ? elf_amd64 : NULL, want_arm64 ? elf_arm64 : NULL);

  if (!g_save_temps) {
    if (want_amd64) { unlink(obj_amd64); unlink(elf_amd64); }
    if (want_arm64) { unlink(obj_arm64); unlink(elf_arm64); }
    rmdir(scratch_dir);
  } else {
    fprintf(stderr, "minicosmocc: kept intermediates in %s\n", scratch_dir);
  }

  return 0;
}
