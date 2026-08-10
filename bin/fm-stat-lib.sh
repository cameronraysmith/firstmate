# shellcheck shell=bash
# Which stat(1) dialect does the stat on PATH actually speak?
# Usage: . bin/fm-stat-lib.sh
#
#   fm_stat_is_gnu          - true when `stat -c <format>` is the working form
#   fm_stat_flavor          - echoes gnu|bsd|none; nonzero exit for none
#
# Callers must not infer the dialect from `uname`. A GNU coreutils stat ahead of
# /usr/bin/stat on a macOS PATH answers only the GNU `-c` form, so a
# Darwin-keyed caller hands `-f` to a stat that rejects it, which is how a
# nix-managed macOS host silently loses every mtime, mode, device, inode, and
# link-count read at once. Ask the implementation instead of the kernel.
#
# The GNU form is probed FIRST, with its output discarded, because that ordering
# is the only one that cannot corrupt a caller: a GNU stat given the BSD `-f`
# form exits nonzero but still writes a filesystem dump to stdout, while a BSD
# stat given the GNU `-c` form writes nothing at all. `stat --version` is
# deliberately not probed - it answers who built this stat, not whether the
# format flag works here.
#
# The verdict is resolved lazily, so a lib sourced on a hot path costs nothing
# until it first needs a stat, and it is cached against the PATH it was resolved
# under. Caching against the process alone would be wrong: callers legitimately
# narrow PATH mid-process (a minimal /usr/bin:/bin, a fakebin shim), and the
# system stat there can speak a different dialect than the one that answered the
# first probe. The cache key is what makes the verdict describe the stat this
# call will actually invoke rather than one some earlier call happened to find.

_fm_stat_cache_valid() {
  [ -n "${_FM_STAT_FLAVOR:-}" ] && [ "${_FM_STAT_FLAVOR_PATH-}" = "${PATH-}" ]
}

fm_stat_detect() {
  if stat -c %h / >/dev/null 2>&1; then
    _FM_STAT_FLAVOR=gnu
  elif stat -f %l / >/dev/null 2>&1; then
    _FM_STAT_FLAVOR=bsd
  else
    _FM_STAT_FLAVOR=none
    printf 'fm-stat-lib: no usable stat(1) on PATH: neither the GNU -c form nor the BSD -f form works\n' >&2
  fi
  _FM_STAT_FLAVOR_PATH=${PATH-}
  [ "$_FM_STAT_FLAVOR" != none ]
}

fm_stat_flavor() {
  _fm_stat_cache_valid || fm_stat_detect || :
  printf '%s\n' "$_FM_STAT_FLAVOR"
  [ "$_FM_STAT_FLAVOR" != none ]
}

fm_stat_is_gnu() {
  _fm_stat_cache_valid || fm_stat_detect || :
  [ "$_FM_STAT_FLAVOR" = gnu ]
}
