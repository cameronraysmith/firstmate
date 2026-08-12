#!/usr/bin/env bash
# tests/fm-classify-decision-key.test.sh - decision-key tolerance in the
# open-decisions fold (bin/fm-classify-lib.sh). A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). A stated slug
# that fails the key charset must still OPEN a record: dropping the line would
# leave the worker waiting on an answer that firstmate, the OPEN DECISIONS
# listing, and the teardown completion gate (bin/fm-decision-hold.sh's
# origin_open_decisions reads this exact fold) can never see. These tests drive
# the REAL status_open_decisions / status_open_decisions_incremental functions
# over crafted status files and assert their folded output, never the fold's own
# source text. Cross-drain cursor persistence and the incremental cost bound live
# in tests/fm-wake-drain-open-decisions-cursor.test.sh; the drain wiring lives in
# tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-tests)

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
  assert_keys_closable "$full" "$label"
}

# Every key the fold emits must be one fm-send's --resolve-key will accept
# (nonempty, A-Za-z0-9._- only, so it also cannot carry the TAB that separates
# the record's own fields). A key that fails this names a decision firstmate can
# see but never close, which is the same loss as never opening it.
assert_keys_closable() {  # <fold-output> <label>
  local out=$1 label=$2 line key
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    case "$key" in
      ''|*[!A-Za-z0-9._-]*)
        fail "$label: fold emitted the unclosable key '$key' in record '$line'" ;;
    esac
  done <<EOF
$out
EOF
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_mid_note_prose_mention_is_not_a_stated_key() {
  local dir
  dir=$(case_dir prose)
  # Only a token at the head of the note states a key; a summary merely
  # mentioning "[key=x]" deeper in must neither open nor close that key.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\n')" \
    "mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "a [key=x] mentioned mid-note is prose, never an opened or closed key"
}

test_malformed_stated_key_opens_a_record_outside_default() {
  local dir before after expected
  dir=$(case_dir malformed)
  # A stated-but-invalid slug still NAMES a decision, so it opens one: it folds
  # into the reserved malformed-key. namespace, identically from both key
  # positions, and never into "default".
  printf 'needs-decision [key=bad key]: pick the bound\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] pick the bound\n' > "$dir/after.status"
  expected=$(printf 'malformed-key.bad-key\tneeds-decision\tpick the bound\n')
  assert_fold "$dir/before.status" "$expected" "malformed before-colon key"
  assert_fold "$dir/after.status" "$expected" "malformed colon-first key"

  # Byte-for-byte equivalence across positions, exactly as for a valid slug: the
  # note-head token is key metadata whether or not its slug parses.
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two malformed key positions folded differently: '$before' vs '$after'"

  # The default bucket stays untouched, so the answer to an unrelated keyless
  # decision cannot close this one (the issue #2109 hazard).
  printf 'resolved: some other answer\n' >> "$dir/before.status"
  assert_fold "$dir/before.status" "$expected" "bare keyless resolution against a malformed-key record"
  pass "a malformed stated key opens its own record, never the shared default bucket"
}

test_malformed_key_decision_is_visible_to_the_completion_gate() {
  local dir state open
  dir=$(case_dir gate)
  state="$dir/state"
  mkdir -p "$state"
  # The fleet-wide surface the wake drain prints and the teardown completion
  # gate reads. Before this record existed, the worker stopped waiting on an
  # answer while every supervisor surface showed an empty open set.
  printf 'blocked [key=deploy token]: waiting on the deploy token\n' > "$state/t1.status"
  open=$(scan_open_decisions "$state")
  [ "$open" = "$(printf 't1\tmalformed-key.deploy-token\tblocked\twaiting on the deploy token\n')" ] \
    || fail "the fleet-wide open set hid a malformed-key blocker: got '$open'"
  pass "a malformed-key decision reaches the fleet-wide open set the completion gate reads"
}

