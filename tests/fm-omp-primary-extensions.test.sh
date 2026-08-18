#!/usr/bin/env bash
# Portable contract tests for the tracked omp primary extension pair.
#
# These pin the facts that separate omp from Pi. Pi's extension files LOAD on omp
# and are silently inert there, so every assertion below exists to keep a future
# edit from quietly re-borrowing a Pi shape: the turn-end guard must hang off the
# blocking session_stop and never agent_settled, the watcher wake must carry NO
# options object, and each extension must write omp's OWN loaded marker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-primary-extensions)
GUARD_EXT="$ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
WATCH_EXT="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"
export NODE_NO_WARNINGS=1

# The extensions import the ONE operational-input adapter across roots, and that
# adapter resolves bin/fm-operational-input.sh from its own module path, so a
# fixture repo needs both trees.
install_omp_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$GUARD_EXT" "$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cp "$WATCH_EXT" "$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
}

test_turnend_guard_blocks_the_stop_and_forwards_stop_hook_active() {
  local repo home out status=0
  repo="$TMP_ROOT/guard-block-root"
  home="$TMP_ROOT/guard-block-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat >> "$FM_HOME/state/payloads.log"
printf '\n' >> "$FM_HOME/state/payloads.log"
printf 'TURN WOULD END BLIND - SUPERVISION IS OFF\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (handlers.has("agent_settled")) {
  console.error("the omp guard registered Pi's agent_settled handler, which never fires on omp");
  process.exit(1);
}
const stop = handlers.get("session_stop");
if (!stop) { console.error("no session_stop handler registered"); process.exit(1); }
const first = await stop({ stop_hook_active: false }, {});
if (first?.decision !== "block") {
  console.error(`first stop was not blocked: ${JSON.stringify(first)}`);
  process.exit(1);
}
if (!String(first.reason).includes("TURN WOULD END BLIND")) {
  console.error(`block reason did not carry the guard banner: ${first.reason}`);
  process.exit(1);
}
// The guard's banner is hook-channel text, not an injected user message, so it
// must NOT be operational-input encoded the way Pi's follow-up is.
if (String(first.reason).includes("FIRSTMATE_OP:")) {
  console.error("the block reason was operational-input encoded");
  process.exit(1);
}
await stop({ stop_hook_active: true }, {});
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp turn-end guard did not block a blind stop" "$out"
  assert_contains "$(cat "$home/state/payloads.log")" '"stop_hook_active":false' \
    "omp guard did not forward the first stop's own stop_hook_active"
  assert_contains "$(cat "$home/state/payloads.log")" '"stop_hook_active":true' \
    "omp guard hardcoded stop_hook_active instead of forwarding omp's value"
  pass "omp turn-end guard blocks the stop and forwards omp's own stop_hook_active"
}

test_turnend_guard_allows_a_healthy_stop() {
  local repo home out status=0
  repo="$TMP_ROOT/guard-allow-root"
  home="$TMP_ROOT/guard-allow-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await handlers.get("session_stop")({ stop_hook_active: false }, {});
if (result !== undefined) {
  console.error(`a healthy stop was not allowed: ${JSON.stringify(result)}`);
  process.exit(1);
}
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp turn-end guard did not allow a healthy stop" "$out"
  pass "omp turn-end guard allows a stop the guard predicate cleared"
}

test_turnend_guard_writes_only_omps_own_marker() {
  local repo home out status=0
  repo="$TMP_ROOT/guard-marker-root"
  home="$TMP_ROOT/guard-marker-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default({ on() {} });
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp turn-end extension failed to load" "$out"
  [ -f "$home/state/.omp-turnend-extension-loaded" ] \
    || fail "omp turn-end extension did not write its own loaded marker"
  [ -f "$home/state/.pi-turnend-extension-loaded" ] \
    && fail "omp turn-end extension wrote Pi's marker, which would let a disarmed Pi session satisfy an omp primary"
  assert_contains "$(sed -n '1p' "$home/state/.omp-turnend-extension-loaded")" "sha256:" \
    "omp turn-end marker did not record a build digest"
  pass "omp turn-end extension records its own marker and never Pi's"
}

