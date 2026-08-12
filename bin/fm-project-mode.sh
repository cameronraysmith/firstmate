#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture and Herdr session from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> session=<s>] - <desc> ...         -> <mode> off, Herdr session <s>
#
# The bracket holds space-separated annotation tokens and is order-independent
# apart from the leading mode: `+yolo` is a bare flag and `session=` is a
# key=value token, so a line may carry either, both, or neither. A token this
# parser does not recognize is ignored, which is what keeps a registry extended
# for a newer firstmate readable by an older one.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# --session prints ONLY the project's recorded Herdr session name and exits 0.
# It is the spawn-time worker-placement selector (docs/herdr-backend.md "Session
# selection"), so unlike the posture output above it FAILS CLOSED: a missing
# registry, an unregistered project, an absent session= token, a name Herdr
# itself would reject, or the reserved orchestrator session "default" all print
# an actionable error to stderr, print nothing to stdout, and exit 1. Falling
# back to an ambient default here would place a worker in whatever session the
# orchestrator's environment happened to name, which is the exact defect this
# selector exists to remove.
# Usage: fm-project-mode.sh [--raw|--session] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
WANT=posture
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --session) WANT=session; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--session] <project-name>}

# The exact registry edit every fail-closed session refusal below asks for.
session_fix_hint() {
  printf 'record it in %s as: - %s [<mode> session=<herdr-session>] - <desc>' "$REG" "$NAME"
}

if [ ! -f "$REG" ]; then
  if [ "$WANT" = session ]; then
    echo "error: no project registry at $REG, so \"$NAME\" has no Herdr session to spawn a worker into; $(session_fix_hint)" >&2
    exit 1
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode>\t<yolo>\t<session>" (one line, session possibly empty) or
# nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; session="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] !~ /^session=/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j] ~ /^session=/) session = substr(a[j], 9);
      }
    }
    printf "%s\t%s\t%s\n", mode, yolo, session; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$WANT" = session ]; then
    echo "error: project \"$NAME\" is not in $REG, so it has no Herdr session to spawn a worker into; $(session_fix_hint)" >&2
    exit 1
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\t' read -r mode yolo session <<EOF
$parsed
EOF

if [ "$WANT" = session ]; then
  if [ -z "$session" ]; then
    echo "error: project \"$NAME\" is registered in $REG but records no Herdr session, and a worker is never placed from the orchestrator's environment; $(session_fix_hint)" >&2
    exit 1
  fi
  # Herdr 0.8.0's own session-name rule (src/session.rs validate_name): 1..64
  # bytes of ASCII letters, digits, '.', '_', and '-', never "." or "..". A name
  # outside it cannot name a session at all, so accepting it here would only
  # move the failure to a confusing herdr error mid-spawn.
  case "$session" in
    .|..|*[!A-Za-z0-9._-]*)
      echo "error: project \"$NAME\" records Herdr session \"$session\" in $REG, which Herdr cannot name (ASCII letters, digits, '.', '_', '-' only, and never '.' or '..')" >&2
      exit 1
      ;;
  esac
  if [ "${#session}" -gt 64 ]; then
    echo "error: project \"$NAME\" records Herdr session \"$session\" in $REG, which is longer than the 64 bytes Herdr allows" >&2
    exit 1
  fi
  if [ "$session" = default ]; then
    echo "error: project \"$NAME\" records the reserved Herdr session \"default\" in $REG; \"default\" carries the orchestrator sessions and never workers, so give $NAME a session of its own" >&2
    exit 1
  fi
  printf '%s\n' "$session"
  exit 0
fi

case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