test_malformed_key_records_close_and_stay_distinct() {
  local dir expected
  dir=$(case_dir malformed-distinct)
  # Derivation is deterministic, so a worker's own malformed resolution closes
  # exactly what its malformed open created - and two different malformed slugs
  # stay two decisions rather than collapsing the way a shared bucket would.
  printf 'needs-decision [key=bad key]: first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=other bad] second question\n' >> "$dir/t.status"
  expected=$(printf 'malformed-key.bad-key\tneeds-decision\tfirst question\nmalformed-key.other-bad\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two distinct malformed keys"

  printf 'resolved: [key=bad key] cleared on its own\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'malformed-key.other-bad\tneeds-decision\tsecond question\n')" \
    "a malformed resolution closing its own malformed open"

  # And firstmate closes the survivor with the key the listing showed it, which
  # is what --resolve-key sends.
  printf 'resolved [key=malformed-key.other-bad]: answered: use 4\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "the listed derived key closes the record"
  pass "malformed-key records close by their own key and never collapse into one bucket"
}

test_malformed_key_cannot_shadow_a_valid_key_or_a_reserved_namespace() {
  local dir expected
  dir=$(case_dir malformed-namespace)
  # The near-miss pair: a malformed slug must not land on the valid key it
  # resembles, or answering one would close the other.
  printf 'needs-decision [key=bad key]: the malformed one\n' > "$dir/t.status"
  printf 'needs-decision [key=bad-key]: the valid one\n' >> "$dir/t.status"
  expected=$(printf 'malformed-key.bad-key\tneeds-decision\tthe malformed one\nbad-key\tneeds-decision\tthe valid one\n')
  assert_fold "$dir/t.status" "$expected" "malformed slug beside the valid slug it resembles"

  # And a malformed slug must not derive INTO a reserved namespace, whose
  # transition rule would reject the line straight back into invisibility.
  printf 'needs-decision [key=pending-reply-abc def]: ordinary worker question\n' > "$dir/r.status"
  assert_fold "$dir/r.status" \
    "$(printf 'malformed-key.pending-reply-abc-def\tneeds-decision\tordinary worker question\n')" \
    "malformed slug resembling a reserved key"
  pass "a derived key shadows neither a valid stated key nor a reserved namespace"
}

test_unrenderable_stated_key_still_opens_a_record() {
  local dir
  dir=$(case_dir malformed-unrenderable)
  # An empty slug has nothing to sanitize into, and a slug carrying the record's
  # own TAB separator would corrupt every consumer that splits on it. Both still
  # open a closable record.
  printf 'needs-decision [key=]: no slug at all\n' > "$dir/empty.status"
  assert_fold "$dir/empty.status" \
    "$(printf 'malformed-key.unreadable\tneeds-decision\tno slug at all\n')" \
    "empty stated slug"

  printf 'needs-decision [key=a\tb]: tab inside the slug\n' > "$dir/tab.status"
  assert_fold "$dir/tab.status" \
    "$(printf 'malformed-key.a-b\tneeds-decision\ttab inside the slug\n')" \
    "tab inside the stated slug"
  pass "an empty or unrenderable stated slug still opens a closable record"
}

test_previous_fold_cache_cannot_hide_a_malformed_key_decision() {
  local dir f cursor offset_line ident_line expected
  dir=$(case_dir malformed-cache)
  f="$dir/t.status"
  cursor="$dir/.t.open-decisions-cursor"
  expected=$(printf 'malformed-key.bad-key\tneeds-decision\tpick the bound\n')
  printf 'needs-decision [key=bad key]: pick the bound\n' > "$f"
  status_open_decisions_incremental "$f" >/dev/null

  # The cache the pre-fix interpretation left behind: this file, fully consumed,
  # with the empty open set that dropping the line produced. Only the fold
  # version distinguishes it, so an unbumped version would keep that home blind
  # to the decision forever.
  offset_line=$(grep '^offset=' "$cursor") || fail "the incremental fold wrote no offset"
  ident_line=$(grep '^ident=' "$cursor") || fail "the incremental fold wrote no file identity"
  printf 'version=3\n%s\n%s\n' "$offset_line" "$ident_line" > "$cursor"

  [ "$(status_open_decisions_incremental "$f")" = "$expected" ] \
    || fail "a cache from the previous interpretation kept the malformed-key decision hidden"
  pass "a fold cache written under the previous interpretation is rebuilt, not trusted"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_opens_a_record_outside_default
test_malformed_key_decision_is_visible_to_the_completion_gate
test_malformed_key_records_close_and_stay_distinct
test_malformed_key_cannot_shadow_a_valid_key_or_a_reserved_namespace
test_unrenderable_stated_key_still_opens_a_record
test_previous_fold_cache_cannot_hide_a_malformed_key_decision
test_incremental_agrees_with_full_fold_across_appends
