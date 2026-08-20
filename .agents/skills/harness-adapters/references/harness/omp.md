# omp (oh-my-pi)

Verified for crewmate, scout, and primary work on 2026-08-18 with omp 17.3.5 on tmux, unless a fact gives another version.
oh-my-pi is a Pi fork with its own identity, config root, lifecycle events, composer, busy predicate, and primary supervision.
Nothing from the Pi reference transfers; every fact below was measured on omp itself.
`../../../bin/fm-spawn.sh` still refuses `--secondmate` on omp because that launch wiring is unbuilt, not because the supervision protocol is missing.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `omp` from `PATH`. The pane's `#{pane_current_command}` is the exact name `omp`, which is also what the liveness and identity probes match; a `*omp*` glob is deliberately never used, so `composer` and `omptest` stay `other`. |
| Launch | A positional prompt, the Pi and Grok shape, so the brief rides the launch command. |
| Busy state | The Firstmate-owned per-task extension's `agent_start` (busy) and `agent_end` **without** `willContinue` (idle), source `omp-ext`. |
| Exit command | `/exit`; one Enter submits it even though a slash popup is open. |
| Interrupt | Single Escape. The run closes with `[Command cancelled]` and the composer returns EMPTY, so no clear key is needed (unlike muse). `../../../bin/fm-control-lib.sh` claims no cancellation acknowledgement. |
| Skill invocation | `/<skill>`, the Claude and Grok form. Typing `/` opens a slash-autocomplete popup, but one Enter submitted `/exit` and exited the application, so no popup settle is scoped to omp; the shared submit retry remains the safety net if a future argument-taking command behaves like Grok's. |
| Model flag | `--model <provider/id>`, pair-native, so the canonical pair passes verbatim; `--help` documents the combined shape (`"openai/gpt-5.2"`) and calls its separate `--provider` flag legacy. Fuzzy matching applies (`--model haiku` resolved to `claude-haiku-4-5`). An unknown model REFUSES the launch with `Model "..." not found`. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`. `--help` documents `off\|minimal\|low\|medium\|high\|xhigh\|max\|auto`, so the whole shared vocabulary maps across. An unknown LEVEL is accepted silently and falls back to the model default rather than refusing, so never pass a value outside the allowlist. The applied level is additionally clamped to what the selected model advertises in `omp models`. |
| Model discovery | Run `omp models` (or `omp models find <substring>`, `omp models --json`), which lists every available provider/model and each one's supported thinking levels. `omp usage` reports the authenticated accounts. |
| Autonomy | `--auto-approve`. Without it every tool call is gated; with it a bash tool call ran unattended. `--approval-mode yolo` is the equivalent knob. |
| Trust dialog | None observed on a never-seen worktree path, and none is needed for the busy extension, which loads through an explicit `-e` path rather than a project root. A PRIMARY needs none either: omp auto-discovers `.omp/extensions/` without approving anything. |
| Primary supervision | Its own tracked `.omp/extensions/` pair. Turn end BLOCKS through `session_stop`; the arm cycle is owned per omp PROCESS. See "Primary supervision" below. `--secondmate` is still refused. |
| Environment marker | `OMPCODE=1`, and omp ALSO exports `CLAUDECODE=1` of its own accord. Detection tests `OMPCODE` first for exactly that reason. |
| Composer | A two-row box with NO interior content row: a titled top border and an input row that IS the bottom border (`╰─ typed text ─╯`), with the terminal cursor on that bottom row. |
| Resume | `omp --continue` for the previous session, or `omp --resume <id-prefix>`. |

## The busy predicate is not Pi's

omp emits no `agent_settled`, and `ctx.isIdle()` is still false AT `agent_end` because the settle completes after the event.
Pi's predicate (`agent_settled` confirmed by `ctx.isIdle()`) can therefore never report idle here.
omp's own terminal signal is `agent_end` with `willContinue` unset; omp sets that flag true at every site that has already scheduled a continuation, including auto-retry, compaction, and a `session_stop` hook that blocked.
A single Escape mid-turn takes the same terminal path, so this source covers manual interruption, which Claude's `Stop` hook does not.

## The composer shape needs identity

Two adjacent border rows are weak evidence on their own, so `../../../bin/fm-composer-lib.sh` gates the inline-bottom shape on the tmux foreground-process identity probe naming `omp`, the same conjunction Pi's separated shape uses.
Unlike Pi it ignores the identity's STATUS, because a real bordered container makes the content read meaningful without it.
Backends with no identity probe (zellij, cmux, orca) therefore read an omp pane `unknown` rather than borrowing tmux's proof.
Long input grows interior rows and turns the composer into an ordinary box whose titled top border reads as geometry ambiguity, so a wrapped omp composer reads `pending-unproven`; that is a safe degradation, because injection defers on anything that is not `empty` and the submit retry treats it exactly like `pending`.
The delivery busy token is the bracketed `esc` from omp's `interruptHint()` in all three of its shipped symbol sets (`⟨esc⟩`, `⟦esc⟧`, `[esc]`); the spinner VERB beside it is model-authored and changes mid-turn, so it is never matched.

## Pi extensions load on omp and are silently inert

omp's loader rewrites `@earendil-works/*` specifiers onto its own bundled copies, so firstmate's `.pi/extensions/fm-primary-turnend-guard.ts` imports and runs on omp with no error.
It is a trap rather than a capability: `pi.on("agent_settled", ...)` registers silently and never fires, so the guard is inert, while the guard's own `state/.pi-turnend-extension-loaded` marker IS written.
That is a disarmed primary reporting itself healthy.
Never reuse a Pi extension, hook path, or predicate on omp without measuring it on omp.

Discovery keeps the two apart on its own: omp auto-discovers only top-level `.omp/extensions/*.ts` and never `.pi/`, Pi never discovers `.omp/`, and omp loads none of `.claude/settings.json`'s hooks despite exporting `CLAUDECODE=1`.
Reaching the trap takes an explicit `-e`.
The markers, the ownership proof (`fm_primary_extension_pairs` in `../../../bin/fm-wake-lib.sh`), and the session-start diagnostic are all keyed per harness for the same reason, so Pi evidence can never answer for an omp primary.

## Primary supervision

`../../../docs/supervision-protocols/omp.md` is the emitted protocol. Two mechanisms, both omp's own:

- Turn end is a BLOCKING stop. omp's `session_stop` is Claude-shaped: returning `{decision: "block", reason}` refuses the stop and puts the reason in front of the model, and omp awaits an async handler, so `../../../bin/fm-turnend-guard.sh` can be spawned from inside one. omp marks only the stop that FOLLOWS a block, so forwarding its own `stop_hook_active` reuses the guard's default-mode loop guard and bounds this to one forced continuation per turn. `--claude` mode is deliberately not used - it exists for Claude's habit of marking every stop after any continuation. Note omp does not render the reason as pane text; the model's reaction is the visible signal.
- The watcher arm cycle is owned per omp PROCESS, not per session. omp emits no lifecycle event for a same-process replacement: `/new` changes the session id while handlers keep firing. Pi's per-session generation model has nothing to bind to, and the process lifetime is the right one anyway, because the arm child supervises the fleet home rather than a conversation. So an omp primary makes ONE `fm_watch_arm_omp` call per process, and `/new` neither retires the cycle nor needs a new call.

Wakes use `pi.sendUserMessage(content)` with NO options object.
`deliverAs: "followUp"` only QUEUES on omp while the session is idle, the opposite of Pi's requirement, so copying Pi's call would have produced a wake that never fires.
`fm_supervision_model` routes omp to the `extension` model beside Pi.
The standing regressions are `../../../tests/fm-omp-primary-extensions.test.sh` and, opt-in, `../../../tests/fm-omp-primary-live-e2e.test.sh`; the omp pair is strict-typechecked by `../../../tests/fm-pi-primary-types.test.sh` despite that file's Pi-shaped name.

`../../../docs/verification/runtime-backends.md` "omp (oh-my-pi)" owns the dated commands and output.
