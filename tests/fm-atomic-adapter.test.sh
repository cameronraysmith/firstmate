#!/usr/bin/env bash
# tests/fm-atomic-adapter.test.sh - the atomic CREWMATE/SCOUT adapter
# (bin/fm-spawn.sh launch profile and per-task wiring, bin/fm-busy-lib.sh source
# registration, bin/fm-control-lib.sh control plane and interrupt-ack fold,
# bin/fm-composer-lib.sh delivery busy signature, bin/fm-teardown.sh cleanup).
#
# atomic is a Pi fork, so the risk this suite exists to close is inheritance by
# assumption. Two facts make that concrete and both are pinned below: atomic's
# model axis needs TWO flags because `--model provider/id` does not pin a
# provider, and atomic scans `.pi/` as well as its own tree, so the launch must
# carry -na or a worktree's Pi extensions reach the worker.
#
# The launch cases run the REAL fm-spawn against a fake tmux pane, an isolated
# git worktree, and a fake `atomic` that answers `--list-models`, so the model
# preflight, the composed launch command, and both per-task artifacts are
# exercised together with no live harness. The vendor-rendered facts (busy
# footer, interrupt restore, composer verdict) are pinned portably here against
# captured output and re-proven against real atomic by
# tests/fm-atomic-adapter-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-atomic-adapter)

# The catalog the fake atomic publishes. It carries the header row
# `atomic --list-models` prints, the authenticated-provider shape, and one
# openrouter id containing a slash, which is the case the canonical-form split
# must not break.
ATOMIC_FAKE_CATALOG='provider      model                     context  max-out  thinking  images
anthropic     claude-opus-5             1M       128K     yes       yes
anthropic     claude-haiku-4-5          200K     64K      yes       yes
openrouter    ~anthropic/claude-sonnet-latest  1M   64K   yes       yes'

# make_case <name> <id> [catalog-mode] -> case|home|proj|wt|fakebin|log
# catalog-mode: ok (default) publishes the catalog; unreadable exits nonzero for
# --list-models, the case that must warn rather than refuse.
make_case() {
  local name=$1 id=$2 mode=${3:-ok} case_dir home proj wt fakebin log
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
  if [ "$mode" = unreadable ]; then
    cat > "$fakebin/atomic" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --list-models) exit 1 ;;
esac
exit 0
SH
  else
    cat > "$fakebin/atomic" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --list-models) printf '%s\\n' "$ATOMIC_FAKE_CATALOG"; exit 0 ;;
esac
exit 0
SH
  fi
  chmod +x "$fakebin/atomic"
  fm_fake_exit0 "$fakebin" treehouse
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$log"
}

run_spawn() {  # <home> <wt> <fakebin> <args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The launch command is the LAST recorded send-keys payload naming the binary;
# earlier payloads are the worktree acquisition and env exports.
launch_line() {  # <log>
  grep -F -- 'fakebin/atomic' "$1" | tail -1
}

test_launch_shape_carries_every_verified_flag() {
  local home proj wt fakebin log out launch state id=atomic-launch-1
  IFS='|' read -r _ home proj wt fakebin log <<EOF
$(make_case launch "$id")
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model anthropic/claude-opus-5 --effort medium --mode no-mistakes --yolo off)
  expect_code 0 $? "atomic spawn should succeed: $out"
  state="$home/state"

  launch=$(launch_line "$log")
  [ -n "$launch" ] || fail "no atomic launch command reached the pane; log: $(cat "$log")"

  assert_contains "$launch" ' -na ' \
    "the launch must carry -na: without it atomic loads a worktree's own .pi/extensions and blocks on its trust dialog"
  assert_contains "$launch" "--provider 'anthropic' --model 'claude-opus-5'" \
    "the canonical provider/id pair must be SPLIT into --provider and --model"
  assert_not_contains "$launch" "--model 'anthropic/claude-opus-5'" \
    "passing the combined form to --model alone does not pin the provider on atomic"
  assert_contains "$launch" "--thinking 'medium'" "the effort axis must reach --thinking"
  assert_contains "$launch" "-e '$state/$id.atomic-ext.ts'" \
    "the busy extension must be loaded by explicit absolute -e path, outside the worktree"
  assert_contains "$launch" '--session-id ' \
    "the launch must pin a session id so the transcript filename is deterministic"

  # The extension is the busy source. Its CONTENT is not asserted here: the
  # generated artifact is driven in a real Node host by
  # tests/fm-busy-adapter-wiring.test.sh, which proves the predicate rather than
  # its source text.
  assert_present "$state/$id.atomic-ext.ts" "atomic spawn did not write the per-task extension"

  out=$(fm_busy_classify tmux fake:w atomic "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "the spawn must seed the busy contract, got '$out'"
  pass "atomic launch: -na, split provider/model, --thinking, explicit -e, pinned session id, both sidecars"
}

test_nested_provider_id_splits_on_the_first_slash_only() {
  local home proj wt fakebin log out launch id=atomic-nested-1
  IFS='|' read -r _ home proj wt fakebin log <<EOF
$(make_case nested "$id")
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model 'openrouter/~anthropic/claude-sonnet-latest' --mode direct-PR --yolo off)
  expect_code 0 $? "a provider whose ids contain slashes must still spawn: $out"
  launch=$(launch_line "$log")
  assert_contains "$launch" "--provider 'openrouter' --model '~anthropic/claude-sonnet-latest'" \
    "the split must take the FIRST slash only; openrouter publishes ids that contain slashes"
  pass "canonical model form: the provider/id split takes the first slash only"
}

