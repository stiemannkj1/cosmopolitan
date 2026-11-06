#!/usr/bin/env python3
"""Run every Lua test in this repo on each target that is available.

Use the Python that this repo builds, from the repo root:

  make -j8 o//third_party/python/python3
  o/third_party/python/python3 scripts/run_lua_tests.py [options] [filter ...]

The tests are test/tool/net/*_test.lua, run as `redbean -i TEST` like the
.lua.runs rule in build/rules.mk does, plus scripts/luaext_test.lua and
scripts/luahttp_test.lua, which run on the lua APE, o/lua.com.

Targets, each skipped with a note when its binary or emulator is missing

  native    o/tool/net/redbean on this machine
  fat       o/redbean.com on this machine
  qemu      o/aarch64/tool/net/redbean under qemu-aarch64
  qemu-fat  o/redbean.com under qemu-aarch64 through the APE loader
  wine      o/redbean.com under wine

Everything runs one test at a time, never in parallel. A test spawns the
binary under test as a child, and starting a binary that another run has
open for writing fails with "Text file busy".

The exit status is 0 only if no test failed or timed out. Arguments that do
not start with a dash select tests whose path contains that text.
"""

import argparse
import glob
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APE_LOADER = '.cosmocc/current/bin/ape-aarch64.elf'

# (target, test path) -> why that test cannot pass there. Shown as SKIP.
# Empty means every test is expected to pass everywhere.
KNOWN_SKIPS = {
    ('wine', 'test/tool/net/lunix_test.lua'):
        'fails at an fstat blocks and mode check, same on the unmodified file',
}


def rel(path):
    return os.path.join(ROOT, path)


def have(path):
    return os.path.exists(rel(path))


def targets():
    """Maps each target name to (prefix for redbean, prefix for lua, note)."""
    qemu = shutil.which('qemu-aarch64')
    wine = shutil.which('wine')
    out = {}

    def add(name, redbean, lua, needs, missing):
        if missing:
            out[name] = (None, None, missing)
        elif not all(have(p) for p in needs):
            out[name] = (None, None, 'not built: ' + ', '.join(
                p for p in needs if not have(p)))
        else:
            out[name] = (redbean, lua, None)

    add('native', ['o/tool/net/redbean'], ['o/lua.com'],
        ['o/tool/net/redbean', 'o/lua.com'], None)
    add('fat', ['o/redbean.com'], ['o/lua.com'],
        ['o/redbean.com', 'o/lua.com'], None)
    add('qemu', [qemu, 'o/aarch64/tool/net/redbean'],
        [qemu, APE_LOADER, 'o/lua.com'],
        ['o/aarch64/tool/net/redbean', APE_LOADER, 'o/lua.com'],
        None if qemu else 'qemu-aarch64 not on PATH')
    add('qemu-fat', [qemu, APE_LOADER, 'o/redbean.com'],
        [qemu, APE_LOADER, 'o/lua.com'],
        ['o/redbean.com', APE_LOADER, 'o/lua.com'],
        None if qemu else 'qemu-aarch64 not on PATH')
    add('wine', [wine, 'o/redbean.com'], [wine, 'o/lua.com'],
        ['o/redbean.com', 'o/lua.com'],
        None if wine else 'wine not on PATH')
    return out


def tests():
    """Returns (path, kind) pairs, kind is 'redbean' or 'lua'."""
    found = []
    for path in sorted(glob.glob(rel('test/tool/net/*_test.lua'))):
        found.append((os.path.relpath(path, ROOT), 'redbean'))
    for name in ('luaext_test.lua', 'luahttp_test.lua'):
        if have('scripts/' + name):
            found.append(('scripts/' + name, 'lua'))
    return found


def command(prefix, kind, test):
    # every run starts in the repo root, so repo paths stay relative, which
    # is also what wine wants, and qemu and wine are absolute from PATH
    return list(prefix) + (['-i', test] if kind == 'redbean' else [test])


