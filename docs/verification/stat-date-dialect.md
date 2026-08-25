# stat(1) and date(1) dialect verification

Active empirical evidence that the dialect probes in
[`bin/fm-stat-lib.sh`](../../bin/fm-stat-lib.sh) and `tests/lib.sh` answer correctly on a host where
`uname` and the resolved coreutils disagree, and the fixture obligation that follows from it.
[`bin/fm-stat-lib.sh`](../../bin/fm-stat-lib.sh)'s header owns the probe contract itself; this file
records only the measurement and the fixture rule.

## The host the probes exist for

Measured 2026-08-24 on macOS 26.5.0 arm64, nix-managed PATH, GNU coreutils 9.11.

```
$ uname
Darwin
$ which -a stat
/nix/store/f0100xb3jh1wz822ngh721h898nqpwj7-coreutils-9.11/bin/stat
/etc/profiles/per-user/crs58/bin/stat
/usr/bin/stat
$ stat -c %h /
22
$ stat -f %m /tmp
stat: cannot read file system information for '%m': No such file or directory
  File: "/tmp"
```

`uname` reports Darwin while the stat that actually resolves is GNU, so a Darwin-keyed caller hands
`-f` to a stat that answers only `-c`. The probe reports `gnu` here and the caller reads a real
mtime:

```
$ . bin/fm-stat-lib.sh && fm_stat_flavor
gnu
```

The same split applies to `date(1)`: GNU `date -r <epoch>` reads its operand as a file name rather
than an epoch, so a Darwin-keyed fixture that renders a timestamp through `date -r` produces an
empty stamp and the `touch` it feeds silently does nothing.

## The obligation this puts on fixtures

A fixture that stubs `stat` or `date` must answer the probe's question, not only the one format its
caller happens to read. `bin/fm-stat-lib.sh` decides the dialect by asking whether the GNU form
works at all (`stat -c %h /`); a stub that answers `-c %Y` and nothing else fails that probe and is
classified BSD, which is the inference the lib exists to remove.

A fixture that stages a `bin/` library into a sandbox must stage
[`bin/fm-stat-lib.sh`](../../bin/fm-stat-lib.sh) alongside it whenever that library sources the
probe, or the staged copy dies at source time inside the sandbox. The current dependents are listed
by `grep -l fm-stat-lib.sh bin/*.sh`.

Both rules are regression-checked by `tests/fm-stat-lib.test.sh` and `tests/fm-date-dialect.test.sh`
for the probes themselves, and by `tests/fm-busy-state.test.sh` and
`tests/fm-pi-branch-extension.test.sh` for the two fixture shapes above.

## Refreshing this record

Re-run the measurement above after a coreutils or macOS upgrade, and re-run
`bin/fm-test-run.sh tests/fm-stat-lib.test.sh tests/fm-date-dialect.test.sh tests/fm-busy-state.test.sh`
to confirm the probes and the fixture rule still hold.
