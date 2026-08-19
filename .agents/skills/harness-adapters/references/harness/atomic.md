# atomic

Verified for crewmate and scout work on 2026-08-19 with atomic 0.9.13 on tmux, unless a fact gives another version.

atomic is a Pi fork, and unlike omp its extension API really is Pi's: the same events fire and the Pi busy predicate works unchanged.
That similarity is the hazard, because atomic scans `.pi/` as well as `.atomic/`, so the launch has to fence Pi's tree off deliberately.
It runs crewmate and scout work only; `../../../bin/fm-spawn.sh` refuses `--secondmate` on atomic because that launch wiring is unbuilt, and no `../../../docs/supervision-protocols/` protocol exists for it yet, so a firstmate primary detected as atomic falls back to the `unknown` protocol.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `atomic` from `PATH`, resolved to an absolute path so the model preflight probes exactly what the pane launches; a missing install refuses the spawn. The nix launcher `exec`s `node`, so the LIVE process name is `node` with `argv[0]` rewritten to `atomic` - see "The composer needs no process identity, and could not have one from `comm`" below. |
| Launch | A positional prompt, the Pi/Grok shape, so the brief rides the launch command. |
| Models | The canonical `provider/id` pair is SPLIT into `--provider <provider> --model <id>`, and the provider prefix is load-bearing rather than decorative: `--model provider/id` does NOT pin a provider, and a bare id resolves through atomic's own order to whichever provider sorts first. `../../../bin/fm-spawn.sh` refuses a model with no provider prefix and preflights the pair against `atomic --list-models`. |
| Busy state | The firstmate-owned per-task extension's `agent_start` (busy) and `agent_settled` confirmed by `ctx.isIdle()` (idle), source `atomic-ext` - Pi's predicate, measured on atomic rather than assumed. |
| Exit command | `/exit`; one Enter submits it even though a 228-entry slash popup is open. The pane survives and prints `To resume this session: atomic --session <headerId>`. |
| Interrupt | Single Escape, followed by `C-u`: atomic restores every message QUEUED during the turn into the composer as real text, which is exactly what a firstmate steer sent to a busy worker becomes. Never send a second Escape - on an idle empty composer atomic's default double-Escape action opens the session-tree overlay. `../../../bin/fm-control-lib.sh` DOES claim a cancellation here, from the transcript record below. |
| Skill invocation | No verified slash form. A slash popup exists (228 entries), but `/no-mis` matched nothing, so firstmate's skills are not commands there; use natural language naming the skill, as with pi. |
| Autonomy | No flag, and none exists to look for: atomic executes tools with NO approval gate at all. |
| Trust dialog | A BLOCKING five-option `Trust project folder?` dialog on any project folder atomic has not been trusted with, whose first and preselected option is a PERSISTENT trust. `-na` suppresses it entirely, which is what firstmate relies on - accepting it with Enter would write a disposable task worktree into atomic's persistent `~/.atomic/agent/trust.json`. |
| Primary supervision | None built. Crewmate and scout only; `--secondmate` refused, on omp's unbuilt-wiring reason rather than muse's incapability. |
| Environment marker | `ATOMIC_CODING_AGENT=true` plus `AI_AGENT=atomic`, and never `PI_CODING_AGENT`. See "Detection" above; the `AI_AGENT` conjunct is what keeps a nested worker from being misread. |
| Composer | Pi's separated region - an input row between two full-width rules - but atomic draws claude's `❯` agent glyph on that row, so the shared classifier proves it through the bare-glyph rule and needs NO identity gate, unlike pi and omp. |
| Model flag | `--provider <provider> --model <id>`, split from the canonical `provider/id` pair. Only `--provider` hard-pins a provider, and `--provider <known> --model <unmatched>` merely warns, launches, and then dies on a provider 404, so `../../../bin/fm-spawn.sh` preflights the pair against `atomic --list-models` and refuses before endpoint creation. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`. Verified 2026-08-19 on atomic 0.9.13; `--thinking` accepts `off\|minimal\|low\|medium\|high\|xhigh\|max`, so the shared vocabulary maps across. Two hazards, both silent: an out-of-range LEVEL is accepted with a warning and falls back to the settings default with exit 0, and the accepted level is then CLAMPED to the selected model's supported set in either direction (a requested `medium` ran at `high` on `kimi-coding/k3`). |
| Model discovery | Run `atomic --list-models [search]`, which prints `<provider> <model> <context> <max-out> <thinking> <images>` rows. It lists ONLY providers that currently hold a usable credential, so an absent pair can mean either an unknown model or an unauthenticated provider; it needs no network. |
| Resume | `atomic --continue`, or `atomic --session <exact .jsonl path>`. NOT `--session-id`: the interactive host forwards `--session <path>` to its engine child, which mints a fresh header id, so a later launch with the same `--session-id` finds nothing and starts a second session. |

## -na is a safety flag, not a permissiveness flag

atomic scans BOTH `.atomic/` and `.pi/` for project-local extensions, at the project root and in the home directory, by deliberate legacy-compatibility design.
A crewmate whose worktree carries a `.pi/extensions` tree - firstmate's own repo most sharply - would therefore load the operator's primary supervision extensions into a worker and arm a second supervisor.
`-na`/`--no-approve` makes atomic ignore project-local files for the run, which closes that and the trust dialog in one flag: verified live with a planted project-local `.pi/extensions` file that loaded under `-a` and was ignored under `-na`.
`-ne`/`--no-extensions` would close it too, but it is the blunt instrument - it disables discovery entirely, including the operator's own extensions, and firstmate has no standing to disable those for a crewmate.
The busy extension is unaffected either way, because an EXPLICIT `-e` path outside the project is not a project-local file (verified: `-na` with an `-e` path in `state/` loaded it).

## The busy predicate IS Pi's, and that was measured

A real turn emitted `agent_start`, then `agent_end`, then `agent_settled` with `ctx.isIdle()` returning true, so Pi's predicate reports idle exactly where it should.
`agent_end` is deliberately NOT the terminal signal: it fires before the settle completes.
This is the opposite of omp, whose settle completes after its terminal event and leaves `isIdle()` false, and the difference is the reason no adapter here may borrow another Pi fork's predicate without measuring it.

## The interrupt acknowledgement, and its one blind spot

atomic appends an assistant record carrying `"stopReason":"aborted"` (with `"errorMessage":"Request aborted"`) to its own JSON-lines session transcript when a turn is cancelled.
`../../../bin/fm-spawn.sh` pins the session id at launch, so the transcript filename is deterministic, and records it with the sessions root in `state/<id>.atomic-session`; `../../../bin/fm-control-lib.sh` owns the read.
The claim is scoped by BYTE OFFSET rather than by content: the control plane captures the transcript's length before it delivers Escape and accepts only a record appended after that point, so a prior aborted turn in the same transcript can never be mistaken for this one.
The blind spot is the first turn: atomic does not create the transcript until the first assistant message exists, so an interrupt before that has no file to read and the claim is reported `unconfirmed` rather than guessed.

## The composer needs no process identity, and could not have one from `comm`

On the nix-installed build `ps -o comm=` reports `node`, not `atomic`: the launcher `exec`s node, and atomic's own `process.title` rewrite lands in `argv[0]`, which is what `ps -o args=` shows (measured live on atomic 0.9.13; `#{pane_current_command}` is no better).
That costs identity DETECTION nothing, because `../../../bin/fm-session-lock-lib.sh`'s ancestry walk reads both fields and matches the anchored `^atomic$` through `argv[0]`.
But `fm_tmux_composer_identity` reads `comm` only, so atomic gets NO arm there - and it needs none, because its composer carries the `❯` glyph, which is positive container proof on its own.
Do not add a `comm`-based identity arm for atomic on the strength of the process-title rewrite: it would never match while reading like a working signal.
The live guard asserts the pairing directly (identity probe returns nothing, verdict is still `empty`), so a future atomic that drops the glyph for pi's glyph-less region fails loudly instead of degrading to `unknown`.

## Two captain decisions this adapter deliberately does not settle

The effort clamp is silent and bidirectional: a requested `medium` runs at `high` on `kimi-coding/k3`.
Firstmate passes the request and records it; whether the ladder should be gated against each model's advertised levels is `atomic-effort-clamp`.
And atomic loads the OPERATOR's `~/.pi/agent/AGENTS.md` resources into every session, which `-na` does not touch because it is a HOME-level resource rather than a project-local file.
That is muse's foreign-personal-context shape without muse's kill switch, and it is not resolved here.

`../../../docs/verification/runtime-backends.md` "atomic" owns the dated commands and output.
The standing regressions are `../../../tests/fm-atomic-harness.test.sh` (identity) and `../../../tests/fm-atomic-adapter.test.sh` (this layer), plus the opt-in live guards `../../../tests/fm-atomic-adapter-live-e2e.test.sh` and `../../../tests/fm-composer-matrix-live-e2e.test.sh`.
