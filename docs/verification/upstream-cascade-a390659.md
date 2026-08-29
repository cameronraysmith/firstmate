# Upstream cascade onto kunchenguid/main a390659

Run record for the cascade-rebase of stack 18 (26 layers, `fm/01` … `fm/24` plus
`fm/fm-atomic-identity` and `fm/fm-atomic-pi-adapt`) from base `10b93b2` onto
upstream `a390659`, run 2026-08-29.

This is a measured record of one job, not the procedure.
`docs/fork-stack-cascade.md` owns the procedure.
This file exists so the next cascade can tell a deliberate resolution from a merge accident.

## Final result

| | |
|---|---|
| upstream tip | `a390659` — `feat(bin): publish per-home summary ledgers (#3222)` |
| original base | `10b93b2` |
| original stack tip | `d921c09` |
| cascade tip | `074d00a` |
| final stack tip | `18ea53f` — one commit added on `fm/24` after the cascade (see "The omp parity port") |
| layers | 26, published in one `git push --atomic` with 26 leases |
| upstream commits integrated | 7 |

`kunchenguid/main` was re-resolved from the remote at the start of the run rather
than taken from the dispatch, and it had not advanced.
`main` was fast-forwarded `10b93b2` → `a390659` and pushed to `origin` before any
stack branch was touched, because `gh stack rebase` rebases onto `origin/main`.

### Recovery point

On `origin` and not moved since:

| ref | pinned at | what it recovers |
|---|---|---|
| `backup/stack18-precascade-20260829T013010Z` + tag of the same name | `d921c09` | the state before this cascade |

The local backup *branch* was deleted before rebasing on purpose.
`git rebase --update-refs` force-updates every branch pointing into the replayed
range, and a backup branch at the stack tip points into it, so leaving it in
place is how a backup silently follows the thing it was meant to preserve.
The annotated tag is not touched by `--update-refs`, and `origin` holds both.

## Topology as measured, not asserted

| check | result |
|---|---|
| ancestry edges across all 26 layers | 26 of 26 hold |
| merge commits in `main..fm/24` | 0 |
| commits in `main..fm/24` | 67 cascaded (68 with the omp commit added afterwards) |
| upstream tip is an ancestor of the stack tip | yes |
| `git range-diff 10b93b2..d921c09 a390659..074d00a` | 58 identical, 8 modified, 0 lost |

One pair is reported by `range-diff` as unpaired in both directions:
`b5a434b2` → `d6813127`, `test: state the landing shape in upstream's
durable-outcome merge cases`, at position 38 on both sides.
It is a correspondence, not a loss.
Most of that commit's content had to be applied while resolving the conflict in
commit 36 of the same layer, because the layer's own test file would not pass at
commit 36 without it, so what remained for commit 38 was its rationale comment
and one invocation the earlier resolution had missed.
The two versions fell below `range-diff`'s similarity threshold for pairing.
The layer's net content is what matters and is correct; its three commits all
survive and are all in one pull request.

## The seven upstream commits

| commit | subject |
|---|---|
| `a390659` | `feat(bin): publish per-home summary ledgers (#3222)` |
| `4207214` | `fix(bin): accelerate and bound changed test runs (#3250)` |
| `1fd7ea2` | `feat(bin): add concurrent bounded remote transport lanes (#3210)` |
| `c651b59` | `fix(pi): surface requested outcomes without replaying fleet events (#3211)` |
| `bca584a` | `fix(bin): prioritize active pipeline-owned crew runs (#3194)` |
| `4f89f5b` | `fix(pi): prevent duplicate captain outcome reports (#3184)` |
| `7ee0c19` | `fix(bin): verify the real GitHub merge outcome instead of reporting an unproved merge (#3064)` |

They touch 52 files.
25 of those are files this stack also modifies: 14 non-test files and 11 test
files.

## Collisions and how each was resolved

### `7ee0c19` against `fm/14-pr-local-ff-landing`

Both change `bin/fm-pr-merge.sh`, the helper that lands every task pull request.

Upstream's verification is entirely about proving that a *forge-side* merge
landed: it wraps `gh-axi pr merge`, reads GitHub's state back through gh's
queue-aware GraphQL view with a gh-axi fallback, and refuses every outcome it
cannot prove.
It does not assume a forge-side merge is the only landing shape; it only verifies
the shape it wraps.

This fork's layer makes a local fast-forward the default and keeps the forge-side
merge behind an explicit `--squash`, `--merge`, `--rebase`, or `--method`.
The captain settled that default on 2026-08-24 and it is not re-litigated here.

The two compose, so both survive: upstream's verification now sits inside the
forge-side branch, and the local fast-forward keeps its own proof, which is
stronger in kind — it pushes the validated head onto the base and re-reads the
base to assert containment, observing the landing directly rather than asking the
forge what it believes.
Upstream's `record_pr_metadata` refactor and its call site before either landing
were adopted whole, because this layer already recorded before dispatching and
upstream's version reports failure better.

