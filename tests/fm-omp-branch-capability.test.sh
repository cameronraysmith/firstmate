#!/usr/bin/env bash
# Opt-in capability probe for omp supervision-branch support, run against the
# omp binary actually INSTALLED on this host.
#
# Why this is a live guard rather than a portable test. Every fact below is
# harness-dependent: it is a property of the omp build in $PATH, and a stub can
# only confirm the assumption already written into the stub. omp also ships as a
# compiled binary with no npm declarations to type-check against, and reading
# its bytes would be asserting implementation source rather than behavior. So
# this probe loads a real extension into a real omp session and reports what the
# API it is handed actually does.
#
# It is designed to FAIL. Four of its assertions are positive capability claims
# that .omp/extensions/fm-branch-supervision.ts depends on, and one is a
# NEGATIVE claim - that omp emits no agent_settled event - which is the whole
# reason that file carries an agent_settled substitute at all. If a future omp
# gains the event, this probe fails and the substitute gets revisited instead of
# quietly rotting beside a native alternative.
#
# Refreshes the omp row of docs/verification/runtime-backends.md.
set -u

if [ "${FM_OMP_BRANCH_CAPABILITY:-0}" != 1 ]; then
  echo "skip: set FM_OMP_BRANCH_CAPABILITY=1 to probe the installed omp for branch-supervision support"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Report an absent harness explicitly rather than passing silently over it: a
