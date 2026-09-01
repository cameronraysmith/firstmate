# Upstream cascade onto kunchenguid/main 10b93b2

Run record for the cascade-rebase of stack 18 (26 layers, `fm/01` … `fm/24` plus
`fm/fm-atomic-identity` and `fm/fm-atomic-pi-adapt`) from base `038d0f7` onto
upstream `10b93b2`, run 2026-08-27.

It landed in two rounds, because upstream advanced mid-run. Round 1 published
onto `d63b0e2`; round 2 carried that published stack forward onto `10b93b2`.
Both are recorded here, because the round 1 resolutions are still the ones in
force and the next cascade needs them.

This is a measured record of one job, not the procedure. It exists so the next
cascade can tell a deliberate resolution from a merge accident.

## Final result

| | |
|---|---|
| upstream tip | `10b93b2` — `fix(bin): recover Claude auto-arm from hung claims (#3156)` |
| original base | `038d0f7` |
| original stack tip | `4076042` |
| final stack tip | `0447bbe` |
| layers | 26, published in one `git push --atomic` per round |

Upstream's tip was re-resolved from the remote at the start of each round rather
than taken from the dispatch, which is how the second round's two commits were
found at all.

### Recovery points

Both are on `origin` and neither has been moved:

| ref | pinned at | what it recovers |
|---|---|---|
| `backup/stack18-precascade-20260827T053532Z` + tag | `4076042` | the state before **any** cascade |
| `backup/stack18-d63b0e2-20260827T140227Z` + tag | `57862b0` | the round 1 published state |

## Round 2 — d63b0e2 → 10b93b2

Two upstream commits: `5953e9b`
`fix(bin): keep a declared wait on the pause cadence under a busy pane or enriched wedge (#3155)`
and `10b93b2` `fix(bin): recover Claude auto-arm from hung claims (#3156)`.

`main` was fast-forwarded `d63b0e2` → `10b93b2` first, non-forced, 0 commits
ahead. Leases were re-read from `origin`, so each lease pinned the SHA that round
1 actually published rather than the original pre-cascade value.

### The one collision: `fm/11-declared-wait-stale-escalation`

Upstream's #3155 and our `fm/11` both change declared-wait handling, and they
land on the same two lines of `docs/configuration.md`. They turn out to be
**complementary, not competing**, which is only visible at the level of
behaviour:

- Upstream widens **when** a declared wait keeps its window: the away-mode
  daemon's re-surface recheck no longer reads a busy pane as "the crew resumed",
  and ages the window against the crew's own latest status line instead.
- Ours widens **what counts as** a declared wait: a crew idling on a long call it
  started itself, not only an external wait. That is the "external" that `fm/11`
  drops from the verb's definition.

Upstream's own rationale is our case exactly — "a worker sitting on a long
foreground call keeps that call live for as long as the wait lasts" — so the
resolution keeps our wording and upstream's appended clause on both lines. Each
fix makes the other more useful: upstream stops a busy pane retiring the window,
and ours is what puts a self-declared background wait inside that window in the
first place.

No other layer conflicted.

### Verification

| check | result |
|---|---|
| ancestry, edge by edge (`git merge-base --is-ancestor`) | **26 edges, 0 failures** |
| every layer contains the upstream tip | 26/26 |
| any layer left on the previous base's history | 0 |
| merge commits in the new range | **0** |
| conflict markers across all 26 final trees | **0** |
| commits | 66 → 66 |

`git range-diff d63b0e2..57862b0 10b93b2..0447bbe`:

| pairing | count |
|---|---|
| rows total | 66 |
| identical (`=`) | 64 |
| modified (`!`) | 2 |
| unmatched, only in NEW (`>`) | **0** |
| unmatched, only in OLD (`<`) | **0** |

Nothing unmatched in either direction. The two modified commits are `fm/11`'s
docs commit, resolved above, and one `fm/04` test commit the three-way merge
adjusted against upstream's watcher changes.

**Upstream's fixes were checked for survival, not assumed.** A replayed layer can
merge cleanly and still silently drop part of an upstream change, so every
substantive line the two new upstream commits add was checked for presence in the
same file at the cascaded tip: **1,024 added lines, 1 absent** — and that one is
the `declared external wait` phrasing this fork deliberately replaces. Both
upstream fixes are otherwise intact.

### Tests

Selection: the 11 suites covering this round's collision area — the declared-wait
classifier and briefs, the daemon, turn-end guard and Claude auto-arm files
upstream changed, and the watcher-lock layer whose commit the merge adjusted.
The full 177-script changed selection was **not** repeated: it re-runs the whole
stack's diff against the base, which is round 1's evidence, not this round's.

