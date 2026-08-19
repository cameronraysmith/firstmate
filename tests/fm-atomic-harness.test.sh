#!/usr/bin/env bash
# tests/fm-atomic-harness.test.sh - atomic harness identity
# (bin/fm-harness.sh detection, bin/fm-session-lock-lib.sh ancestry,
# bin/fm-launch-boundary-lib.sh sanitization).
#
# atomic is a Pi fork that derives its identity marker from its own app name
# rather than hard-coding Pi's: it sets ATOMIC_CODING_AGENT=true plus
# AI_AGENT=atomic, writes PI_SESSION_* compatibility aliases, and deliberately
# never writes PI_CODING_AGENT. These cases pin the facts that keep an atomic
# session claimable and non-confusable in both directions.
#
# The AI_AGENT conjunct is the load-bearing part and is asserted from both
# sides. The *_CODING_AGENT markers are sticky under nesting, so an atomic
# session that inherited CLAUDECODE must still read as atomic, while a claude or
# pi worker launched UNDER atomic inherits ATOMIC_CODING_AGENT and must not.
# AI_AGENT is what separates them, because every harness that publishes it
# rewrites it and the innermost one wins.
#
# The launch-boundary case runs the real launch command fm-spawn produced, under
# an environment carrying atomic's markers, and reads what the launched process
# actually received. It drives that through the claude adapter on purpose:
# atomic is not a spawnable adapter yet, and the marker set is applied to EVERY
# adapter rather than a per-harness list, so a leak is a leak whichever worker
# inherits it.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $1 expand inside the fixture child, not here
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-atomic-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

HARNESS="$ROOT/bin/fm-harness.sh"
LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A real executable renamed to atomic carries the ancestry, because the ancestry
# walk reads real process tables. atomic rewrites process.title to its app name,
# so the live process name really is the bare word.
ATOMIC_BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$ATOMIC_BIN_DIR"
cp "$(command -v bash)" "$ATOMIC_BIN_DIR/atomic"
cp "$(command -v bash)" "$ATOMIC_BIN_DIR/atomically"

cat > "$TMP_ROOT/ancestry-probe.sh" <<'SH'
#!/usr/bin/env bash
. "$1" || exit 3
p=$(fm_harness_ancestry_pid 2>/dev/null) || p=none
printf '%s\n' "$p"
SH
chmod +x "$TMP_ROOT/ancestry-probe.sh"

# Detection reads the AMBIENT environment, so a case that sets only the markers
# it cares about inherits whatever primary the suite itself runs under - and an
# omp or cursor primary's own marker outranks atomic's, which made these cases
# pass under claude and fail under omp. Every case therefore starts from a
# scrubbed marker set and adds back exactly what it is asserting.
harness_env() {  # <VAR=value...> <command...>
  env -u ATOMIC_CODING_AGENT -u AI_AGENT -u CLAUDECODE -u OMPCODE \
    -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$@"
}

test_atomic_marker_outranks_retained_claudecode_and_pi() {
  local out
  out=$(harness_env ATOMIC_CODING_AGENT=true AI_AGENT=atomic "$HARNESS")
  [ "$out" = atomic ] || fail "atomic's own markers must detect atomic, got '$out'"
  out=$(harness_env ATOMIC_CODING_AGENT=true AI_AGENT=atomic CLAUDECODE=1 "$HARNESS")
  [ "$out" = atomic ] || fail "a retained CLAUDECODE must not outrank atomic, got '$out'"
  out=$(harness_env ATOMIC_CODING_AGENT=true AI_AGENT=atomic PI_CODING_AGENT=true "$HARNESS")
  [ "$out" = atomic ] || fail "a leaked PI_CODING_AGENT must not outrank atomic, got '$out'"
  pass "fm-harness: atomic's markers outrank a retained claude or pi marker"
}

test_inherited_atomic_marker_never_claims_a_nested_worker() {
  local out
  out=$(harness_env ATOMIC_CODING_AGENT=true CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] \
    || fail "a claude worker carrying an inherited ATOMIC_CODING_AGENT must read as claude, got '$out'"
  out=$(harness_env ATOMIC_CODING_AGENT=true AI_AGENT=claude-code_2-1-234_agent CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] \
    || fail "AI_AGENT names the innermost harness, so this must read as claude, got '$out'"
  out=$(harness_env ATOMIC_CODING_AGENT=true AI_AGENT=pi PI_CODING_AGENT=true "$HARNESS")
  [ "$out" = pi ] \
    || fail "a pi worker launched under atomic must read as pi, got '$out'"
  out=$(harness_env ATOMIC_CODING_AGENT=1 AI_AGENT=atomic "$HARNESS")
  [ "$out" != atomic ] || fail "an inexact ATOMIC_CODING_AGENT value must not claim the atomic identity"
  pass "fm-harness: an inherited atomic marker alone never claims a nested worker"
}

