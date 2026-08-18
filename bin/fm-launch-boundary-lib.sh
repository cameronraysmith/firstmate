#!/usr/bin/env bash
# fm-launch-boundary-lib.sh - the ONE declared set of agent-session environment
# markers firstmate clears at every launch boundary, plus the `env -u` prefix
# built from it.
#
# It lives in its own sourceable file rather than inside bin/fm-spawn.sh so the
# set has exactly one copy: fm-spawn applies it, and the regressions that pin
# the canonical launch commands derive their expectation from it instead of
# repeating the list. A hand-copied list in five test files is how a set like
# this drifts.
#
# WHY THE SET EXISTS. Two independent things put these markers in a worker's
# environment. A primary EXPORTS its own: claude sets CLAUDECODE,
# CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_CHILD_SESSION, and CLAUDE_PID on every
# tool child, and omp sets CLAUDECODE=1 of its own accord even though it is not
# claude (verified 2026-08-17 on omp 17.3.5 from a scrubbed environment, which
# also settles the question omp's identity change left open: the marker is
# omp's own compatibility export, not an inherited value). Separately, a pane
# environment RETAINS whatever the long-lived session daemon was started with,
# and those markers survive there indefinitely.
#
# Leaking one is not cosmetic. A claude worker that starts with an inherited
# CLAUDE_CODE_CHILD_SESSION silently disables its own transcript persistence,
# and is only saved when the SAME marker is also present in the tmux GLOBAL
# environment, which claude probes as its ambient-marker escape hatch. A worker
# on a backend that sets no TMUX has no such probe at all, so the loss is
# unconditional there (verified 2026-08-17 on Claude Code 2.1.234; the pane
# warns "Transcript saving is off - inherited CLAUDE_CODE_CHILD_SESSION
# marker", and clearing the marker at this boundary is what makes it stop).
#
# WHAT IS AND IS NOT IN IT. The claude-family names come from claude's own
# declared session-scoped key list rather than from guesswork, restricted to
# the agent-identity and session-binding entries: that same list also carries
# SHELL, TMUX, TMPDIR, and friends, which are the pane's own environment and
# never firstmate's to clear. Operator CONFIGURATION is likewise untouched
# (CLAUDE_CONFIG_DIR, subagent model, feature toggles), because clearing a
# deliberate setting would be a different bug. TRACEPARENT is deliberately
# absent even though claude lists it: firstmate propagates a task-scoped
# carrier through this same launch under docs/trace-context.md, and unsetting
# it here would silently disable that.
#
# Re-sourcing is a cheap idempotent redefinition, so this file needs no include
# guard (matching bin/fm-composer-lib.sh and bin/fm-tmux-lib.sh).

fm_launch_foreign_markers() {
  cat <<'EOF'
CLAUDECODE
CLAUDE_CODE_ENTRYPOINT
CLAUDE_CODE_SESSION_ID
CLAUDE_CODE_CHILD_SESSION
CLAUDE_CODE_BRIDGE_SESSION_ID
CLAUDE_CODE_MESSAGING_SOCKET
CLAUDE_CODE_MESSAGING_TOKEN
CLAUDE_CODE_EXECPATH
CLAUDE_CODE_INVOKED_SKILLS
CLAUDE_PID
CLAUDE_EFFORT
AI_AGENT
OMPCODE
PI_CODING_AGENT
FM_PI_HARNESS
GROK_AGENT
CURSOR_AGENT
CURSOR_INVOKED_AS
EOF
}

# fm_launch_marker_prefix: the `env -u ...` prefix, trailing space included so a
# caller can concatenate it straight onto a launch command. It is applied to
# EVERY adapter rather than a per-harness list, because a marker is foreign to
# the harness that set it too: a claude worker launched from a claude primary
# inherits exactly the same session bindings as one launched from omp.
fm_launch_marker_prefix() {
  local name out='env'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    out="$out -u $name"
  done <<EOF
$(fm_launch_foreign_markers)
EOF
  printf '%s ' "$out"
}
