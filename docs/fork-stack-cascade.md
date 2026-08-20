# Cascading the fork's PR stack onto upstream

This fork carries its work as one long chain of stacked pull requests over a `main` that is a pure mirror of the upstream hard-fork source.
Upstream moves most days, so the chain is rebased onto it repeatedly; this file owns that procedure, the hazards that have previously cost commits here, and the decisions a cascade is not free to revisit.
It documents fork maintenance only. Nothing here describes firstmate's runtime behaviour.

## Order of operations

The first step is load-bearing. `gh stack rebase` rebases onto `origin/main`, so publishing the mirror before touching the stack is what stops the whole chain replaying onto a stale base.

1. Fetch upstream, fast-forward local `main` to it, and push `origin main` **before** touching any stack branch.
2. Record every layer's current SHA. Those SHAs are the `--force-with-lease` values in step 5 and they are unrecoverable once the rebase starts. Keep them outside the repository.
3. `gh stack checkout <n>` re-imports the stack's true membership and order from GitHub, which is authoritative; the local `.git/gh-stack` file can be stale or truncated and is not.
4. `gh stack rebase --remote origin`, bottom to top. Resolve each conflict and continue through `gh stack rebase --continue`, never by hand-rebasing a tracked branch out from under it.
5. Verify the topology with plain-git ancestry over every parent-child edge, then publish with plain `git push --atomic`, one lease per branch pinned to its step-2 SHA.

Confirm the result by content, not identity: the cascade rewrites every SHA. `git range-diff <old-base>..<old-tip> main..<new-tip>` pairs the commits one to one, and `git cherry` distinguishes an unchanged patch from one the replay altered.

## Hazards

Each of these has caused real damage in this repository.

- **Never `gh stack push`.** It refreshes its lease before comparing, so it can overwrite a third party's update. Publish with plain git only.
- **Never `gh stack sync --prune`, and never automate any prune.** Stored merged flags can force-delete branches, and a partially repaired flag makes a successful-looking cascade silently drop commits.
- **Never `gh stack merge`, especially non-interactively.** It can merge the whole stack unprompted.
- **`git rebase --update-refs` silently skips refs checked out in another worktree.** Enumerate `git worktree list` first, confirm no stack branch is checked out anywhere, and verify every ancestry edge afterwards regardless.
- **`git rerere` replays a resolution recorded for the same conflict text, including one recorded under a decision that has since been overruled.** A rerere-resolved path arrives already resolved and merely unstaged, so it is easy to stage without reading. Inspect it against both sides before accepting it.
- Pin API and push identity on every `gh stack` invocation; its stored repository field is not enforcement, and PR numbers collide across repositories.

## Settled decisions a cascade must not re-litigate

**Watcher wedge semantics (2026-08-20).** Upstream `b57c4d6` and this fork's layer 11 independently fixed the same defect - a watcher escalating a healthy but quiet worker as a possible wedge - on disjoint paths. Upstream handles the busy pane past the completed-turn bound; the fork handles the idle stale paths and extends `crew_absorb_class` in `bin/fm-classify-lib.sh`, which upstream has no equivalent for. **Both are kept**: neither subsumes the other, and each side's tests fail under the other's implementation.

Where the two orderings differed - the idle-pane live gate - **upstream's ordering stands**. The first stale of a declared pause whose agent is live or ambiguously read surfaces one bare wake, then the pause cadence takes over; a confidently dead agent behind the same declaration is absorbed with no bare wake at all. `surface_nonterminal_stale` therefore keeps upstream's queue-then-record shape, and this fork's tests were adjusted to that behaviour rather than the reverse.

## Recurring mechanical notes

- Any new upstream fixture that backdates a file with a `uname`-keyed `date -r` or `stat` form needs the one-line port to `fm_test_set_mtime` / `fm_test_file_mtime`. Upstream's inference breaks its own suites wherever GNU coreutils precede `/bin` on the `PATH`, which is what the dialect-probe layers exist to fix.
- `bin/fm-lint.sh` needs a pinned `actionlint` on the `PATH`; `bin/fm-install-actionlint.sh <dir>` fetches the verified build. Without it the lint gate and two suites exit 127 for a reason unrelated to the change under test.
- After a cascade, other checkouts still hold stale stack metadata. `gh stack checkout <n>` in each one re-imports the published truth.
