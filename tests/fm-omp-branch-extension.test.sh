#!/usr/bin/env bash
# Portable contract tests for the tracked omp supervision-branch extension
# (.omp/extensions/fm-branch-supervision.ts).
#
# These pin the facts that separate omp's branch from Pi's, because Pi's file
# LOADS on omp and is silently inert there, and because omp has no agent_settled
# event at all:
#
#   - the merge gate is the agent_settled SUBSTITUTE (agent_end + willContinue +
#     ctx.isIdle() + ctx.hasPendingMessages()), and a note must NOT be delivered
#     inside the willContinue continuation window;
#   - ownership is PROCESS-scoped, so a same-process session replacement must
#     neither retire the cycle nor need re-arming;
#   - markers and session state are .omp-rooted, never Pi's;
#   - every branch failure degrades to the pre-branch wake-to-main path.
#
# The omp SDK is stubbed (scriptable in-process sessions); every fleet-record
# behavior runs the REAL bin scripts. The harness fact the stub cannot prove -
# that the installed omp really has these primitives and really has no
# agent_settled - is proven by tests/fm-omp-branch-capability.test.sh against a
# real omp.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-branch-extension)
EXT="$ROOT/.omp/extensions/fm-branch-supervision.ts"
export NODE_NO_WARNINGS=1

