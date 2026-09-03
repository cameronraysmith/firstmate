# Upstream integration and 30-member stack cascade

Integrated 35 upstream commits into the fork and replayed published stack 40 onto the new base.
Every SHA below was re-resolved in this run rather than taken from the dispatch brief.

## Step results

| Step | Result |
|---|---|
| 1. Record members and SHAs | 30 members read from GitHub's own stack API (`PullRequest.stack`, size 30, trunk `main`), not from local metadata, which was stale at stack 18. Baseline in `baseline.tsv`; local, remote, and PR-head SHAs agreed for 29 of 30, and `fm/fm-remote-worker-bad-interpreter` had no local branch and was created from `origin/` at `03eb060d`. |
| 2. Backup branches | 30 `backup/cascade-<branch>` branches created at the recorded old tips and verified equal to them. No tag was created. |
| 3. Free the checked-out member | Already satisfied: no stack member was checked out in any worktree. The primary checkout was detached at `407c9d7a`, so `fm/fm-omp-eval-idle-timeout-clamp` was free. Non-stack refs `wip/fm08-fixture-fix-staged`, `review/fm08-adversarial`, and `fm/linearize-16-18` were left untouched and re-verified unmoved after the cascade. |
| 4. Mirror push | `origin/main` fast-forwarded `a56a78ac` -> `75b2de26`, exactly 35 commits, ancestry proven before pushing. Landed before the cascade. |
| 5. Cascade | All 30 members rebased onto `75b2de26` by membership, one sequential `git rebase --onto` per member. Final tip `32c5b38f`. Every segment kept its original commit count (79 commits total). |
| 6. Publish | One `git push --atomic` carrying 30 refspecs, each with `--force-with-lease` pinned to that branch's independently recorded old SHA. Dry run first, then the real push; no lease was refused. |

`--update-refs` was deliberately never used: the `backup/cascade-*` branches point at member tips inside the rebase range, and that flag would have force-updated them, destroying the backups.

## Proofs

- **Signatures.** 79/79 rebased commits report `%G?` = `G`. Pre-rebase was also 79/79 `G`, so nothing was stripped. `--no-gpg-sign` was never passed.
- **Identity.** Committer is `Cameron Smith <cameron.ray.smith@gmail.com>` on all 79. Author is Cameron on 78; one commit, `fix(omp): await the async SessionManager.open the branch reopens with`, was authored `Claude Opus 5 <noreply@anthropic.com>` **before** the cascade (`eb2befd4`) and still is after (`57ff06ce`). Preserved, not introduced; flagged because the brief expected uniform Cameron authorship.
- **range-diff.** 30/30 branches paired with **zero** unmatched commits in either direction. 60 pairs identical, 19 changed patches, 79 total, matching the 79 commits exactly. Detail in `range-diff-detail.txt`.
- **Ancestry.** `git merge-base --is-ancestor` proven per edge locally and again on the `origin/` refs after publication: `origin/main` -> pos1 -> ... -> pos30, all OK. `gh stack view` metadata and the forge `mergeable` flag were not consulted.
- **Tree equivalence.** The final tip's file set is identical to the original stack tip's, plus only the files upstream's 35 commits added. Nothing was dropped.

## Conflicts resolved, per layer

Resolved by asking which behaviour must survive, keeping ours, and retaining upstream's structural improvement.

| Layer | Conflict | Resolution |
|---|---|---|
| pos1 `fm/01-stat-dialect-probe` | `ci.yml` and the shard doc: ours raised the portable serial cap to 25 min sized against worst-case shard walls; upstream held 20 min but re-measured the lane upward (~63 min remainder, ~12.7 min shards, 5 shards). | Kept our 25-minute cap and upstream's newer measurements and 5-shard structure. Upstream's larger shards strengthen our worst-case rationale. YAML re-parsed; `workflow_dispatch`, `concurrency`, and the event-gated `cancel-in-progress` all survived. |
| pos1 | `tests/fm-pi-branch-extension.test.sh`: both sides added different libs to one sandbox staging list. | Union. Upstream's three libs plus our `fm-stat-lib.sh`, which `fm-wake-lib.sh` sources and without which the sandbox copy is dead at source time. |
| pos5 `fm/05-decision-key-visibility` | `bin/fm-brief.sh`: upstream added `TASK_SECTION`, ours added `DECISION_KEY_PROTOCOL`; base empty. | Union, both variable definitions retained. |
| pos10 `fm/11-declared-wait-stale-escalation` | `bin/fm-watch.sh`, two comment-only blocks describing the same merged behaviour. | Kept our pause-semantics wording ("a known wait it expects to clear on its own"), which is the paused-versus-blocked distinction this layer introduces, and upstream's `surface_nonterminal_stale` block, which additionally documents the read-throttle-before-queue invariant. Verified both descriptions against the merged `pause_state_class`. |
| pos10 | `docs/architecture.md`, `docs/configuration.md`: ours widened "declared external wait" to include a crew's own background work; upstream sharpened the cadence prose. | Combined: our widened definition with upstream's cadence description. |
| pos15 `fm/16-test-failure-detail` | `tests/fm-pi-watch-extension.test.sh`: ours converted a raw exit-code assertion to `expect_code`; upstream reworded the message. | Combined: the helper with upstream's wording. Verified against `expect_code`'s signature in `tests/lib.sh`. |
| pos17 `fm/18-startup-network-reap` | `tests/fm-startup-network.test.sh`: ours normalised `TMP_ROOT` slashes (the owner check compares it against a process argv); upstream added `DRAIN` and a re-worded coverage bullet. | Union of both, keeping the normalisation and upstream's bullet and `DRAIN`. |
| pos19 `fm/20-omp-adapter-verification` | `docs/verification/runtime-backends.md`: upstream rewrote the Pi refresh paragraph and added a streaming section; ours appended a whole `## omp (oh-my-pi)` section and left that paragraph untouched. | Union spliced from the merged file so upstream's other clean edits elsewhere in the file were preserved. Refresh paragraph appears exactly once, in upstream's newer form. |
| pos19 | `tests/fm-spawn-dispatch-profile.test.sh`: upstream renamed `brief.md` -> `launch-brief.md`; ours replaced a literal marker prefix with `$(fm_launch_marker_prefix)`. | Both, orthogonal. |
| pos19 | `docs/watcher-continuity.md`: upstream expanded the Pi contract; ours appended two omp sentences. | Union. |
| pos21 `fm/fm-atomic-pi-adapt` | `docs/calm-mode-feasibility.md`: ours deletes it with the Calm extension; upstream added one table row describing Calm-hiding for its new `fm_branch_processed` tool. | Deleted, in our favour. Upstream's substantive work from that commit merged cleanly elsewhere; the lost row described exactly the mechanism the retirement removes. |
| pos21 | `bin/fm-test-run.sh` weight hints: upstream re-measured the whole table and added entries; ours only removed the retired Calm entry. | Upstream's fresher table minus the Calm entry. |
| pos21 | `docs/verification/supervision.md`: ours dropped the Calm sentence; upstream updated the verification date and description. | Both: Calm sentence dropped, upstream's newer 2026-09-01 line kept. |
| pos25 `fm/24-omp-branch-supervision` | `docs/configuration.md`: ours extended the supervision branch to an omp primary; upstream refined the captain-outcome mechanism. | Combined in both blocks. |

