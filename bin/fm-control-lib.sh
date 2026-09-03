#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|atomic|grok|kimi|cursor|muse) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# and an unrecognized value returns nonzero rather than being guessed into a
# family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    atomic) printf 'atomic' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    muse*) printf 'muse' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse and atomic are
# crewmate/scout adapters only, for different reasons. muse has no primary
# supervision protocol at all. atomic is not in muse's position: it has the full
# primary capability surface, being a Pi fork whose extension API is pi's, but it
# has no tracked primary extension tree and no supervision protocol of its own,
# so the secondmate launch surface is unbuilt for it. bin/fm-spawn.sh refuses a
# --secondmate launch on both. The control plane asks this BEFORE it stops
# anything, so an incompatible relaunch target is refused while the current agent
# is still running rather than after it has been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|atomic) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# omp cancels on a single Escape: the running tool closed with
# `[Command cancelled]` and the agent settled (verified live, omp 17.3.5).
# atomic cancels on a single Escape too: the pane printed `Request aborted`, the
# running tool closed with `Command aborted`, and the composer returned to its
# prompt row (verified live, atomic 0.9.13). A SECOND Escape is deliberately not
# sent: on an idle empty composer atomic's default double-Escape action opens the
# session-tree overlay, so a "press it twice to be safe" interrupt could park a
# modal over an idle worker.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|atomic|kimi|cursor|muse) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|omp|atomic|grok|kimi|cursor|muse) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse and atomic are the verified adapters
# that RESTORE text into the composer as real bright text, so an interrupt is not
# complete until Ctrl+U has cleared it; leaving it there would make the next
# submitted line - a steer, or this plane's own exit command - concatenate onto
# it. The two restore different text, and atomic's case is the one firstmate hits
# routinely: a steer submitted while the worker is BUSY is queued, and atomic puts
# every queued message back into the editor when the turn is cancelled (verified
# live on atomic 0.9.13 - a queued steer line reappeared in the composer after a
# single Escape and the pane classified `pending` until Ctrl+U, which returned it
# to `empty`). atomic does not restore the in-flight prompt itself, so an
# interrupt with nothing queued needs no clear - but this plane cannot know
# whether a steer was queued, so it always clears.
# cursor and omp were both checked for the same behaviour and do NOT repollute:
# after a single Escape cursor's composer shows only the `Add a follow-up`
# placeholder and omp's returns to an empty input row, so neither needs a clear
# key. Prints the key or nothing; a harness with no verified mechanics returns
# nonzero, matching the tables above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse|atomic) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

# omp's own busy source DOES close on an interrupt - agent_end fires with
# willContinue unset, the same terminal path a completed run takes - but it is a
# pushed record rather than an adapter-observable acknowledgement this plane can
# read back at the moment it delivers the key, so it claims none, like cursor.
#
# atomic is the second adapter after muse that can supply a real one. It appends
# an assistant record carrying `"stopReason":"aborted"` to its own session
# transcript when a turn is cancelled, and that record is APPENDED, so the claim
# is made against bytes written after the offset this plane captured before it
# delivered the key - a prior aborted turn in the same transcript can never be
# mistaken for this one (verified live, atomic 0.9.13).
fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    atomic) printf 'atomic-session-aborted' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) printf 'none' ;;
    *) return 1 ;;
  esac
}

# --- atomic interrupt-acknowledgement binding --------------------------------
#
# atomic writes one JSON-lines transcript per session under
# <sessions-root>/<cwd-slug>/<timestamp>_<session-id>.jsonl. bin/fm-spawn.sh
# pins the session id at launch and records it, with the sessions root it
# resolved then, in state/<id>.atomic-session; the id carries a per-launch suffix
# so a relaunch cannot leave two transcripts this cannot tell apart. Matching on
# the recorded id means atomic's own cwd-slug algorithm is never reimplemented
# here, and a slug change upstream cannot silently break the binding.
fm_control_atomic_binding_path() {  # <state-dir> <id>
  printf '%s/%s.atomic-session' "$1" "$2"
}

fm_control_atomic_binding_field() {  # <state-dir> <id> <key>
  local path value
  path=$(fm_control_atomic_binding_path "$1" "$2")
  [ -f "$path" ] || return 1
  value=$(awk -F= -v key="$3" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$path") || return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# The ONE transcript this task's launch created, or nonzero. Zero matches means
# the session has not written its file yet: atomic creates it only once the first
# assistant message exists. Two or more means the binding is ambiguous, which
# must never be resolved by guessing.
fm_control_atomic_session_file() {  # <state-dir> <id>
  local root session_id match='' count=0 candidate
  root=$(fm_control_atomic_binding_field "$1" "$2" sessions_root) || return 1
  session_id=$(fm_control_atomic_binding_field "$1" "$2" session_id) || return 1
  [ -d "$root" ] || return 1
  for candidate in "$root"/*/*_"$session_id".jsonl; do
    [ -f "$candidate" ] || continue
    match=$candidate
    count=$((count + 1))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$match"
}

fm_control_atomic_transcript_size() {  # <file>
  local size
  [ -f "$1" ] || return 1
  size=$(wc -c < "$1" 2>/dev/null) || return 1
  printf '%s' "${size//[[:space:]]/}"
}

# True when the bytes appended to <file> after <offset> carry an aborted
# assistant record. Both tokens must be on the SAME line, which is one JSON
# object, so a tool result that merely quoted the phrase cannot satisfy it.
fm_control_atomic_aborted_since() {  # <file> <offset>
  local file=$1 offset=$2
  [ -f "$file" ] || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  tail -c "+$((offset + 1))" "$file" 2>/dev/null \
    | grep '"stopReason":"aborted"' \
    | grep -q '"role":"assistant"'
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse) printf '/exit' ;;
    codex|pi|pi-signed) printf '/quit' ;;
    omp|atomic) printf '/exit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    atomic)
      printf '%s\n' "$state/$id.atomic-ext.ts"
      # The interrupt-ack binding is per-incarnation: a relaunch AWAY from atomic
      # must retire it so no retired launch's session id outlives its agent.
      printf '%s\n' "$state/$id.atomic-session"
      ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
