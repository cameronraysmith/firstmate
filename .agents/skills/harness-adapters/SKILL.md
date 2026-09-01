---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, verifying a new harness adapter, or running external commands from an omp eval cell.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, muse, omp, and atomic.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, tell the captain under `../../../AGENTS.md` section 9 that the requested worker runtime is not verified, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime for future work.
Do not pause current work for that choice.

On `unknown`, ask the captain instead of guessing.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
Muse is verified only for crewmate and scout work, never a secondmate or primary.

## Detection

`../../../bin/fm-harness.sh` prints firstmate's own harness from verified environment markers, then process ancestry.
omp (oh-my-pi) sets `OMPCODE=1` and keeps none of Pi's own markers, so `../../../bin/fm-harness.sh` reports its own `omp` identity ahead of any retained `CLAUDECODE`, and the session-lock ancestry table anchors the exact process name `omp`.
`CLAUDECODE=1` on an omp tool process is omp's OWN compatibility export, not an inherited value, verified from a scrubbed environment on omp 17.3.5, which is why that ordering is load-bearing rather than incidental.
omp is deliberately not aliased to the pi family despite being a Pi fork: its config root is `~/.omp/agent`, and its lifecycle events, composer shape, and busy predicate all differ from Pi's.
omp runs a verified PRIMARY through its own tracked extension pair and is a verified secondmate harness.
Its secondmate launch passes no `-e` path: the pane's working directory is the secondmate home, and omp auto-discovers that home's tracked `.omp/extensions/*.ts` without a trust approval, so naming those files again would give omp a second route to modules discovery has already loaded.
omp uses its OWN tracked pair, `.omp/extensions/fm-primary-turnend-guard.ts` plus `.omp/extensions/fm-primary-omp-watch.ts`, auto-discovered from `.omp/extensions/` with no trust step; its guard BLOCKS the turn through omp's `session_stop` instead of forcing a follow-up, and its arm cycle is owned per omp PROCESS rather than per session.
Never point an omp primary at the Pi pair: they load on omp and never fire (see `references/harness/omp.md`).
atomic (a Pi fork) derives its marker from its own app name and sets `ATOMIC_CODING_AGENT=true` alongside `AI_AGENT=atomic`, and it deliberately never writes `PI_CODING_AGENT`, so `../../../bin/fm-harness.sh` reports `atomic` ahead of any retained `CLAUDECODE` or leaked Pi marker, and the session-lock ancestry table anchors the exact process name `atomic`, which it matches through `argv[0]` because the nix launcher's `comm` is `node`.
The `AI_AGENT` conjunct is what keeps the reverse direction correct: the `*_CODING_AGENT` markers are sticky under nesting, so a claude or pi worker launched under atomic inherits `ATOMIC_CODING_AGENT` while `AI_AGENT` still names its own harness.
atomic is deliberately not aliased to the pi family either: its config root is `~/.atomic/agent`, it renamed Pi's `grep` tool to `search`, and it scans `.pi/` in addition to its own tree, which is a hazard rather than an inheritance (see `references/harness/atomic.md`).
atomic is CREWMATE/SCOUT ONLY: its extension API is Pi's and the capability is there, but no firstmate primary protocol is built on it, so `../../../bin/fm-spawn.sh` refuses `--secondmate` on atomic rather than launching supervision that cannot be armed.
Only `FM_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
`../../../bin/fm-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/fm-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means firstmate's own harness.
`../../../bin/fm-harness.sh secondmate` resolves `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own harness.
`../../../bin/fm-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/fm-harness.sh`.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
Kimi establishes its unsupported primary boundary in its selected harness reference; Muse follows Non-negotiable safety above.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "muse": "references/harness/muse.md",
    "omp": "references/harness/omp.md",
    "atomic": "references/harness/atomic.md"
  }
}
```