One upstream line was dropped: the implicit `merge_args=(--squash)` default.
In this composition the GitHub forge-side arm is reached only when the caller has
already named a method, so the default is unreachable, and it contradicts this
layer's contract that the script never chooses a landing shape for the caller.

Upstream's new tests assume its own default, so twenty-eight invocations across
`tests/fm-pr-merge.test.sh` and `tests/fm-pr-check-security.test.sh` now state
their landing explicitly.
That is not a weakening: the local fast-forward needs a real project clone on
disk and these outcome fixtures deliberately build only a home, so a case that
means to exercise the forge path has to say so.
The default landing has its own fourteen cases, which do build that clone.

Re-run in place immediately after resolving: `tests/fm-pr-merge.test.sh` 75 of
75, `tests/fm-pr-check-security.test.sh` 41 of 41.

### `4207214` against the eight commits in `bin/fm-test-run.sh`

Both consequences of this collision are real.

It changes the runner this cascade's own verification depends on, so the
measurement below was taken with the post-cascade runner, stated here rather than
switched silently.

It also reduces the cost of every future cascade, which is why it was worth
taking rather than minimising.
Its changed-file map previously resolved one direct test reference to that test's
whole family, so a one-line change to `bin/fm-push-transition-lib.sh` selected all
twelve real-Herdr-gated scripts including a 341s end-to-end test.
A cascade diff touches many `bin/` scripts, so that over-selection is exactly the
cost that hurts here.
It also adds longest-hint-first concurrent scheduling for `--changed`,
`--per-script-timeout-secs` (900s on the automatic `--changed` path), and
`--max-wall-ms`.

### `c651b59` and `4f89f5b` against `fm/24-omp-branch-supervision`

No textual conflict, and nothing in this fork's implementation became redundant.
Both upstream commits change `.pi/extensions/fm-branch-supervision.ts`, which
upstream owns and this fork does not modify.
`.omp/extensions/fm-branch-supervision.ts` is this fork's port of that extension
for a different primary harness, not a duplicate of the Pi file, and upstream
never touches it.

Worth recording for the next cascade: the two commits are sequential edits to one
constant, and the second **replaces** the first.
`4f89f5b` made the relay order conditional after one merge reached the captain
twice in sixteen seconds; `c651b59` then removed that conditional wording,
because "if you already reported this, do not report it again" turned the
opposite way and lost outcomes instead.
The settled form separates event ownership from the captain-facing response.
Anyone reading only `4f89f5b` will reintroduce the wording it added.

`fm/23-pi-branch-fixture-parity` is untouched by either commit's code; it collides
with `4207214` instead, through `bin/fm-test-run.sh`.

### `1fd7ea2` against `fm/01-stat-dialect-probe`

This is the founding-defect shape the fork exists to guard, and it recurred
exactly as predicted.

Upstream's hunk adds `fm_remote_job_stage_owner_alive` immediately after
`fm_remote_job_path_mtime` in `bin/fm-remote-job-lib.sh`, carrying that helper's
`uname -s = Darwin` line along as untouched context.
`fm/01` replaces precisely that line with a `fm_stat_is_gnu` probe, because the
inference is wrong on any host where GNU coreutils precede `/bin` on the `PATH`.

Upstream is not reintroducing the inference deliberately here — it is building
beside it — but the hunks overlap on the one line the fork exists to remove.
Resolved in this fork's favour with upstream's structural addition kept: the
probe survives and the new function landed beside it.
`range-diff` confirms both in the replayed commit.

### Collisions the survey had not predicted

`a390659` inserts `fm-home-summary-refresh.sh --best-effort` calls at spawn and
teardown exit points that `fm/08`, `fm/09`, `fm/19`, `fm/20`, `fm/21`, and
`fm/22` also edit.
Semantically independent of every layer; positional only, and merged cleanly.
Upstream's new `tests/fm-home-summary-refresh.test.sh` passes 10 of 10 here.

`bca584a` rewords one line of `AGENTS.md` inside the section 7 Validate paragraph
that `fm/14` also edits, and a header comment in `bin/fm-teardown.sh`.
Both sides' wording survives.

`4207214` modifies `tests/fm-calm-pi-extension.test.sh`, which
`fm/fm-atomic-pi-adapt` deletes.
This is a delete-against-modify, and it is the first cascade in which that file
is live upstream rather than untouched.
Upstream's edit adds a bounded reap loop around the headless Chrome the script
spawns, because it was observed running 17+ minutes against a 464ms recorded hint
when Chrome retained `--headless=new` after `--dump-dom` returned and ignored
`TERM`.
The deletion stands, per the captain's 2026-08-24 decision, and supersedes that
per-test repair rather than discarding a protection: the same upstream commit's
durable fix is `--per-script-timeout-secs` at the runner level, which is kept and
converts a hang in *any* script.
The rationale is restated in the layer's own commit message, which is what that
decision requires on every cascade.