**11 scripts, 1 failed, 0 gate-skipped**, 9m19s. **Zero introduced failures.**

`fm-watcher-lock` fails at the new base `10b93b2` on a clean upstream checkout
with none of our layers present, so it is pre-existing. `bin/fm-lint.sh` exits 1
solely because `actionlint` is absent from this host; ShellCheck 0.11.0 itself is
clean.

## Round 1 — 038d0f7 → d63b0e2

| | |
|---|---|
| upstream tip | `d63b0e2` — `fix(pi): prevent stale captain outcome re-emissions (#3154)` |
| stack tip | `4076042` → `57862b0` |

`main` was fast-forwarded `038d0f7` → `d63b0e2` before the cascade, because
gh-stack rebases onto `origin/main`. It was a true fast-forward: our mirror was 0
commits ahead and `origin/main` was a verified ancestor of the upstream tip.

### Verification

26 ancestry edges checked individually, 0 failures; 0 merge commits; 0 conflict
markers; 63 → 66 commits. `git range-diff 038d0f7..4076042 d63b0e2..57862b0`
gave 66 rows: 48 identical, 15 modified, 3 only-in-new, **0 only-in-old**. All 63
pre-cascade commits paired; the 3 new commits are the adaptations below.

### Cascade mechanism, both rounds

Bottom-to-top, one explicit `git rebase --onto` per layer — deliberately **not**
`git rebase --update-refs`. `--update-refs` moves every branch pointing into the
replayed range, and the backup branches point at the old stack tips, so it would
have dragged them forward and destroyed the recovery points.

Round 1 also had to clear a precondition: `fm/24-omp-branch-supervision` was
checked out in another worktree, and `--update-refs` silently skips refs held
elsewhere. That worktree's HEAD was detached in place at the same commit —
worktree, branch and commits untouched, PR 33 intact.

### Conflict resolutions

Nine layers conflicted in round 1. The rule throughout both rounds: keep
upstream's structural improvement, preserve our behaviour, and judge by which
behaviour survives rather than which lines collided.