test_sessionstart_nudge_is_encoded_and_source_derived() {
  local repo home out status=0
  repo="$TMP_ROOT/nudge-root"
  home="$TMP_ROOT/nudge-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'SOURCE=%s\n' "$2"
SH
  chmod +x "$repo/bin/fm-sessionstart-run.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const sent = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage(message) { sent.push(message); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const header = (extra) => ({ sessionManager: { getHeader: () => extra } });
// omp's session_start carries no reason field at all, so the source has to come
// from the header and argv.
await handlers.get("session_start")({}, header({ timestamp: new Date().toISOString() }));
await handlers.get("session_start")({}, header({ parentSession: "01a0-parent" }));
await handlers.get("session_compact")({}, header({}));
if (sent.length !== 3) {
  console.error(`expected three injections, saw ${sent.length}`);
  process.exit(1);
}
const sources = sent.map((m) => (m.content.match(/SOURCE=(\S+)/) || [])[1]);
if (sources[0] !== "startup") { console.error(`fresh session was not startup: ${sources[0]}`); process.exit(1); }
if (sources[1] !== "fork") { console.error(`a parentSession header was not a fork: ${sources[1]}`); process.exit(1); }
if (sources[2] !== "compact") { console.error(`session_compact was not compact: ${sources[2]}`); process.exit(1); }
for (const message of sent) {
  if (message.customType !== "firstmate-sessionstart-nudge") {
    console.error(`unexpected customType: ${message.customType}`);
    process.exit(1);
  }
  if (message.display !== false) { console.error("nudge was displayed"); process.exit(1); }
  // omp injects a MESSAGE rather than hook stdout, so provenance is mandatory.
  if (!message.content.startsWith("⁣FIRSTMATE_OP: v1 session-start: ")) {
    console.error(`untyped operational injection: ${JSON.stringify(message.content)}`);
    process.exit(1);
  }
}
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp session-start injection contract broke" "$out"
  pass "omp injects an operational-input encoded digest and derives its source without a reason field"
}

test_sessionstart_nudge_skips_an_empty_digest() {
  local repo home out status=0
  repo="$TMP_ROOT/nudge-empty-root"
  home="$TMP_ROOT/nudge-empty-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-sessionstart-run.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let sent = 0;
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() { sent += 1; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({}, {});
if (sent !== 0) { console.error("an empty digest was still injected"); process.exit(1); }
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp injected an empty session-start digest" "$out"
  pass "omp skips injection when the session-start wrapper stays silent"
}

test_tool_call_seatbelt_blocks_a_denied_command() {
  local repo home out status=0
  repo="$TMP_ROOT/seatbelt-root"
  home="$TMP_ROOT/seatbelt-home"
  mkdir -p "$home/state"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'denied: backgrounded watcher arm\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-cd-pretool-check.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default({ on(e, h) { handlers.set(e, h); } });
const call = handlers.get("tool_call");
const blocked = await call({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } });
if (blocked?.block !== true) { console.error(`arm seatbelt did not block: ${JSON.stringify(blocked)}`); process.exit(1); }
if (!String(blocked.reason).includes("backgrounded watcher arm")) {
  console.error(`seatbelt reason was lost: ${blocked.reason}`);
  process.exit(1);
}
const other = await call({ type: "tool_call", toolName: "read", input: { command: "x" } });
if (other?.block) { console.error("seatbelt blocked a non-bash tool"); process.exit(1); }
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp PreToolUse seatbelt contract broke" "$out"
  pass "omp blocks a denied bash command through the shared PreToolUse seatbelt"
}