Two references to the deleted script are deliberately left verbatim.
`bin/fm-test-run.sh` names it inside the comment deriving the 900s constant from
measured runtimes, and `docs/fm-test-isolation-proof.md` names it in a recorded
measurement.
Both are upstream's measurement provenance rather than live references, and
editing a recorded measurement to remove a since-deleted script would falsify
what was measured.
Nothing depends on the file existing: upstream's own timeout test builds a
synthetic repository and creates the script itself, so the name there is only a
path string, and `tests/fm-test-run.test.sh` passes 25 of 25.

## The omp parity port

One commit was added on `fm/24` after the cascade, not as part of it:
`fix(omp): carry upstream's captain-outcome contract into the omp branch port`.

The omp port carried the pre-`4f89f5b` instruction wording verbatim — the exact
string both upstream commits were fixing — so the omp primary kept a defect its
Pi counterpart no longer has.
Ported: the settled `c651b59` instruction wording, its `verdict` rule that an
outcome answering an explicit captain request is captain-facing however routine it
reads, and head-and-tail mirror truncation with the newest captain request
mirrored uncapped.

Two parts were deliberately not ported, and the reasons belong in this record
because the next cascade will meet them again.

`c651b59`'s `before_agent_start` staging is a capability claim this repository has
not measured.
omp does emit that event — the observed order is in
`docs/verification/runtime-backends.md` — but whether its payload carries the
`prompt` field the staging reads is unverified, and the convention here is to
record such a fact after probing a real omp rather than assume it.
The turn_end mirror still finds the current captain request among the persisted
entries, so the uncapping works without it.

Its switch to the canonical `classifyFirstmateOperationalText` helper was tried
and reverted.
That helper spawns `bin/fm-operational-input.sh` per call and this predicate runs
once per mirrored message, so it buys single ownership of a two-form grammar at
the price of a subprocess in the mirror's hot path and a new fixture dependency;
the mirror-filtering test failed on exactly that.
The inline match decides the same two forms, and the comment now says why it
stays inline.

`tests/fm-omp-branch-extension.test.sh` passes 10 of 10, including the
mirror-filtering case that exercises both operational forms and the captain-note
delivery case, whose assertion was re-pointed from the retired wording to the two
invariants the settled contract states.

## Verification and the failure split

Selection: `bin/fm-test-run.sh --changed --base main` at the stack tip, 179
scripts, run on the post-cascade runner.
All 179 produced a result.
Nine failed.
None was introduced by this cascade.

| script | verdict | evidence |
|---|---|---|
| `fm-lint` | environmental | `actionlint` absent; 27 of 27 with the pinned 1.7.12 installed |
| `fm-lint-workflows` | environmental | same cause; 16 of 16 once installed |
| `fm-spawn-pool-base-freshen` | pre-existing | fails identically at upstream `a390659`; test file unchanged by this stack |
| `fm-tmux-agent-liveness` | pre-existing | fails identically at upstream `a390659`; test file unchanged by this stack |
| `fm-remote-transport-lanes` | pre-existing | fails at upstream `a390659` too, and gets *further* at the tip (4 assertions pass vs 0) |
| `fm-guard-stale-banner` | pre-existing | 5 pass / 1 fail identically at the pre-cascade tip `d921c09` |
| `fm-startup-network` | pre-existing | 15 pass / 1 fail identically at the pre-cascade tip `d921c09` |
| `fm-backend-herdr-session-per-project-e2e` | pre-existing | 5 pass / 1 fail identically at the pre-cascade tip `d921c09` |
| `fm-backend-herdr-presentation-e2e` | load-induced flake | passes 23 of 23 at the pre-cascade tip and 23 of 23 on a clean re-run at the tip |

**Introduced by the cascade: 0. Pre-existing, environmental, or flake: 9.**

One methodological note that cost a wrong verdict and should not cost another.
Upstream's base is the correct comparator only for assertions upstream authored.
Four of these seven test files are modified by this stack, so at the base the
comparison runs a *different* file.
`fm-startup-network` first read as introduced for exactly that reason: it passes
18 of 18 at the base, but the failing assertion is this fork's own, upstream's
file does not contain it, and `bin/fm-startup-network.sh` is byte-identical
between base and tip.
For a fork-authored assertion the comparator is the pre-cascade stack tip.

Every failure was also re-run serially, because the new runner schedules
`--changed` concurrently and upstream's own commit records that 3 of 18 scripts in
one family fail under concurrency on wall-clock assertions.
All seven reproduced serially, so none of them was a scheduling artifact; the
Herdr presentation flake was found by re-running, not by scheduling.

Also run: `bin/fm-lint.sh` clean with ShellCheck 0.11.0 and actionlint 1.7.12
across the changed shell surface and all three workflow files.

Not run: the credentialed live end-to-end lanes, which are opt-in and need
provider credentials.