# atomic is verified for scout work as well as ship work, and a scout carries no
# delivery contract, so the same launch and the same wiring have to come out of a
# spawn that passes neither --mode nor --yolo.
test_scout_spawn_gets_the_same_wiring() {
  local home proj wt fakebin log out launch state id=atomic-scout-1
  IFS='|' read -r _ home proj wt fakebin log <<EOF
$(make_case scout "$id")
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --scout --model anthropic/claude-haiku-4-5 --effort xhigh)
  expect_code 0 $? "atomic scout spawn should succeed: $out"
  state="$home/state"
  launch=$(launch_line "$log")
  assert_contains "$launch" ' -na ' "a scout launch must carry the same project-local fence"
  assert_contains "$launch" "--thinking 'xhigh'" "a scout launch must carry the requested effort"
  assert_present "$state/$id.atomic-ext.ts" "a scout spawn did not write the busy extension"
  assert_present "$state/$id.atomic-session" "a scout spawn did not write the session binding"
  pass "atomic scout spawns get the same launch fence, effort axis, and per-task wiring"
}

test_model_without_a_provider_is_refused() {
  local home proj wt fakebin out status id=atomic-bare-1
  IFS='|' read -r _ home proj wt fakebin _ <<EOF
$(make_case bare "$id")
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model claude-opus-5 --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a bare model id was accepted for atomic: $out"
  assert_contains "$out" "canonical provider/id model form" \
    "the refusal must name the required form"
  assert_absent "$home/state/$id.meta" \
    "the model axis must be refused BEFORE endpoint creation"
  pass "atomic refuses a model with no provider prefix, before endpoint creation"
}

test_model_absent_from_the_catalog_is_refused() {
  local home proj wt fakebin out status id=atomic-unknown-1
  IFS='|' read -r _ home proj wt fakebin _ <<EOF
$(make_case unknown "$id")
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model anthropic/claude-opus-9999 --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unpublished model was accepted for atomic: $out"
  assert_contains "$out" '--list-models' "the refusal must name the catalog it checked"
  assert_absent "$home/state/$id.meta" \
    "an unpublished model must be refused BEFORE endpoint creation, because atomic would launch and then die on a provider 404"
  pass "atomic refuses a model its own catalog does not publish"
}

test_provider_mismatch_is_refused() {
  local home proj wt fakebin out status id=atomic-mismatch-1
  IFS='|' read -r _ home proj wt fakebin _ <<EOF
$(make_case mismatch "$id")
EOF
  # claude-opus-5 IS in the catalog, but under anthropic rather than openrouter.
  # This is the pair-level check: a per-id check would have passed it.
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model openrouter/claude-opus-5 --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a model published under a DIFFERENT provider was accepted: $out"
  assert_contains "$out" "not published for provider 'openrouter'" \
    "the refusal must name the provider that does not publish it"
  pass "atomic preflights the provider/model PAIR, not the id alone"
}