test_atomic_ancestry_is_the_exact_process_name() {
  local out
  out=$(env -u CLAUDECODE -u OMPCODE -u ATOMIC_CODING_AGENT -u AI_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    "$ATOMIC_BIN_DIR/atomic" -c 'r=$("$1"); printf "%s" "$r"' _ "$HARNESS")
  [ "$out" = atomic ] || fail "fm-harness.sh under an atomic-named ancestor reported '$out', expected atomic"
  out=$(env -u CLAUDECODE -u OMPCODE -u ATOMIC_CODING_AGENT -u AI_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    "$ATOMIC_BIN_DIR/atomically" -c 'r=$("$1"); printf "%s" "$r"' _ "$HARNESS")
  [ "$out" != atomic ] || fail "an atomic-prefixed process name must never carry the atomic ancestry"
  pass "fm-harness: atomic ancestry is detected through the exact process name"
}

test_lock_harness_table_is_exact_for_atomic() {
  local out
  out=$(bash -c '. "$1"; fm_harness_process_matches atomic "" && echo match || echo no' _ "$LIB")
  [ "$out" = match ] || fail "the exact name atomic must match the harness table"
  out=$(bash -c '. "$1"; fm_harness_process_matches atomically "" && echo match || echo no' _ "$LIB")
  [ "$out" = no ] || fail "an atomic-containing name must not match the harness table"
  pass "fm-session-lock-lib: the atomic entry is anchored to the exact name"
}

test_lock_ancestry_resolves_the_nearest_atomic_process() {
  local out mine got
  out=$("$ATOMIC_BIN_DIR/atomic" -c 'printf "%s\n" $$; r=$("$1" "$2"); printf "%s\n" "$r"' \
    _ "$TMP_ROOT/ancestry-probe.sh" "$LIB")
  mine=$(printf '%s\n' "$out" | sed -n 1p)
  got=$(printf '%s\n' "$out" | sed -n 2p)
  [ "$got" = "$mine" ] \
    || fail "lock ancestry resolved '$got', expected the atomic-named parent $mine"
  pass "fm-session-lock-lib: an atomic-named ancestor owns the fleet-lock identity"
}

# Build a spawn case whose fake tmux RECORDS every send-keys payload, so the
# real launch command can be replayed afterwards.
atomic_spawn_case() {  # <name> <id> -> home|proj|wt|fakebin|log
  local name=$1 id=$2 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin="$case_dir/fake/fakebin"
  log="$case_dir/sendkeys.log"
  mkdir -p "$fakebin" "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for a in "\$@"; do
      case "\$a" in
        -*|send-keys|firstmate:*) continue ;;
        *) printf '%s\\n' "\$a" >> "$log" ;;
      esac
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$log"
}

test_launch_boundary_clears_atomic_session_markers() {
  local home proj wt fakebin log launch out marker leaked=
  IFS='|' read -r home proj wt fakebin log <<CASE
$(atomic_spawn_case launch-sanitize sanitize-atomic-1)
CASE
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
env | sort
exit 0
SH
  chmod +x "$fakebin/claude"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" sanitize-atomic-1 "$proj" claude --mode no-mistakes --yolo off 2>&1) \
    || fail "spawn should succeed: $out"

  launch=$(grep -F -- claude "$log" | tail -1)
  [ -n "$launch" ] || fail "no launch command was sent to the pane; log: $(cat "$log")"

  out=$(cd "$wt" && env PATH="$fakebin:$PATH" \
    ATOMIC_CODING_AGENT=true AI_AGENT=atomic \
    ATOMIC_SESSION_ID=01a0171e ATOMIC_SESSION_FILE=/stale/parent.jsonl \
    PI_SESSION_ID=01a0171e PI_SESSION_FILE=/stale/parent.jsonl \
    ATOMIC_REASONING_LEVEL=off PI_REASONING_LEVEL=off \
    ATOMIC_SKIP_VERSION_CHECK=1 \
    bash -c "$launch")

  for marker in ATOMIC_CODING_AGENT AI_AGENT ATOMIC_SESSION_ID ATOMIC_SESSION_FILE \
    PI_SESSION_ID PI_SESSION_FILE ATOMIC_REASONING_LEVEL PI_REASONING_LEVEL; do
    printf '%s\n' "$out" | grep -q "^$marker=" && leaked="$leaked $marker"
  done
  [ -z "$leaked" ] || fail "the launch boundary leaked atomic session markers:$leaked"
  printf '%s\n' "$out" | grep -q '^ATOMIC_SKIP_VERSION_CHECK=1$' \
    || fail "ATOMIC_SKIP_VERSION_CHECK is operator configuration and must survive the launch boundary"
  pass "launch boundary: a spawn clears atomic's identity and session markers, and nothing else"
}

test_atomic_marker_outranks_retained_claudecode_and_pi
test_inherited_atomic_marker_never_claims_a_nested_worker
test_atomic_ancestry_is_the_exact_process_name
test_lock_harness_table_is_exact_for_atomic
test_lock_ancestry_resolves_the_nearest_atomic_process
test_launch_boundary_clears_atomic_session_markers