# Keep JavaScript heredocs outside command substitutions. Stock macOS Bash 3.2
# reparses quotes and template literals inside that combination.
install_omp_branch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.omp/extensions" \
    "$repo/.pi/extensions/lib" \
    "$repo/bin" \
    "$repo/node_modules/@oh-my-pi/pi-coding-agent"
  cp "$EXT" "$repo/.omp/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@oh-my-pi/pi-coding-agent/package.json" <<'JSON'
{"name":"@oh-my-pi/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@oh-my-pi/pi-coding-agent/index.js" <<'JS'
import { writeFileSync } from "node:fs";

export class SessionManager {
  constructor(file) {
    this.file = file;
  }
  static create(cwd, dir) {
    globalThis.__fmCreateCount = (globalThis.__fmCreateCount ?? 0) + 1;
    const sm = new SessionManager(`${dir}/created-${globalThis.__fmCreateCount}.jsonl`);
    sm.created = true;
    writeFileSync(sm.file, "");
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  static open(path) {
    const sm = new SessionManager(path);
    sm.opened = true;
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  getSessionFile() {
    return this.file;
  }
}

export async function createAgentSession(options) {
  if (globalThis.__fmCreateSessionError) throw new Error(globalThis.__fmCreateSessionError);
  const session = {
    options,
    ops: [],
    disposed: false,
    async prompt(text) {
      if (globalThis.__fmPromptGate) {
        globalThis.__fmPromptStarted = true;
        await globalThis.__fmPromptGate;
      }
      session.ops.push({ kind: "prompt", text });
      (globalThis.__fmPrompts ??= []).push(text);
    },
    async sendCustomMessage(message, opts) {
      if (globalThis.__fmMirrorGate) {
        globalThis.__fmMirrorStarted = true;
        await globalThis.__fmMirrorGate;
      }
      session.ops.push({ kind: "custom", message, opts });
      (globalThis.__fmMirrors ??= []).push(message);
    },
    dispose() {
      session.disposed = true;
    },
  };
  (globalThis.__fmSessions ??= []).push(session);
  // Run the inline extension factories the way omp does, against a
  // branch-scoped API, so the actor-identity tool_call handler is observable.
  const branchHandlers = new Map();
  for (const entry of options.extensions ?? []) {
    entry.factory({
      on(event, handler) {
        branchHandlers.set(event, handler);
      },
    });
  }
  session.branchHandlers = branchHandlers;
  return { session, extensionsResult: {}, eventBus: {} };
}
JS
}

# Shared driver preamble: a fake main-session omp ExtensionAPI. The event bus
# mirrors omp's EventBus, which wraps each handler in an async function - so the
# handler's body up to its first await runs synchronously inside emit(), which
# is what makes the offer handshake's post-emit accepted read valid.
DRIVER_PRELUDE=$(cat <<'JS'
const { spawnSync } = await import("node:child_process");
const { mkdirSync, writeFileSync } = await import("node:fs");
const { pathToFileURL } = await import("node:url");

const home = process.env.FM_HOME;
const realRoot = process.env.FM_ROOT_OVERRIDE;
const approvedProject = `${home}/projects/approved`;
mkdirSync(`${home}/state`, { recursive: true });
mkdirSync(`${home}/config`, { recursive: true });
mkdirSync(approvedProject, { recursive: true });
writeFileSync(`${home}/state/branch-driver.meta`, `project=${approvedProject}\nwindow=fm-branch-driver\n`);
if (!process.env.FM_TEST_SKIP_LOCK) {
  writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
}

const busHandlers = new Map();
const bus = {
  on(channel, handler) {
    const safeHandler = async (data) => {
      await handler(data);
    };
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), safeHandler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
  },
};
const piHandlers = new Map();
const sentToMain = [];
const mainUserMessages = [];
const mainTools = [];
const timers = [];
// The settle context main hands to every lifecycle handler. Tests drive
// streaming and queue state through these two flags directly.
const mainState = { idle: true, pending: false, entries: [], file: `${home}/state/main-session.jsonl` };
const ctx = {
  isIdle: () => mainState.idle,
  hasPendingMessages: () => mainState.pending,
  sessionManager: {
    getSessionFile: () => mainState.file,
    getEntries: () => mainState.entries,
  },
  setInterval(callback, ms) {
    const timer = { callback, ms };
    timers.push(timer);
    return timer;
  },
};
const pi = {
  typebox: {
    Type: {
      Object(properties, options) {
        return { type: "object", properties, ...(options ?? {}) };
      },
      String(options) {
        return { type: "string", ...(options ?? {}) };
      },
      Number(options) {
        return { type: "number", ...(options ?? {}) };
      },
      Boolean(options) {
        return { type: "boolean", ...(options ?? {}) };
      },
      Optional(schema) {
        return { ...schema, optional: true };
      },
      Literal(value) {
        return { const: value };
      },
      Union(schemas, options) {
        return { anyOf: schemas, ...(options ?? {}) };
      },
    },
  },
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool(tool) {
    mainTools.push(tool);
  },
  sendMessage(message, options) {
    sentToMain.push({ message, options: options ?? {} });
  },
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
  },
};
function fire(event, payload) {
  for (const handler of piHandlers.get(event) ?? []) handler(payload, ctx);
}
// Main starts one streaming run.
function mainStarts() {
  mainState.idle = false;
  fire("agent_start", { type: "agent_start" });
}
// Main's run ends. willContinue mirrors omp's own "a continuation is already
// scheduled" flag; idle/pending mirror ctx.isIdle()/ctx.hasPendingMessages().
function mainEnds({ willContinue = false, idle = true, pending = false } = {}) {
  mainState.idle = idle;
  mainState.pending = pending;
  fire("agent_end", { type: "agent_end", ...(willContinue ? { willContinue: true } : {}) });
}
function runTimers() {
  for (const timer of timers) timer.callback();
}
function makeOffer(message, projects = [approvedProject], heartbeat = false, eligible = projects.length > 0 || heartbeat) {
  const offer = {
    message,
    projects,
    heartbeat,
    eligible,
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}
function dispatch(message, projects, heartbeat, eligible) {
  const offer = makeOffer(message, projects, heartbeat, eligible);
  if (offer.eligible) {
    const row = offer.heartbeat
      ? "1\t1\theartbeat\theartbeat\theartbeat\n"
      : `1\t1\tsignal\tbranch-driver.status\t${message}\n`;
    writeFileSync(`${home}/state/.wake-queue`, row);
  }
  bus.emit("fm-branch-supervision:dispatch", offer);
  return offer;
}
async function settle(predicate, label) {
  for (let i = 0; i < 250; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}
async function quiesce() {
  for (let i = 0; i < 20; i += 1) await new Promise((resolve) => setTimeout(resolve, 5));
}
function outcomeScript(args) {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-branch-outcome.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-branch-outcome.sh ${args.join(" ")} failed: ${result.stderr}`);
  return (result.stdout || "").trim();
}
function branchTool(name) {
  const session = (globalThis.__fmSessions ?? [])[0];
  if (!session) throw new Error("branch session was never created");
  const tool = (session.options.customTools ?? []).find((entry) => entry.name === name);
  if (!tool) throw new Error(`branch tool ${name} was not registered`);
  return tool;
}
async function report(params) {
  return branchTool("fm_branch_report").execute("call-1", params);
}
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
JS
)

# The settled-boundary test. This is the one that would pass on a naive
# substitute, so it deliberately drives the failing case first: a note produced
# while main is inside the willContinue continuation window must NOT reach main
# until the terminal agent_end. A substitute that fired on any agent_end, or
# that only checked isIdle(), delivers during step 2 and fails here.
test_settled_boundary_holds_notes_through_automatic_continuation() {
  local repo home out status
  repo="$TMP_ROOT/settle-root"
  home="$TMP_ROOT/settle-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, quiesce, outcomeScript, report, mainStarts, mainEnds, runTimers, sentToMain, home }; })()`);
const { dispatch, settle, quiesce, outcomeScript, report, mainStarts, mainEnds, runTimers, sentToMain, home } = globalThis.__t;
import { writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

// Bring the branch up so its report tool exists.
const offer = dispatch("signal: task-4 done");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");

// 1. Main takes a turn.
mainStarts();

// 2. The turn ends with an automatic continuation already scheduled. omp is
// momentarily NOT streaming here, so every delivery mode would append the note
// straight into the continuation's context. Nothing may be delivered.
mainEnds({ willContinue: true, idle: true, pending: false });
const midContinuation = await report({ task: "task-4", verdict: "routine", summary: "rebased and pushed" });
if (midContinuation.isError) throw new Error(`report refused mid-continuation: ${JSON.stringify(midContinuation)}`);
await quiesce();
if (sentToMain.length !== 0) {
  throw new Error(`merge note landed mid-continuation: ${JSON.stringify(sentToMain)}`);
}
// The outcome is durable but deliberately still UNREAD, so nothing is lost if
// the process dies inside the continuation window.
if (outcomeScript(["list", "--recent", "5"]).indexOf("rebased and pushed") === -1) {
  throw new Error("held note was not durably recorded before the merge");
}

// 3. A queued follow-up would start another turn on its own, so a settle that
// only checked isIdle() would release here. It must not.
mainEnds({ willContinue: false, idle: true, pending: true });
await quiesce();
if (sentToMain.length !== 0) {
  throw new Error(`merge note landed while queued work was still pending: ${JSON.stringify(sentToMain)}`);
}

// 4. Still streaming is not settled either.
mainEnds({ willContinue: false, idle: false, pending: false });
await quiesce();
if (sentToMain.length !== 0) {
  throw new Error(`merge note landed while main was still streaming: ${JSON.stringify(sentToMain)}`);
}

// 5. The terminal settle releases it, exactly once, as a routine note.
mainEnds({ willContinue: false, idle: true, pending: false });
await settle(() => sentToMain.length === 1, "merge note after the terminal settle");
await quiesce();
if (sentToMain.length !== 1) throw new Error(`note delivered more than once: ${JSON.stringify(sentToMain)}`);
const routine = sentToMain[0];
if (!routine.message.content.startsWith("⛵ task-4:")) {
  throw new Error(`routine note lost its visible marker: ${JSON.stringify(routine.message)}`);
}
if (routine.message.display !== true) throw new Error("routine note must render for the operator");
// Routine merges take omp's idle no-turn append: no triggerTurn, and no
// deliverAs, so the note can never enter the pending-next-turn queue and
// poison hasPendingMessages() for the next settle decision.
if (Object.keys(routine.options).length !== 0) {
  throw new Error(`routine merge must carry no options: ${JSON.stringify(routine.options)}`);
}
// Only now may the outcome store's read cursor advance.
if (outcomeScript(["list", "--recent", "5"]).indexOf("rebased and pushed") === -1) {
  throw new Error("delivered outcome vanished from the store");
}

// 6. A captain-relevant note opens exactly one follow-up turn and is delivered
// silently, because that turn is itself the captain-visible artefact.
const captain = await report({ task: "task-4", verdict: "captain", summary: "needs a credential decision" });
if (captain.isError) throw new Error(`captain report refused: ${JSON.stringify(captain)}`);
await settle(() => sentToMain.length === 2, "captain merge note");
const escalation = sentToMain[1];
if (escalation.options.triggerTurn !== true || escalation.options.deliverAs !== "followUp") {
  throw new Error(`captain note must take one follow-up turn: ${JSON.stringify(escalation.options)}`);
}
if (escalation.message.display !== false) {
  throw new Error("captain note must be delivered silently; the follow-up turn is the visible artefact");
}
// What main's model actually receives is the delivered payload, not the
// delivery options. Pinning only the options is precisely what let the stale
// re-emission defect through on the Pi side, so write both notes out for the
// real protocol executable to classify below.
writeFileSync(`${home}/state/delivered-captain-note`, escalation.message.content);
writeFileSync(`${home}/state/delivered-routine-note`, sentToMain[0].message.content);

// 7. The bounded sweep only ever RELEASES a held note; it must never deliver
// one while main is unsettled.
mainStarts();
const heldDuringStream = await report({ task: "task-4", verdict: "routine", summary: "held for the sweep" });
if (heldDuringStream.isError) throw new Error("report refused while main streamed");
await quiesce();
runTimers();
await quiesce();
if (sentToMain.length !== 2) {
  throw new Error(`sweep released a note while main was unsettled: ${JSON.stringify(sentToMain)}`);
}
// Once main really is idle with nothing queued, the sweep releases it even
// though no further agent_end ever arrives.
globalThis.__t.pi;
mainEnds({ willContinue: true, idle: true, pending: false });
await quiesce();
if (sentToMain.length !== 2) throw new Error("continuation window released the swept note early");
runTimers();
await settle(() => sentToMain.length === 3, "sweep release once main is genuinely idle");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the agent_settled substitute must hold notes through an automatic continuation: $out"
  pass "merge notes are held through willContinue, queued work, and streaming, then released once"

  # The delivered captain payload must identify itself to main's model. When it
  # did not, main could not tell an incoming outcome from its own earlier answer
  # and re-emitted that answer instead of relaying the outcome, silently losing
  # it. The real protocol executable is the oracle here: it decides the kind and
  # extracts the body, so this asserts delivered behavior rather than a shape
  # this test already knows.
  local kind body
  kind=$(./bin/fm-operational-input.sh kind < "$home/state/delivered-captain-note") \
    || fail "captain outcome reaches main's model as unattributed text the model cannot tell from its own answer"
  [ "$kind" = branch-outcome ] \
    || fail "captain outcome delivered as kind '$kind', not branch-outcome"
  body=$(./bin/fm-operational-input.sh body < "$home/state/delivered-captain-note") \
    || fail "captain outcome envelope carries no readable body"
  case "$body" in
    *"task-4: needs a credential decision"*) ;;
    *) fail "captain outcome body lost the outcome itself: $body" ;;
  esac
  case "$body" in
    *"Relay only this outcome"*"Do not restate or repeat any earlier answer"*) ;;
    *) fail "captain outcome body never tells main to relay it instead of repeating: $body" ;;
  esac
  # The routine note is rendered in the TUI, and its renderer reads the glyph off
  # the front of this same string, so it must stay plain text.
  if ./bin/fm-operational-input.sh kind < "$home/state/delivered-routine-note" >/dev/null 2>&1; then
    fail "routine note must stay plain rendered text, not typed operational input"
  fi
  pass "an omp captain outcome reaches main's model as typed, self-describing input while routine notes stay plain"
}

