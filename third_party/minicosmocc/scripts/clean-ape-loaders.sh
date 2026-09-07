#!/bin/bash
# Removes every known APE loader install location before a test run, so
# tests can prove a binary needs no pre-installed loader. Global system
# paths and binfmt_misc entries need root; this script uses sudo only
# when something actually needs removing, and only for APE's own
# binfmt_misc entries (APE, APE-jart) -- it never touches unrelated
# entries like qemu-aarch64's own binfmt registration.
set -uo pipefail

TMPDIR="${TMPDIR:-/tmp}"
FOUND_UNREMOVABLE=0

have_sudo() {
  [ "$(id -u)" = "0" ] && return 0
  sudo -n true 2>/dev/null
}

remove_path() {
  local path="$1" desc="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ "$(id -u)" = "0" ] || [ -w "$(dirname "$path")" ]; then
    rm -rf "$path"
    echo "removed $desc: $path"
  elif have_sudo; then
    sudo rm -rf "$path"
    echo "removed (sudo) $desc: $path"
  else
    echo "WARNING: $desc exists at $path but no permission (and no non-interactive sudo) to remove it" >&2
    FOUND_UNREMOVABLE=1
  fi
}

unregister_binfmt() {
  local entry="$1" bf="/proc/sys/fs/binfmt_misc/$1"
  if [ ! -e "$bf" ]; then
    return 0
  fi
  if [ "$(id -u)" = "0" ]; then
    echo -1 > "$bf"
    echo "unregistered binfmt_misc entry: $entry"
  elif have_sudo; then
    sudo sh -c "echo -1 > '$bf'"
    echo "unregistered (sudo) binfmt_misc entry: $entry"
  else
    echo "WARNING: binfmt_misc entry $entry is registered but no permission (and no non-interactive sudo) to unregister it" >&2
    FOUND_UNREMOVABLE=1
  fi
}

echo "==> cleaning APE loaders"

# global loader locations
remove_path /usr/bin/ape "global APE loader"
remove_path /usr/local/bin/ape "global APE loader (local)"

# user-level loader locations (cosmo self-extracts here per docs)
remove_path "$HOME/.ape" "user APE loader dir"
remove_path "$HOME/.local/bin/ape" "user APE loader"
for f in "$HOME"/.ape-*; do
  if [ -e "$f" ]; then remove_path "$f" "user APE loader"; fi
done

# temp loader locations
for f in /tmp/.ape-* "$TMPDIR"/ape* "$TMPDIR"/.ape-*; do
  if [ -e "$f" ]; then remove_path "$f" "temp APE loader"; fi
done

# binfmt_misc: only APE's own entries, never qemu-* or other unrelated ones
unregister_binfmt APE
unregister_binfmt APE-jart

echo "==> verifying nothing remains (and nothing was silently reinstalled)"
STILL_PRESENT=0
for p in /usr/bin/ape /usr/local/bin/ape "$HOME/.ape" "$HOME/.local/bin/ape"; do
  if [ -e "$p" ]; then
    echo "STILL PRESENT: $p" >&2
    STILL_PRESENT=1
  fi
done
for f in /tmp/.ape-* "$TMPDIR"/ape* "$TMPDIR"/.ape-* "$HOME"/.ape-*; do
  if [ -e "$f" ]; then
    echo "STILL PRESENT: $f" >&2
    STILL_PRESENT=1
  fi
done
for entry in APE APE-jart; do
  if [ -e "/proc/sys/fs/binfmt_misc/$entry" ]; then
    echo "STILL REGISTERED: $entry" >&2
    STILL_PRESENT=1
  fi
done

if [ "$STILL_PRESENT" = "1" ] || [ "$FOUND_UNREMOVABLE" = "1" ]; then
  echo "==> cleanup incomplete: APE loader remnants remain (see above)" >&2
  exit 1
fi
echo "==> confirmed: no APE loader present (global, user, temp, or binfmt_misc)"