def run_one(argv, env, timeout):
    start = time.time()
    proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
        status = 'PASS' if proc.returncode == 0 else 'FAIL'
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        out, _ = proc.communicate()
        status = 'TIMEOUT'
    text = out.decode('utf-8', 'replace')
    return status, time.time() - start, proc.returncode, text


def main():
    # show progress as it happens even when piped or redirected
    sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', 1, errors='replace')
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('filters', nargs='*', help='only tests whose path contains one of these')
    parser.add_argument('-t', '--targets', default='native,fat,qemu,qemu-fat,wine',
                        help='comma separated list of targets to use')
    parser.add_argument('--timeout', type=float, default=300,
                        help='seconds allowed for each test, default 300')
    parser.add_argument('-x', '--fail-fast', action='store_true',
                        help='stop at the first failure')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='show the output of every test, not only failures')
    parser.add_argument('--list', action='store_true',
                        help='list the tests and targets and exit')
    parser.add_argument('--no-known-skips', action='store_true',
                        help='run tests that are listed as known not to work')
    args = parser.parse_args()

    avail = targets()
    wanted = [t for t in args.targets.split(',') if t]
    for t in wanted:
        if t not in avail:
            parser.error('unknown target %s, choose from %s' % (t, ', '.join(avail)))
    selected = [(p, k) for p, k in tests()
                if not args.filters or any(f in p for f in args.filters)]

    if args.list:
        for name in avail:
            note = avail[name][2]
            print('target %-9s %s' % (name, 'available' if not note else 'unavailable, ' + note))
        for path, kind in selected:
            print('test   %-6s %s' % (kind, path))
        return 0
    if not selected:
        print('no tests match', file=sys.stderr)
        return 2

    tmpdir = tempfile.mkdtemp(prefix='run_lua_tests.')
    env = dict(os.environ, TMPDIR=tmpdir)
    before = set(glob.glob(rel('cosmo-spawn-test-*')))
    totals = {}
    failures = []
    stop = False
    try:
        for name in wanted:
            redbean, lua, note = avail[name]
            counts = {'PASS': 0, 'FAIL': 0, 'TIMEOUT': 0, 'SKIP': 0}
            totals[name] = counts
            print('\n=== %s' % name)
            if note:
                print('  skipped, %s' % note)
                counts['SKIP'] = len(selected)
                continue
            for path, kind in selected:
                why = None if args.no_known_skips else KNOWN_SKIPS.get((name, path))
                if why:
                    counts['SKIP'] += 1
                    print('  SKIP     %-52s %s' % (path, why))
                    continue
                argv = command(redbean if kind == 'redbean' else lua, kind, path)
                status, secs, code, text = run_one(argv, env, args.timeout)
                counts[status] += 1
                print('  %-8s %-52s %6.1fs' % (status, path, secs))
                if status != 'PASS':
                    failures.append((name, path, status, code))
                if status != 'PASS' or args.verbose:
                    lines = text.rstrip('\n').split('\n')
                    shown = lines if args.verbose else lines[-20:]
                    for line in shown:
                        print('      | ' + line)
                if status != 'PASS' and args.fail_fast:
                    stop = True
                    break
            if stop:
                break
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        # a killed or crashed run can leave the spawn suite's scratch directory
        for leftover in set(glob.glob(rel('cosmo-spawn-test-*'))) - before:
            shutil.rmtree(leftover, ignore_errors=True)

    print('\n=== summary')
    print('  %-9s %6s %6s %8s %6s' % ('target', 'pass', 'fail', 'timeout', 'skip'))
    for name, c in totals.items():
        print('  %-9s %6d %6d %8d %6d' % (name, c['PASS'], c['FAIL'], c['TIMEOUT'], c['SKIP']))
    if failures:
        print('\nfailed:')
        for name, path, status, code in failures:
            print('  %-9s %-52s %s (exit %s)' % (name, path, status, code))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