test_omp_branch_dispatch_gating_and_prefix_contract() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-root"
  home="$TMP_ROOT/dispatch-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, quiesce, mainTools, mainUserMessages, home }; })()`);
const { dispatch, settle, quiesce, mainTools, mainUserMessages, home } = globalThis.__t;
import { existsSync, writeFileSync, unlinkSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

// 1. An accepted wake reaches the branch session, never main.
const offer = dispatch("signal: task-9 done: PR https://example.com/pr/9 checks green");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
if (!globalThis.__fmPrompts[0].includes("FIRSTMATE SUPERVISION WAKE: signal: task-9 done")) {
  throw new Error(`branch prompt lost the wake reason: ${globalThis.__fmPrompts[0]}`);
}
if (mainUserMessages.length !== 0) throw new Error("accepted wake leaked to main as a user message");

// 2. Prefix stability and resource isolation, expressed through omp's own
// createAgentSession options rather than Pi's DefaultResourceLoader.
const session = globalThis.__fmSessions[0];
const options = session.options;
if (JSON.stringify(options.toolNames) !== JSON.stringify(["read", "bash", "fm_branch_report"])) {
  throw new Error(`unexpected tool order: ${JSON.stringify(options.toolNames)}`);
}
if (options.restrictToolNames !== true || options.allowRestrictedCustomTools !== true) {
  throw new Error("branch tool set must be restricted to the named tools plus its own custom tools");
}
// disableExtensionDiscovery is the recursion guard: without it the branch would
// discover this very file and spawn a branch of its own.
if (options.disableExtensionDiscovery !== true) throw new Error("branch must not discover project extensions");
for (const key of ["skills", "rules", "contextFiles", "promptTemplates", "slashCommands"]) {
  if (!Array.isArray(options[key]) || options[key].length !== 0) {
    throw new Error(`branch must load no ${key}`);
  }
}
for (const key of ["enableMCP", "enableLsp", "enableIrc", "hasUI"]) {
  if (options[key] !== false) throw new Error(`branch must set ${key} false`);
}
if (!options.systemPrompt || !options.systemPrompt.startsWith("You are the SUPERVISION BRANCH")) {
  throw new Error("branch system prompt is not the generator's output");
}
if (options.systemPrompt.length < 4096) throw new Error("branch prompt is below the provider caching minimum");
// providerPromptCacheKey is a first-class omp option, so no
// before_provider_request hook is needed to keep the per-home key stable.
if (!/^fm-branch-[0-9a-f]{24}$/.test(options.providerPromptCacheKey)) {
  throw new Error(`unexpected cache key: ${options.providerPromptCacheKey}`);
}
if (options.providerPromptCacheKeySource !== "explicit") {
  throw new Error("the per-home cache key must be caller-pinned, not inherited");
}

// 3. The branch actor identity is injected natively through tool_call, because
// omp's compat shim maps Pi's spawnHook onto shellEnv and DISCARDS the hook's
// rewritten command - Pi's readonly prelude would be silently dropped here.
const toolCall = session.branchHandlers.get("tool_call");
if (!toolCall) throw new Error("branch registered no tool_call handler for the actor identity");
const revised = toolCall({ toolName: "bash", input: { command: "bin/fm-lease.sh claim task-9" } });
if (!revised || typeof revised.input?.command !== "string") {
  throw new Error(`tool_call did not revise the bash input: ${JSON.stringify(revised)}`);
}
if (!revised.input.command.includes("FM_SUPERVISION_ACTOR=branch")) {
  throw new Error("branch bash does not carry the branch actor identity");
}
if (!revised.input.command.includes("readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID")) {
  throw new Error("branch bash lost the loud accidental-override guard");
}
if (!revised.input.command.includes("bin/fm-lease.sh claim task-9")) {
  throw new Error("branch bash lost the original command");
}
if (toolCall({ toolName: "read", input: { path: "x" } }) !== undefined) {
  throw new Error("the actor identity must revise bash only");
}

// 4. omp's OWN marker, never Pi's. Pi's extensions load on omp and are inert
// there, so an omp primary must never answer an ownership question with a
// marker a disarmed session wrote.
if (!existsSync(`${home}/state/.omp-branch-extension-loaded`)) {
  throw new Error("omp branch extension did not write its own loaded marker");
}
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("omp branch extension wrote Pi's marker");
}