test_unreadable_catalog_warns_and_launches() {
  local home proj wt fakebin log out launch id=atomic-nocatalog-1
  IFS='|' read -r _ home proj wt fakebin log <<EOF
$(make_case nocatalog "$id" unreadable)
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" atomic \
    --model anthropic/claude-opus-5 --mode no-mistakes --yolo off)
  expect_code 0 $? "an unreadable catalog must not refuse the spawn: $out"
  assert_contains "$out" 'not preflighted' \
    "an unreadable catalog must say what it could not verify"
  launch=$(launch_line "$log")
  assert_contains "$launch" "--provider 'anthropic' --model 'claude-opus-5'" \
    "the launch must still carry the split model axis"
  pass "an unreadable catalog warns rather than refusing: a probe that cannot answer is not evidence of a bad model"
}

test_spawn_refuses_secondmate() {
  local home fakebin out status id=atomic-secondmate-1
  IFS='|' read -r _ home _ _ fakebin _ <<EOF
$(make_case secondmate "$id")
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" atomic --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "atomic was accepted as a secondmate harness: $out"
  assert_contains "$out" "secondmate launch wiring is not built" \
    "the refusal must name the unbuilt LAUNCH surface rather than implying atomic cannot supervise"
  fm_control_harness_supports_kind atomic secondmate \
    && fail "the control plane must refuse an atomic secondmate before it stops anything"
  fm_control_harness_supports_kind atomic ship \
    || fail "the control plane must accept an atomic ship task"
  pass "atomic is refused as a secondmate in both the spawn and the control plane"
}

test_control_plane_tables() {
  local out
  fm_control_harness_supported atomic || fail "atomic is not a supported control harness"
  out=$(fm_control_harness_family atomic)
  [ "$out" = atomic ] || fail "atomic must resolve to its own family, got '$out'"
  out=$(fm_control_interrupt_key atomic)
  [ "$out" = Escape ] || fail "atomic interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat atomic)
  # A second Escape on an idle empty composer opens atomic's session-tree overlay.
  [ "$out" = 1 ] || fail "atomic must interrupt on exactly one Escape, got '$out'"
  out=$(fm_control_interrupt_clear_key atomic)
  [ "$out" = C-u ] || fail "atomic restores queued text into its composer, so it needs C-u, got '$out'"
  out=$(fm_control_exit_command atomic)
  [ "$out" = /exit ] || fail "atomic exits with /exit, got '$out'"
  out=$(fm_control_interrupt_ack_source atomic)
  [ "$out" = atomic-session-aborted ] || fail "atomic supplies a transcript-backed ack, got '$out'"
  out=$(fm_control_harness_wiring_paths atomic /wt /state task-9)
  assert_contains "$out" '/state/task-9.atomic-ext.ts' "the extension is per-task wiring"
  assert_contains "$out" '/state/task-9.atomic-session' \
    "the session binding is per-incarnation wiring and must be retired by a relaunch away from atomic"
  pass "control plane: atomic's interrupt, clear, exit, ack, and wiring rows are wired"
}

# The ack is scoped by BYTE OFFSET, not by content: a transcript that already
# holds an aborted record must not confirm the NEXT interrupt.
test_interrupt_ack_is_scoped_to_new_bytes() {
  local dir state id=ack-1 file offset
  dir="$TMP_ROOT/ack"
  state="$dir/state"
  mkdir -p "$state/sessions/--proj--"
  printf 'sessions_root=%s\nsession_id=%s\nworkspace_root=%s\n' \
    "$state/sessions" fm-ack-1 "$dir/wt" > "$state/$id.atomic-session"
  file="$state/sessions/--proj--/2026-01-01T00-00-00-000Z_fm-ack-1.jsonl"
  printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"aborted","errorMessage":"Request aborted"}}' > "$file"

  out=$(fm_control_atomic_session_file "$state" "$id") \
    || fail "the one matching transcript was not resolved"
  [ "$out" = "$file" ] || fail "resolved the wrong transcript: '$out'"

  offset=$(fm_control_atomic_transcript_size "$file") || fail "transcript size unreadable"
  fm_control_atomic_aborted_since "$file" "$offset" \
    && fail "a PRIOR aborted record must not confirm a later interrupt"

  printf '%s\n' '{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"stopReason aborted mentioned in output"}]}}' >> "$file"
  fm_control_atomic_aborted_since "$file" "$offset" \
    && fail "a tool result quoting the phrase must not confirm a cancellation"

  printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[],"stopReason":"aborted","errorMessage":"Request aborted"}}' >> "$file"
  fm_control_atomic_aborted_since "$file" "$offset" \
    || fail "an aborted assistant record appended after the offset must confirm"
  pass "interrupt ack: confirmation comes only from an aborted assistant record appended after delivery"
}

