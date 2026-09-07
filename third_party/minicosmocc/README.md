# minicosmocc

A minimal Cosmopolitan/APE C compiler wrapper. Compiles a single C
source file into a fat (amd64+arm64 native) APE binary that runs
unmodified on Linux, Windows (including under Wine), and, via Blink,
on arm64 hosts.

See `SUMMARY.md` for the full history and design rationale, and
`scripts/strip-manifest.txt` for what's stripped from the underlying
`cosmocc` release and why.

## Rebuild or test from scratch

Requires the full cosmopolitan monorepo checkout (this project builds
`apelink` and the ape loader from local source).

```
scripts/minicosmocc.py build            # stage + build dist/minicosmocc.com
scripts/minicosmocc.py build-uncached   # same, but redownload the cosmocc release
scripts/minicosmocc.py test              # stage + build + run the full test suite
```

Each command starts with a full clean (`build/`, `dist/`, test scratch,
and APE loader caches). Set `COSMOCC_VERSION` to stage from a
different `cosmocc` release.

## Usage

```
dist/minicosmocc.com [-c] [-o OUTPUT] [--target=amd64|arm64] [-save-temps] \
    [-I DIR] [-L DIR] [-l LIB] [-D DEF] [flags...] FILE.c
```

- Exactly one `.c` file per invocation. Output defaults to `a.out`.
- No target flag produces a fat binary that runs natively on both
  amd64 and arm64.
- `-c` compiles only, skipping the link step.
- `--target=amd64` or `--target=arm64` produces single-arch output
  instead of fat (known bug in this mode, see SUMMARY.md's "Known
  limitations").
- `-save-temps` keeps the scratch build directory instead of deleting
  it.
- `-I`/`-D`/other compiler flags are forwarded to `cc1`. `-L`/`-l` are
  forwarded to the link step.

Examples:

```
dist/minicosmocc.com -o hello hello.c
dist/minicosmocc.com -c -o hello.o hello.c
dist/minicosmocc.com --target=amd64 -o hello.amd64 hello.c
```
