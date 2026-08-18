Mode: omp extension background wake with a blocking turn-end stop.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the omp primary auto-loaded both project extensions; omp discovers top-level `.omp/extensions/*.ts` with no trust approval, so if they are missing, restart omp with `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__`.
3. First cycle only: make the one required `fm_watch_arm_omp` call.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through omp's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live omp process, and owns every later successor launch.
6. One arm cycle belongs to the omp PROCESS, not to a conversation.
   omp emits no lifecycle event for a same-process session replacement, so `/new` neither retires the cycle nor needs a new `fm_watch_arm_omp` call; supervision keeps running and wakes keep arriving in the replacement session.
   The process-owner contract lives in `.omp/extensions/fm-primary-omp-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_omp` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_omp`, and restart omp with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_OMP_TURNEND_EXT__`).

A turn that would end blind is stopped rather than nagged.
omp's `session_stop` is a blocking hook, so the turn-end guard refuses the stop and returns the repair banner as the reason; the following stop carries omp's own `stop_hook_active` flag and is always allowed, which bounds this to one forced continuation per turn.

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked, project-local `.omp/extensions/*.ts` files that omp auto-discovers; `bin/fm-session-start.sh` reports when the running omp session has not loaded both required extensions.
Never substitute the Pi extensions: omp's loader accepts them and they are silently inert there.