# probe that checked nothing must never read as a pass.
command -v omp >/dev/null 2>&1 || fail "omp not found; this probe cannot pass without the harness it measures"
OMP_VERSION=$(omp --version 2>&1 | head -1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-branch-capability.XXXXXX")
cleanup() {
  if [ "${FM_OMP_BRANCH_CAPABILITY_KEEP:-0}" = 1 ]; then
    printf 'lab retained at %s\n' "$LAB" >&2
    return 0
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

PROJECT="$LAB/project"
REPORT="$LAB/report.json"
mkdir -p "$PROJECT/.omp/extensions"

printf 'probing omp %s\n' "$OMP_VERSION"

# The probe extension. It records what the live API exposes, then writes one
# JSON report at the terminal settle. Everything it asserts is something the
# tracked branch extension actually calls.
cat > "$PROJECT/.omp/extensions/fm-capability-probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import * as omp from "@oh-my-pi/pi-coding-agent";

const reportPath = process.env.FM_PROBE_REPORT as string;
const seen: Record<string, unknown> = {
  // Pillar 1: a persistent second in-process session.
  createAgentSession: typeof (omp as Record<string, unknown>).createAgentSession,
  SessionManager: typeof (omp as Record<string, unknown>).SessionManager,
  // The gap. This must stay 0: the substitute in
  // .omp/extensions/fm-branch-supervision.ts exists only because omp has no
  // such event, and it must be revisited the day omp gains one.
  agentSettledFired: 0,
  agentEndFired: 0,
  agentEndCarriesWillContinueProperty: false,
  // Pillar 3 and the settle signals.
  isIdle: "absent",
  hasPendingMessages: "absent",
  setInterval: "absent",
  sessionManagerOnContext: "absent",
  // Pillar 2 and the offer handshake.
  sendMessage: "absent",
  eventBusSynchronousThroughAccept: false,
  branchCreated: false,
  branchAcceptedPromptCacheKey: false,
  branchToolNamesRestricted: false,
  sendCustomMessageStartedNoTurn: null as boolean | null,
  branchError: "",
};

function flush(): void {
  writeFileSync(reportPath, `${JSON.stringify(seen, null, 2)}\n`);
}

export default function (pi: any) {
  seen.sendMessage = typeof pi.sendMessage;

  // The offer handshake depends on omp's EventBus invoking a handler
  // synchronously up to its first await, so a post-emit read of a flag the
  // handler set is a valid decision.
  const offer = { accepted: false, accept() { offer.accepted = true; } };
  pi.events.on("fm-capability-probe:offer", (data: any) => {
    data.accept();
  });
  pi.events.emit("fm-capability-probe:offer", offer);
  seen.eventBusSynchronousThroughAccept = offer.accepted === true;

  pi.on("agent_settled", () => {
    seen.agentSettledFired = (seen.agentSettledFired as number) + 1;
    flush();
  });

  pi.on("agent_start", async (_event: unknown, ctx: any) => {
    seen.isIdle = typeof ctx.isIdle;
    seen.hasPendingMessages = typeof ctx.hasPendingMessages;
    seen.setInterval = typeof ctx.setInterval;
    seen.sessionManagerOnContext = typeof ctx.sessionManager?.getEntries;

    // Build the branch exactly the way the tracked extension does: full
    // isolation through omp's own createAgentSession options, a first-class
    // providerPromptCacheKey, and no Pi compat-shim types anywhere.
    try {
      const created = await (omp as any).createAgentSession({
        cwd: process.env.FM_PROBE_PROJECT,
        systemPrompt: "You are a capability probe. Answer nothing.",
        providerPromptCacheKey: "fm-branch-capability-probe",
        providerPromptCacheKeySource: "explicit",
        disableExtensionDiscovery: true,
        skills: [],
        rules: [],
        contextFiles: [],
        promptTemplates: [],
        slashCommands: [],
        enableMCP: false,
        enableLsp: false,
        enableIrc: false,
        hasUI: false,
        toolNames: ["read"],
        restrictToolNames: true,
        allowRestrictedCustomTools: true,
      });
      const branch = created.session;
      seen.branchCreated = typeof branch?.sendCustomMessage === "function";
      seen.branchAcceptedPromptCacheKey = true;
      seen.branchToolNamesRestricted = true;
      if (seen.branchCreated) {
        // Turn-free bidirectional injection: an idle session with no options
        // object must append the message and start no model turn. omp's
        // sendCustomMessage returns true only when it synchronously started a
        // turn, so false here IS the turn-free guarantee.
        const startedTurn = await branch.sendCustomMessage(
          { customType: "fm-probe-mirror", content: "[captain] probe", display: false },
          {},
        );
        seen.sendCustomMessageStartedNoTurn = startedTurn === false;
      }
      await branch?.dispose?.();
    } catch (error) {
      seen.branchError = error instanceof Error ? error.message : String(error);
    }
    flush();
  });

  pi.on("agent_end", (event: any) => {
    seen.agentEndFired = (seen.agentEndFired as number) + 1;
    // willContinue is omp's own "an automatic continuation is already
    // scheduled" flag - the signal the substitute is built on. The property
    // must be PRESENT on the event shape even when this settle is terminal,
    // because an absent property and a false one would be indistinguishable to
    // the substitute and it would silently degrade to "every agent_end is
    // terminal".
    if (event && "willContinue" in event) seen.agentEndCarriesWillContinueProperty = true;
    flush();
  });

  flush();
}
TS
# One real non-interactive turn against the operator's own omp credentials.
# --no-session keeps it from writing session state; the prompt is deliberately
# trivial because the probe measures the API, not the model.
(
  cd "$PROJECT" || exit 1
  FM_PROBE_REPORT="$REPORT" FM_PROBE_PROJECT="$PROJECT" \
    omp -p "Reply with the single word: ok" \
    --no-session \
    --no-skills \
    --no-rules \
    --no-lsp \
    --no-extensions \
    -e "$PROJECT/.omp/extensions/fm-capability-probe.ts" \
    > "$LAB/omp-stdout" 2> "$LAB/omp-stderr"
) || true

[ -f "$REPORT" ] || {
  printf 'omp stdout:\n' >&2
  cat "$LAB/omp-stdout" >&2 2>/dev/null || true
  printf 'omp stderr:\n' >&2
  cat "$LAB/omp-stderr" >&2 2>/dev/null || true
  fail "the probe extension never ran under omp $OMP_VERSION"
}

command -v jq >/dev/null 2>&1 || fail "jq not found; the probe report cannot be checked"

probe() {
  jq -r "$1" "$REPORT"
}

expect() {
  local label=$1 query=$2 want=$3 got
  got=$(probe "$query")
  if [ "$got" != "$want" ]; then
    printf 'probe report:\n' >&2
    cat "$REPORT" >&2
    fail "omp $OMP_VERSION: $label (expected $want, got $got)"
  fi
  printf 'ok - omp %s: %s\n' "$OMP_VERSION" "$label"
}

# Pillar 1 - a persistent second in-process session.
expect "createAgentSession is exported from @oh-my-pi/pi-coding-agent" '.createAgentSession' 'function'
expect "SessionManager is exported from @oh-my-pi/pi-coding-agent" '.SessionManager' 'function'
expect "a fully isolated branch session can be created" '.branchCreated' 'true'
expect "createAgentSession accepts a caller-pinned providerPromptCacheKey" '.branchAcceptedPromptCacheKey' 'true'
expect "createAgentSession accepts a restricted tool set" '.branchToolNamesRestricted' 'true'

# Pillar 2 - turn-free bidirectional injection.
expect "pi.sendMessage is available to main" '.sendMessage' 'function'
expect "sendCustomMessage on an idle session starts no turn" '.sendCustomMessageStartedNoTurn' 'true'
expect "the event bus reaches a handler synchronously through accept()" '.eventBusSynchronousThroughAccept' 'true'

# The settle signals that stand in for agent_settled.
expect "ctx.isIdle is available on lifecycle handlers" '.isIdle' 'function'
expect "ctx.hasPendingMessages is available on lifecycle handlers" '.hasPendingMessages' 'function'
expect "ctx.setInterval is available for the bounded settle sweep" '.setInterval' 'function'
expect "ctx.sessionManager exposes getEntries for the dialog mirror" '.sessionManagerOnContext' 'function'
expect "agent_end fired at least once" '.agentEndFired > 0' 'true'
expect "agent_end carries the willContinue continuation flag" '.agentEndCarriesWillContinueProperty' 'true'

# The gap, asserted explicitly so the substitute cannot rot.
expect "agent_settled never fires (the substitute is still required)" '.agentSettledFired' '0'

branch_error=$(probe '.branchError')
[ -z "$branch_error" ] || fail "omp $OMP_VERSION: branch session creation reported: $branch_error"

printf 'ok - omp %s carries every supervision-branch capability, and still has no agent_settled\n' "$OMP_VERSION"