One self-inflicted defect was caught and fixed: splicing `bin/fm-test-run.sh` by hand dropped its executable bit (100755 -> 100644). Restored with `git update-index --chmod=+x` and the layer commit amended; the amended commit re-signed `G` with identity intact.

## Tests

Selection: for each layer where a resolution changed real content, the tests covering the resolved file, run at that layer's own rebased tip. 288 assertions passed across 8 layers.

Deliberately excluded: the full per-layer test diffs, which are 61 distinct scripts and about 40 minutes serial across 12 checkouts. That is far wider than the resolutions and covers upstream code this task did not write; publication arms CI on all 30 PRs, and this stack's own pos1 commit is what makes CI run on every stack PR.

Three layers failed. Each was attributed by running the same test at the pre-cascade old tip:

1. **`tests/fm-documentation-audiences.test.sh`** at pos21 and pos25: dangling link `../calm-mode-feasibility.md#...`. Fails at the **old** tips too, and passes by the final tip because pos26 (`fix(docs): repair the dangling calm-mode-feasibility link the cascade created`) repairs it. Pre-existing intermediate state, not caused by this cascade.
2. **`tests/fm-watch-triage.test.sh`** at pos10: fails at the old tip too, with a different assertion, alongside `date: ...: No such file or directory` and `touch: invalid date format`. Host-dependent fixture failure, not a cascade regression.
3. **`tests/fm-test-run.test.sh`** at pos21: **passes at the old tip, fails at the new tip, and still fails at the final tip.** A real regression introduced by the integration, described below.

## Open item: upstream fixture names a script this stack deletes

`tests/fm-test-run.test.sh` fails with:

```
--jobs 4 refused: tests/fm-calm-pi-extension.test.sh is not in the proven-isolated set
(see bin/fm-test-isolation-proof.sh --list) and its family has no recorded concurrent
proof. Unproven stateful scripts stay serial.
```

Upstream commit `7dcf0721` ("perf: accelerate local validation with bounded concurrency") added a strict `--jobs 4` fixture that names `tests/fm-calm-pi-extension.test.sh`, which pos21 deletes with the Calm extension. The old base referenced that script only in two tolerant places, which is why pos21's old tip passed. Our retirement commit predates upstream's fixture and could not have known about it.

Surviving references at the final tip:

- `tests/fm-test-run.test.sh:392` `timeout_script=tests/fm-calm-pi-extension.test.sh`
- `tests/fm-test-run.test.sh:417` the matching `FM_TEST_END ... exit=124` assertion
- `tests/fm-test-run.test.sh:505` and `:516` the concurrency and proven-isolated selections

Picking a replacement fixture subject is a content decision inside another layer's diff: the timeout probe needs a deliberately slow script (Calm's was ~77s) and the concurrency case needs a specific family, so the substitute changes what those fixtures actually measure. That choice was left open rather than invented here.

## Files

- `sha-mapping.txt` - the complete old-SHA to new-SHA mapping for all 30 members. Every recorded pull-request head in this home is stale and must be re-armed from it.
- `baseline.tsv`, `members.tsv`, `newtips.tsv` - machine-readable baseline and results.
- `range-diff-detail.txt` - full per-branch range-diff output.
- `cascade.sh`, `record.sh`, `verify.sh`, `rangediff.sh`, `publish.sh`, `run-resolution-tests.sh`, `attribute-failures.sh`, `classify-changed.sh`, `test-selection.sh` - the exact steps, re-runnable.