test_watch_extension_wake_carries_no_options_object() {
  local repo home out status=0
  repo="$TMP_ROOT/wake-root"
  home="$TMP_ROOT/wake-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  # Call 1 closes actionable, which is what makes the extension start a successor.
  # The successor must then stay alive and READY, or the extension keeps replacing a
  # cycle that keeps closing actionable - the same live behaviour, and an infinite
  # loop in a fixture.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
calls="$FM_HOME/state/arm-calls"
count=0
[ ! -f "$calls" ] || count=$(cat "$calls")
count=$((count + 1))
printf '%s\n' "$count" > "$calls"
printf 'watcher: started pid=42%s recovery-generation=g%s\n' "$count" "$count"
[ "$count" -eq 1 ] || exec sleep 30
printf 'signal: done: portable omp wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=1 \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let handler = null;
let notification = "";
let prompt = "";
let extraArgs = -1;
let toolName = "";
const pi = {
  on() {},
  typebox: { Type: { Object: (p) => ({ type: "object", properties: p }) } },
  registerCommand(name, options) { if (name === "fm-watch-arm-omp") handler = options.handler; },
  registerTool(tool) { toolName = tool.name; },
  sendUserMessage: async (message, ...rest) => { prompt = message; extraArgs = rest.length; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (toolName !== "fm_watch_arm_omp") {
  console.error(`watch extension registered the wrong tool: ${toolName}`);
  process.exit(1);
}
if (!handler) { console.error("fm-watch-arm-omp command was not registered"); process.exit(1); }
await handler("", { ui: { notify(message) { notification = message; } } });
if (!notification.includes("started omp extension arm child")) { console.error(notification); process.exit(1); }
for (let i = 0; i < 250 && !prompt; i += 1) await new Promise((r) => setTimeout(r, 20));
if (!prompt.startsWith("⁣FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational wake: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) { console.error(prompt); process.exit(1); }
// The single most important omp-vs-Pi difference. deliverAs: "followUp" only
// QUEUES an omp wake while the session is idle, so a Pi-shaped call would produce
// a wake that never fires.
if (extraArgs !== 0) {
  console.error(`the omp wake passed ${extraArgs} extra argument(s); it must be sendUserMessage(content) alone`);
  process.exit(1);
}
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp watcher wake contract broke" "$out"
  [ -f "$home/state/.omp-watch-extension-loaded" ] \
    || fail "omp watch extension did not write its own loaded marker"
  [ -f "$home/state/.pi-watch-extension-loaded" ] \
    && fail "omp watch extension wrote Pi's marker"
  pass "omp delivers a typed watcher wake with no deliverAs and records its own marker"
}

test_watch_extension_refuses_a_foreign_session_lock() {
  local repo home out status=0
  repo="$TMP_ROOT/foreign-lock-root"
  home="$TMP_ROOT/foreign-lock-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=1 recovery-generation=g1\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let handler = null;
let notification = "";
const holder = spawn("sleep", ["30"], { stdio: "ignore" });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${holder.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default({
  on() {},
  typebox: { Type: { Object: (p) => ({ type: "object", properties: p }) } },
  registerCommand(name, options) { if (name === "fm-watch-arm-omp") handler = options.handler; },
  registerTool() {},
  sendUserMessage: async () => {},
});
await handler("", { ui: { notify(message) { notification = message; } } });
holder.kill("SIGTERM");
if (!notification.includes("read-only")) {
  console.error(`a foreign session lock was not refused: ${notification}`);
  process.exit(1);
}
process.stdout.write("done\n");
EOF
) || status=$?
  expect_code 0 "$status" "omp watch extension armed under a foreign session lock" "$out"
  pass "omp watch extension refuses to arm when another session holds the lock"
}

test_watch_extension_is_process_scoped_not_session_scoped() {
  local out status=0
  # omp emits no session_start/session_shutdown for a same-process replacement, so
  # the watch extension must not depend on either to own its cycle. It may listen
  # for session_shutdown to retire on terminal quit, but a session_start handler
  # would encode a generation model omp never signals.
  out=$(grep -n 'on?\?\.\?("session_start"' "$WATCH_EXT" || true)
  [ -z "$out" ] \
    || fail "the omp watch extension registered session_start, which omp never fires for a session replacement: $out"
  status=$(grep -c 'on?\?\.\?("session_shutdown"' "$WATCH_EXT" || true)
  [ "$status" -eq 1 ] \
    || fail "the omp watch extension must retire its arm child on terminal shutdown (matches: $status)"
  pass "omp watch extension owns one process-scoped cycle rather than a per-session generation"
}

test_extensions_never_import_pi_vendor_modules() {
  # Typing an omp extension with Pi's ExtensionAPI describes Pi's events, not
  # omp's, and importing Pi's TUI would tie omp to a presentation layer it has no
  # Firstmate extension for. Both are how a Pi shape gets re-borrowed by accident.
  local ext
  for ext in "$GUARD_EXT" "$WATCH_EXT"; do
    grep -q 'from "@earendil-works/' "$ext" \
      && fail "$(basename "$ext") imports a Pi vendor module"
  done
  pass "the omp extensions declare omp's surface themselves instead of importing Pi's"
}

test_turnend_guard_blocks_the_stop_and_forwards_stop_hook_active
test_turnend_guard_allows_a_healthy_stop
test_turnend_guard_writes_only_omps_own_marker
test_sessionstart_nudge_is_encoded_and_source_derived
test_sessionstart_nudge_skips_an_empty_digest
test_tool_call_seatbelt_blocks_a_denied_command
test_watch_extension_wake_carries_no_options_object
test_watch_extension_refuses_a_foreign_session_lock
test_watch_extension_is_process_scoped_not_session_scoped
test_extensions_never_import_pi_vendor_modules