| Layer | Collision | Resolution |
|---|---|---|
| `fm/01` | upstream and we appended different cases to the same test-runner list, and different files to the same sandbox `cp` list | both kept |
| `fm/05` | **both sides bumped `FM_OPEN_DECISIONS_FOLD_VERSION` 4→5**, for different fold-semantics changes: upstream's unbracketed correlation token (#1967), ours malformed-key derivation | bumped to **6**. The read sites compare that constant by **equality**, not ordering, so only a third value discards a cursor persisted under either reading and rebuilds from byte 0 |
| `fm/11` | our layer drops "external" from the declared-wait definition; upstream extended the reporting-trigger list and added a standing-merge-authority line | ours for the definition, upstream's for the list and the new line |
| `fm/14` | our layer restructured the GitHub case into local-fast-forward-by-default vs. explicit forge merge; upstream (#3104) added a merged-state confirmation gate after the forge command, which the restructure displaced | gate moved **inside the forge branch**. A queued-but-not-landed merge is a forge-side failure mode only: `land_local_fast_forward` pushes non-forced and then re-reads the base to prove it contains the validated head. Upstream's `test_queued_github_merge_leaves_the_poll_armed` covers the placement |
| `fm/14` | upstream added a durable-outcome suite and we added a local-fast-forward suite at the same point | both kept; the lettered header index merged with upstream's cases relettered `(af)`–`(am)` |
| `fm/20` | upstream re-measured the signed Pi CLI and sharpened the refresh instruction; we appended the omp section | upstream's paragraph, then our section |
| `fm/20` | we re-rooted extension staging into `.pi/`+`.omp/` subtrees; upstream added `fm-branch-model-picker.ts` to the old flat list | our layout, carrying upstream's new file into it |
| `fm/fm-atomic-pi-adapt` | our Calm retirement vs. upstream's Calm fixes | see below |
| `fm/24` | upstream tightened the supervision-branch prose to delegate detail to its owners; we widened it to omp and added omp-only facts | upstream's structure, widened, carrying our facts |

None was a behaviour-level either/or, so none needed a decision above the cascade.

### Two defects a clean replay hid

Both are cases where nothing conflicted, so the rebase produced a tree that
merged perfectly and behaved wrongly.

**1. Upstream #3024 vs. the Calm retirement.** Upstream made
`.pi/extensions/fm-branch-supervision.ts` import `./lib/fm-calm-visibility.ts`.
That import did not exist when the layer was written, so the deletion replayed
cleanly onto a tree that now needs the module — leaving the Pi supervision branch
extension unable to load at all (`ERR_MODULE_NOT_FOUND`).

`lib/fm-calm-visibility.ts` is therefore retained. Safety for the atomic primary
was **measured, not assumed**: against the installed atomic 0.9.15, its two value
imports (`getMarkdownTheme`, `UserMessageComponent`) are both exported from the
`dist/index.d.ts` atomic aliases the Pi specifier to, while
`createGrepToolDefinition` — the actual crash, imported only by `fm-calm.ts` — is
not. `lib/` modules are imported, never loaded as extensions, so the retained
file adds no extension to any host's load set.

The captain has since ruled that **Calm stays** and is not to be retired, and
that the atomic crash is fixable by renaming one factory. Retaining
`lib/fm-calm-visibility.ts` is consistent with that ruling. Reversing the
retirement layer itself is a separate task and was explicitly out of scope here,
so `fm/fm-atomic-pi-adapt` still removes `fm-calm.ts` and the three presentation
layout modules.

**2. Upstream #3154 vs. our omp port.** The fix landed on the Pi extension while
`fm/24`'s omp port of that same extension was in flight. The port is a new file,
so nothing conflicted and the defect came back silently on the omp side. Carried
across as its own commit, with a regression that classifies the delivered payload
using the real `bin/fm-operational-input.sh` rather than pinning delivery options
— the exact blind spot upstream named when fixing the Pi side.

omp mechanics preserved: the wrap sits in `deliverNote`, not `mergeIntoMain`,
because the port holds notes until main is fully settled; omp has no
`agent_settled` event, so the settled test stays `willContinue` plus
`ctx.isIdle()` plus `ctx.hasPendingMessages()`, markers stay omp-rooted, the arm
cycle stays process-scoped, and all four settled-boundary cases still pass.

### Round 1 tests

`bin/fm-test-run.sh --changed --base d63b0e2` on the cascaded tip: **177 scripts,
12 failed, 24 gate-skipped**, 76 minutes. Every failure was re-run at a baseline —
upstream's tip for scripts that exist there, and the pre-cascade stack tip
`4076042` for the one that exists only in our stack, since upstream cannot
baseline our own tests.

**Introduced — all three fixed, each on its own layer:**

| script | cause | fix |
|---|---|---|
| `fm-pi-branch-extension` | #3024 import vs. Calm retirement | module retained; now exits 0 with the baseline's gate-skip shape |
| `fm-pr-merge` | #3104's outcome cases build a home and no project clone, and this fork's default landing is a local fast-forward, which needs one | each case states its landing with an explicit forge method |
| `fm-pr-check-security` | same | same |

Both PR-forge scripts pass at `4076042` and failed after the cascade, which is
what identified them as introduced rather than pre-existing.

**Pre-existing — named, not fixed** (8 verified failing at `d63b0e2` with our
layers absent; 1 ours-only verified failing identically at `4076042`):
`fm-lint-workflows` and `fm-lint` (both `actionlint not found` on this host),
`fm-subagent-pretool-check`, `fm-spawn-pool-base-freshen`, `fm-watcher-lock`,
`fm-teardown-endpoint-safety`, `fm-tmux-agent-liveness`, `fm-afk-inject-e2e`, and
`fm-backend-herdr-session-per-project-e2e`.

The herdr script also printed a `WORKTREE TANGLE` banner, because the working
copy sat on a named stack branch rather than detached. That banner is noise: the
failure reproduces with HEAD detached and at the pre-cascade tip.

Deliberately not run in either round: the opt-in live lanes (real herdr,
credentialed e2e, installed Pi npm package) gate-skip on this host and are
recorded as skips, never as passes.

## Out of scope, and one consequence

PR 25 untouched and still not a stack member. The two off-convention branch names
unchanged. PRs 30 and 32 not rebased, force-pushed or retargeted.
`gh stack sync --prune` never run.

One consequence, reported rather than acted on: **PR 32's base is
`fm/23-pi-branch-fixture-parity`, a stack member**, not `main`. That base was
rewritten by both rounds, so PR 32's diff and mergeability change even though the
PR itself was left alone; it is already showing as conflicting.

All 26 PR bases were re-read from the forge after each publish and still match
the stack order. gh-stack needed no repointing, because the branch names are
stable and only their commits moved.