// 5. Main keeps the outcomes tool.
if (!mainTools.some((tool) => tool.name === "fm_branch_outcomes")) {
  throw new Error("fm_branch_outcomes was not registered on main");
}

// 6. The refusal ladder. Each rung must leave the wake to main untouched.
if (dispatch("check: unresolved fleet event", []).accepted) {
  throw new Error("branch accepted an ineligible offer");
}
writeFileSync(`${home}/state/.afk`, "");
if (dispatch("signal: task-9 done again").accepted) {
  throw new Error("branch accepted a wake while away mode was active");
}
unlinkSync(`${home}/state/.afk`);
if (!dispatch("signal: task-9 done a third time").accepted) {
  throw new Error("branch stopped accepting after away mode cleared");
}
await quiesce();
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "omp branch dispatch gating and prefix contract: $out"
  pass "the omp branch isolates itself through omp's own session options and declines out-of-scope wakes"
}

test_omp_branch_failures_fall_back_to_main() {
  local repo home out status
  repo="$TMP_ROOT/fallback-root"
  home="$TMP_ROOT/fallback-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle, quiesce, mainUserMessages, home }; })()`);
const { dispatch, settle, quiesce, mainUserMessages, home } = globalThis.__t;
import { writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

// A branch that cannot be created returns the wake to MAIN rather than dropping
// it - the whole point of the design's failure direction.
globalThis.__fmCreateSessionError = "no model configured";
const offer = dispatch("signal: task-3 needs review");
if (!offer.accepted) throw new Error("branch declined before it had a chance to fail");
await settle(() => mainUserMessages.length === 1, "fallback wake on main");
const fallback = mainUserMessages[0];
if (!fallback.content.includes("FIRSTMATE WATCHER WAKE: signal: task-3 needs review")) {
  throw new Error(`fallback lost the wake reason: ${fallback.content}`);
}
if (!fallback.content.includes("Supervision branch unavailable")) {
  throw new Error("fallback did not say why it fell back");
}
// NO options object: omp's deliverAs "followUp" only QUEUES, so copying Pi's
// call here would produce a fallback wake that never fires.
if (Object.keys(fallback.options).length !== 0) {
  throw new Error(`omp fallback wake must carry no options: ${JSON.stringify(fallback.options)}`);
}

// Once broken, later wakes are declined outright so they take the pre-branch
// wake-to-main path instead of retrying a dead branch.
if (dispatch("signal: task-3 needs review again").accepted) {
  throw new Error("a broken branch kept accepting wakes");
}
await quiesce();
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "branch failures must degrade to the pre-branch wake-to-main path: $out"
  pass "a branch that cannot be created returns the wake to main and then declines"
}

# The pathology this fork already hit once: binding a generation to a session
# lifecycle event on omp. omp emits NOTHING for a same-process replacement, so a
# /new must leave the cycle alone, and the mirror must re-key itself off the
# session FILE rather than off an event that never arrives.
test_omp_branch_cycle_is_process_scoped_across_a_replacement() {
  local repo home out status
  repo="$TMP_ROOT/procscope-root"
  home="$TMP_ROOT/procscope-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, quiesce, home }; })()`);
const { pi, fire, dispatch, settle, quiesce, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

const first = dispatch("signal: task-1 done");
if (!first.accepted) throw new Error("branch did not accept the first wake");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "first branch wake");
const branchSession = globalThis.__fmSessions[0];

// Mirror one exchange of the current main session.
const ctxState = { file: `${home}/state/main-session.jsonl` };
fire("turn_end", { type: "turn_end" });
await quiesce();

// A /new on omp: the session file changes and NO lifecycle event fires. The
// cycle must survive, the branch session must not be disposed, and the next
// wake must still be accepted without any re-arming.
const second = dispatch("signal: task-2 done");
if (!second.accepted) throw new Error("a same-process session replacement retired the supervision cycle");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "second branch wake after a replacement");
if (branchSession.disposed) throw new Error("a same-process replacement disposed the branch session");
if (globalThis.__fmSessions.length !== 1) {
  throw new Error(`a replacement re-created the branch: ${globalThis.__fmSessions.length} sessions`);
}

// Terminal quit is the only thing that retires it.
fire("session_shutdown", { type: "session_shutdown" });
await quiesce();
if (!branchSession.disposed) throw new Error("terminal shutdown did not dispose the branch session");
if (dispatch("signal: task-3 done").accepted) {
  throw new Error("branch accepted a wake after terminal shutdown");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the omp supervision cycle must belong to the process, not the conversation: $out"
  pass "a same-process session replacement neither retires the cycle nor re-creates the branch"
}

test_omp_branch_mirror_filters_and_advances_its_own_cursor() {
  local repo home out status
  repo="$TMP_ROOT/mirror-root"
  home="$TMP_ROOT/mirror-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, quiesce, home, mainState }; })()`);
const { fire, dispatch, settle, quiesce, home, mainState } = globalThis.__t;
import { existsSync, readFileSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);

const offer = dispatch("signal: task-6 done");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");

const message = (role, text) => ({ type: "message", message: { role, content: [{ type: "text", text }] } });
mainState.entries = [
  message("user", "standing order: never merge task-7"),
  message("assistant", "understood, task-7 stays open"),
  // Operational injections are fleet machinery, not captain dialog; mirroring
  // them would feed the branch its own supervision traffic back.
  message("user", "\u2063FIRSTMATE WATCHER WAKE: signal: task-6 done"),
  message("user", "FIRSTMATE SESSION START"),
  message("assistant", "   "),
  { type: "toolResult" },
];
fire("turn_end", { type: "turn_end" });
await settle(() => (globalThis.__fmMirrors ?? []).length === 2, "mirrored dialog");
const mirrored = globalThis.__fmMirrors.map((m) => m.content);
if (JSON.stringify(mirrored) !== JSON.stringify([
  "[captain] standing order: never merge task-7",
  "[main] understood, task-7 stays open",
])) {
  throw new Error(`unexpected mirror contents: ${JSON.stringify(mirrored)}`);
}
for (const entry of globalThis.__fmMirrors) {
  if (entry.display !== false) throw new Error("mirrored dialog must be read-only context, never displayed");
}

// The durable cursor is .omp-rooted and advances only after delivery.
const cursorFile = `${home}/state/.omp-branch-mirror-cursor`;
if (!existsSync(cursorFile)) throw new Error("omp branch mirror cursor was not written");
if (existsSync(`${home}/state/.branch-mirror-cursor`)) {
  throw new Error("omp branch wrote Pi's mirror cursor");
}
const cursor = JSON.parse(readFileSync(cursorFile, "utf8"));
if (cursor.index !== mainState.entries.length) throw new Error(`cursor did not advance: ${JSON.stringify(cursor)}`);

// A second turn_end with nothing new mirrors nothing.
fire("turn_end", { type: "turn_end" });
await quiesce();
if (globalThis.__fmMirrors.length !== 2) throw new Error("re-mirrored already delivered dialog");

// A same-process replacement changes the session FILE, which re-mirrors the new
// session from its start with no lifecycle event involved.
mainState.file = `${home}/state/main-session-2.jsonl`;
mainState.entries = [message("user", "new session, first order")];
fire("turn_end", { type: "turn_end" });
await settle(() => globalThis.__fmMirrors.length === 3, "mirror after a session replacement");
if (globalThis.__fmMirrors[2].content !== "[captain] new session, first order") {
  throw new Error(`replacement mirror wrong: ${globalThis.__fmMirrors[2].content}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "omp branch mirror filtering and cursor: $out"
  pass "the mirror filters operational traffic and re-keys itself on the session file"
}

test_omp_branch_stays_inert_without_lock_ownership() {
  local repo home out status
  repo="$TMP_ROOT/inert-root"
  home="$TMP_ROOT/inert-home"
  mkdir -p "$home/state" "$home/config"
  install_omp_branch_extension_fixture "$repo"
  PLUGIN="$repo/.omp/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SKIP_LOCK=1 DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, quiesce, mainUserMessages, home }; })()`);
const { fire, dispatch, quiesce, mainUserMessages, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

// A secondary, read-only omp session: the lock names a live process that is not
// in this process's ancestry. It must write no markers and accept no wakes.
writeFileSync(`${home}/state/.lock`, `1\n`);
if (dispatch("signal: task-5 done").accepted) {
  throw new Error("a session that does not own the fleet lock accepted a wake");
}
fire("turn_end", { type: "turn_end" });
await quiesce();
if (existsSync(`${home}/state/.omp-branch-extension-loaded`)) {
  throw new Error("a non-owning session wrote the loaded marker");
}
if ((globalThis.__fmSessions ?? []).length !== 0) throw new Error("a non-owning session created a branch");
if (mainUserMessages.length !== 0) throw new Error("a declined wake was injected into main by the branch");

// Cold start: the lock arrives later, exactly as it does when the session runs
// bin/fm-session-start.sh. Ownership is re-read lazily, so the branch engages
// without any re-arming.
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
if (!dispatch("signal: task-5 done now").accepted) {
  throw new Error("the branch stayed inert after acquiring the fleet lock");
}
await quiesce();
if (!existsSync(`${home}/state/.omp-branch-extension-loaded`)) {
  throw new Error("acquiring the lock did not activate the branch");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a non-owning omp session must stay inert: $out"
  pass "the branch stays inert without lock ownership and engages lazily once it arrives"
}

test_settled_boundary_holds_notes_through_automatic_continuation
test_omp_branch_dispatch_gating_and_prefix_contract
test_omp_branch_failures_fall_back_to_main
test_omp_branch_cycle_is_process_scoped_across_a_replacement
test_omp_branch_mirror_filters_and_advances_its_own_cursor
test_omp_branch_stays_inert_without_lock_ownership