test_ambiguous_or_missing_transcript_never_guesses() {
  local dir state id=ack-2 root
  dir="$TMP_ROOT/ack-ambiguous"
  state="$dir/state"
  root="$state/sessions"
  mkdir -p "$root/--a--" "$root/--b--"
  printf 'sessions_root=%s\nsession_id=%s\nworkspace_root=%s\n' \
    "$root" fm-ack-2 "$dir/wt" > "$state/$id.atomic-session"

  fm_control_atomic_session_file "$state" "$id" >/dev/null \
    && fail "no transcript yet must not resolve: atomic writes the file only after the first assistant message"

  printf '{}\n' > "$root/--a--/2026-01-01T00-00-00-000Z_fm-ack-2.jsonl"
  fm_control_atomic_session_file "$state" "$id" >/dev/null \
    || fail "exactly one match must resolve"

  printf '{}\n' > "$root/--b--/2026-01-02T00-00-00-000Z_fm-ack-2.jsonl"
  fm_control_atomic_session_file "$state" "$id" >/dev/null \
    && fail "two matching transcripts must refuse rather than pick one"
  pass "interrupt ack: zero or ambiguous transcripts refuse instead of guessing"
}

test_busy_source_is_atomics_own() {
  local out
  out=$(fm_busy_sources_for_harness atomic)
  assert_contains "$out" 'atomic-ext' "atomic must trust its own extension source"
  fm_busy_source_trusted atomic omp-ext \
    && fail "an omp-ext record must never be trusted for an atomic task"
  fm_busy_source_trusted atomic pi-ext \
    && fail "a pi-ext record must never be trusted for an atomic task"
  fm_busy_source_trusted omp atomic-ext \
    && fail "an atomic-ext record must never be trusted for an omp task"
  fm_busy_source_trusted atomic atomic-ext \
    || fail "atomic-ext must be trusted for an atomic task"
  # The name is exact, not a prefix, so a raw-launch basename cannot borrow it.
  out=$(fm_busy_sources_for_harness atomicfork)
  [ -z "$out" ] || fail "a merely atomic-prefixed harness name must trust nothing, got '$out'"
  pass "busy source: atomic-ext is exact and never crosses adapters"
}

test_delivery_busy_signature() {
  local footer='(anthropic) claude-haiku-4-5 low • /tmp/proj'
  local busy='esc to interrupt'
  printf '%s\0' "$busy" | fm_busy_lines_match atomic \
    || fail "atomic's verified busy footer must match its own signature"
  printf '%s\0' "$footer" | fm_busy_lines_match atomic \
    && fail "atomic's idle model/cwd row must not read busy"
  # Pi's token and omp's bracketed hint are the two wrong signatures to inherit.
  printf '%s\0' 'Working...' | fm_busy_lines_match atomic \
    && fail "pi's Working... must not classify atomic busy: atomic randomizes its spinner text"
  printf '%s\0' '⠙ Combobulating... ⟨esc⟩' | fm_busy_lines_match atomic \
    && fail "omp's bracketed esc must not classify atomic busy"
  printf '%s\0' "$busy" | fm_busy_lines_match pi \
    && fail "atomic's footer must not classify a pi pane busy"
  pass "delivery guard: atomic's footer is its own signature in both directions"
}

# Teardown removal is covered behaviorally by
# tests/fm-teardown.test.sh's test_teardown_removes_atomic_per_task_state_files,
# which runs the real script over a landed-work fixture; asserting it here could
# only read bin/fm-teardown.sh's source.

test_launch_shape_carries_every_verified_flag
test_nested_provider_id_splits_on_the_first_slash_only
test_scout_spawn_gets_the_same_wiring
test_model_without_a_provider_is_refused
test_model_absent_from_the_catalog_is_refused
test_provider_mismatch_is_refused
test_unreadable_catalog_warns_and_launches
test_spawn_refuses_secondmate
test_control_plane_tables
test_interrupt_ack_is_scoped_to_new_bytes
test_ambiguous_or_missing_transcript_never_guesses
test_busy_source_is_atomics_own
test_delivery_busy_signature
