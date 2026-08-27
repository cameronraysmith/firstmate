// Firstmate supervision branch for omp (docs/supervision-protocols/omp.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// omp process as the captain's MAIN session. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which writes
// the durable outcome store FIRST (bin/fm-branch-outcome.sh) and only then
// merges an append-only note to main's tail. Main's captain/assistant dialog is
// mirrored into the branch as read-only fm-main-mirror context at main's
// turn_end.
//
// omp-only by construction: this file lives in .omp/extensions, which no other
// harness loads. It is an adaptation of the Pi branch extension's BEHAVIOR, not
// a port of its code - see "Why this is not Pi's file" below.
//
// PROCESS-SCOPED OWNERSHIP. One supervision cycle belongs to the omp PROCESS,
// not to a conversation, for exactly the reason stated once in
// .omp/extensions/fm-primary-omp-watch.ts: omp emits no lifecycle event for a
// same-process session replacement, so a /new must neither retire this cycle
// nor require re-arming. Pi's per-session generation shape is wrong here -
// binding a generation to session_start on omp produced a duplicate-watcher
// pathology in this fork before. This file therefore binds exactly ONE
// generation for the life of the process and retires it on terminal shutdown.
// The mirror needs no replacement event either: collectMainDialog keys its
// cursor on the session FILE, so a /new re-mirrors the new session from its
// start on its own.
//
// Session-lock ownership is still evaluated LAZILY at every side-effect
// boundary, exactly as Pi does and for the same reason: a cold omp start
// acquires the fleet lock only when the session runs fm-session-start.sh, so
// latching ownership once at load would leave the branch inert for the whole
// process, and a secondary read-only omp session that never owns the lock must
// never write markers, clean leases, or accept wakes.
//
// Failure direction: every path that cannot reach a working branch falls back
// to delivering the wake to MAIN exactly as before the branch existed. A broken
// branch degrades to today's behavior, never to a lost wake. The wake queue
// stays durable until the handler runs the drain's acknowledgement, and the
// outcome store's read cursor advances only after a note is actually handed to
// omp, so an outcome recorded but never merged is re-presented by the
// BRANCH OUTCOMES digest at the next locked session start.
//
// Failure direction, refined: a wake is never lost, but the two reasons a
// branch can be unreachable are NOT the same fact and do not degrade the same
// way. ABSENCE - this omp has no branch capability - degrades to main quietly
// and indefinitely, because that is a property of the runtime and not an
// operator error. CONTRACT MISMATCH - the capability is present but its shape
// moved under us - degrades too, and is additionally said out loud once per
// home. The distinction is not decorative. This port once fed
// createAgentSession an un-awaited SessionManager.open promise, died inside omp
// on `sessionManager.getSessionId is not a function`, and fell back to main on
// every wake for the life of the process with every suite still green. Note
// what that was NOT: omp's contract never moved - open has been `static async`
// since well before 18.0.4 - and the defect was simply unreachable until a
// branch had recorded a session file to reopen, so the first launch passed and
// armed every launch after it. An omp upgrade supplied only the restart, which
// is why "it broke when the runtime bumped" was the wrong story. A degrade that
// says nothing is how a capability disappears without anyone noticing.
//
// Threat model (captain-decided, unchanged from Pi): the branch's actor
// identity is CONFUSED-AGENT-GRADE - deterministic env injection plus a
// readonly-variable shell prelude so an accidental override fails loudly inside
// the branch's own shell. bin/fm-lease-lib.sh documents the grade and its
// deliberate limits.
//
// ---------------------------------------------------------------------------
// Why this is not Pi's file (measured against omp 18.0.6 - see
// VERIFIED_OMP_VERSION below; refresh with
// tests/fm-omp-branch-capability.test.sh)
//
// 1. Native specifiers only. Pi-named imports resolve on omp solely through the
//    legacy compat shim, so this file imports @oh-my-pi/pi-coding-agent and
//    declares omp's own extension surface structurally, like the rest of the
//    tracked .omp pair. tests/fm-omp-primary-extensions.test.sh enforces that.
// 2. No DefaultResourceLoader. It exists on omp only inside the Pi compat shim
//    and is not reachable from the native root export. It is also unnecessary:
//    omp's createAgentSession takes the isolation controls directly
//    (systemPrompt, disableExtensionDiscovery, empty skills/rules/contextFiles/
//    promptTemplates/slashCommands, enableMCP/enableLsp/enableIrc off,
//    toolNames + restrictToolNames + allowRestrictedCustomTools).
// 3. No before_provider_request cache-key hook. providerPromptCacheKey is a
//    first-class createAgentSession option on omp, so the per-home key is set
//    where the session is built instead of patched onto each request.
// 4. No createBashToolDefinition and no spawnHook. Both reach omp only through
//    the compat shim, and the shim maps spawnHook onto native shellEnv while
//    DISCARDING the hook's rewritten command - Pi's readonly prelude would be
//    silently dropped. The actor identity is injected natively instead, by a
//    branch-local tool_call handler that revises the bash input before it runs.
// 5. No pi-tui message renderer. omp renders a display:true custom message with
//    its own CustomMessageComponent when no renderer is registered, and the
//    tracked omp extensions deliberately do not tie omp to Pi's presentation
//    layer.
// 6. agent_settled does not exist on omp. See MERGE GATING below.
//
// MERGE GATING - the agent_settled substitute.
// Pi emits agent_settled after its agent_end-era queue processing and uses it
// to choose between an immediate merge and a nextTurn merge. omp has no such
// event. The substitute is agent_end + ctx.isIdle() + explicit tracking of
// queued work, and it must reproduce the "fully settled after automatic
// continuation" boundary, because omp's delivery calls make an early merge
// actively harmful rather than merely early:
//
//   - sendMessage(note, {}) while main is STREAMING steers the live stream.
//   - sendMessage(note, {deliverAs:"nextTurn"}) while main is IDLE appends
//     immediately, with no turn - it does not wait for a turn.
//
// So during the window where main has emitted agent_end with willContinue:true
// (auto-retry, empty/unexpected-stop retry, compaction continuation, TTSR
// self-repair) main is momentarily NOT streaming while a continuation is
// already scheduled. Every delivery mode available in that window lands the
// note mid-continuation. The only correct action is not to deliver at all yet.
//
// This file therefore HOLDS merge notes until main is fully settled and
// delivers them in order once it is. Settled means all three of:
//   - the last agent_end did not carry willContinue: true;
//   - ctx.isIdle() (main is not streaming);
//   - ctx.hasPendingMessages() is false (no queued steer/follow-up/next-turn
//     work will start or absorb a turn).
// Because notes are delivered ONLY while settled, they take omp's idle
// append path and never enter the pending-next-turn queue themselves, so the
// extension's own merges can never poison hasPendingMessages(). Holding is
// strictly safer than Pi's immediate nextTurn merge: the outcome is already
// durable in the store and its read cursor advances only on real delivery.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createAgentSession, SessionManager } from "@oh-my-pi/pi-coding-agent";
import {
  FM_BRANCH_DISPATCH_EVENT,
  scopeForUnreadWake,
  type BranchDispatchOffer,
} from "../../.pi/extensions/lib/fm-branch-dispatch.ts";
import { encodeFirstmateOperationalInput } from "../../.pi/extensions/lib/fm-operational-input.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const afkFlag = join(state, ".afk");
const sessionsDir = join(state, "omp-branch-session");
const sessionPointer = join(state, ".omp-branch-session");
const mirrorCursorFile = join(state, ".omp-branch-mirror-cursor");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
// omp's OWN marker, never Pi's. Pi's extensions load on omp and are silently
// inert there, so an omp primary must never be able to satisfy a supervision
// ownership question with evidence a disarmed session wrote.
const loadedMarker = join(state, ".omp-branch-extension-loaded");
// Records the contract mismatch already announced to the operator, so the
// diagnostic fires once per home per defect instead of once per wake.
const contractMismatchMarker = join(state, ".omp-branch-contract-mismatch");

// Same tool set in the same order on every spawn (tool definitions are part of
// the cached prefix, so reordering them invalidates it). "bash" is omp's own
// registry bash tool; the branch actor identity is injected by the tool_call
// handler installed with the branch, not by replacing the tool.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;

// One shared prompt_cache_key per home for ALL branch sessions, derived only
// from the home path so it survives restarts; main keeps omp's own default.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
// Carried inside the captain note's own text because that text is the only
// part of a custom message the model is given (see deliverNote).
const CAPTAIN_OUTCOME_INSTRUCTION =
  "This is a supervision outcome delivered automatically by the supervision branch. " +
  "It was not typed by the captain and it is not your own earlier output. " +
  "Relay only this outcome to the captain now, in one short message, in captain outcome language. " +
  "Do not restate or repeat any earlier answer.";
// Bounded re-check for held notes. agent_end normally releases them; this only
// covers a continuation that never emits its own terminal agent_end, so a note
// can never be stranded behind a stuck settle flag.
const SETTLE_SWEEP_MS = 5000;

// The omp release this port's session-manager contract is verified against,
// end to end, by tests/fm-omp-branch-capability.test.sh. It is REPORTED, never
// enforced: the gate below probes the surface and adapts, so a later omp that
// keeps the contract keeps working without this line being touched. It exists
// so an incompatible bump is a visible refusal rather than an invisible loss.
const VERIFIED_OMP_VERSION = "18.0.6";

// Exactly the surface a BRANCH session manager is used through, and no more.
// getSessionId is the one that actually bit: createAgentSession reads
// `options.providerSessionId ?? sessionManager.getSessionId()`
// (omp packages/coding-agent/src/sdk.ts), so a value missing it dies INSIDE omp
// with a TypeError indistinguishable from the branch being unsupported.
// getSessionFile is ours, for the pointer that lets the next launch reopen this
// conversation. Nothing else belongs here: demanding a method the port never
// calls would turn an unrelated omp change into a false refusal, and this gate
// only earns its keep while every entry is a real dependency. The MAIN
// session's separate read-only surface is ReadonlyEntries, below.
const REQUIRED_SESSION_MANAGER_METHODS = ["getSessionId", "getSessionFile"] as const;

type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";
type HeldNote = { seq: string; task: string; verdict: Verdict; summary: string; silent: boolean };

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

// omp's API surface, declared structurally rather than imported from
// @earendil-works/pi-coding-agent - see the type note in
// .omp/extensions/fm-primary-turnend-guard.ts. Only the members measured on omp
// appear here, and every member this extension cannot work without is REQUIRED
// rather than optional-chained: silently registering nothing while still
// writing a loaded marker is the exact failure the tracked omp adapters exist
// to prevent.
type OmpToolResult = {
  content: Array<{ type: "text"; text: string }>;
  details?: unknown;
  isError?: boolean;
};

type OmpSchema = { Object: (properties: Record<string, unknown>) => unknown };
type OmpTypeBox = {
  Type: OmpSchema & {
    String: (options?: Record<string, unknown>) => unknown;
    Number: (options?: Record<string, unknown>) => unknown;
    Boolean: (options?: Record<string, unknown>) => unknown;
    Literal: (value: string) => unknown;
    Union: (variants: unknown[], options?: Record<string, unknown>) => unknown;
    Optional: (schema: unknown) => unknown;
  };
};

type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getEntries(): Array<{ type: string }>;
};

// The two settle signals plus the session view the mirror reads. isIdle and
// hasPendingMessages are required for the reason stated in MERGE GATING:
// without them there is no honest agent_settled substitute, and a merge note
// would land mid-continuation.
type OmpEventContext = {
  isIdle: () => boolean;
  hasPendingMessages: () => boolean;
  sessionManager: ReadonlyEntries;
  setInterval: (callback: () => void, ms?: number) => unknown;
};

type OmpAgentEndEvent = { type: "agent_end"; willContinue?: boolean };

type OmpToolDefinition = {
  name: string;
  label: string;
  description: string;
  promptSnippet?: string;
  parameters: unknown;
  execute: (toolCallId: string, params: unknown) => Promise<OmpToolResult>;
};

type OmpBranchSession = {
  prompt: (text: string) => Promise<unknown>;
  sendCustomMessage: (
    message: { customType: string; content: string; display: boolean },
    options: Record<string, never>,
  ) => Promise<unknown>;
  dispose: () => unknown;
};

type OmpExtensionAPI = {
  typebox: OmpTypeBox;
  on: (event: string, handler: (event: unknown, ctx: OmpEventContext) => unknown) => unknown;
  events: { on: (channel: string, handler: (data: unknown) => void) => unknown };
  sendMessage: (
    message: { customType: string; content: string; display: boolean },
    options: { triggerTurn?: boolean; deliverAs?: "steer" | "followUp" | "nextTurn" },
  ) => unknown;
  sendUserMessage: (content: string, options?: { deliverAs?: "steer" | "followUp" }) => unknown;
  registerTool: (tool: OmpToolDefinition) => unknown;
};

// Is the branch capability present at all? Deliberately shallow: it asks only
// whether omp still offers the two entry points this port builds on, never
// which version answered. A build that lacks them cannot host a branch, and
// that is a fact about the runtime, not a defect to shout about.
function ompBranchCapabilityPresent(): boolean {
  return (
    typeof createAgentSession === "function" &&
    typeof (SessionManager as unknown as { create?: unknown } | undefined)?.create === "function"
  );
}

// "" when the value satisfies what createAgentSession is about to do to it;
// otherwise the defect, phrased for whoever has to fix it.
function sessionManagerContractDefect(candidate: unknown): string {
  if (candidate === null || candidate === undefined) {
    return "the SessionManager factory produced nothing";
  }
  if (typeof candidate !== "object" && typeof candidate !== "function") {
    return `the SessionManager factory produced a ${typeof candidate}, not a session manager`;
  }
  // A thenable is named separately because it is the shape that actually broke
  // supervision here, and because "missing getSessionId" would send the reader
  // hunting through omp's session manager for a method that is in fact there.
  if (typeof (candidate as { then?: unknown }).then === "function") {
    return "the SessionManager factory returned a promise this port did not await";
  }
  const missing = REQUIRED_SESSION_MANAGER_METHODS.filter(
    (name) => typeof (candidate as Record<string, unknown>)[name] !== "function",
  );
  if (missing.length > 0) return `the session manager is missing ${missing.join(", ")}`;
  return "";
}

function offerEligible(offer: BranchDispatchOffer): boolean {
  return offer.eligible === true;
}

function afkActive(): boolean {
  return existsSync(afkFlag);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

let ownedLockPid = "";

// Same ownership read as the omp watcher extension's lockOwnership(): the lock
// names the harness pid, and this process owns it when that pid appears in its
// own ancestry.
function lockOwnership(): LockOwnership {
  ownedLockPid = "";
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) {
      ownedLockPid = lockPid;
      return "owned";
    }
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const p = part as { type?: string; text?: string };
        return p && p.type === "text" && typeof p.text === "string" ? p.text : "";
      })
      .filter((piece) => piece.length > 0)
      .join("\n");
  }
  return "";
}

// Operational injections (watcher wakes, away-supervisor escalations, launch
// briefs) are fleet machinery, not captain dialog; mirroring them would feed
// the branch its own supervision traffic back. Current injections start with
// the U+2063 operational prefix; the plain legacy form starts with FIRSTMATE.
function isOperationalUserText(text: string): boolean {
  return text.startsWith("⁣") || /^FIRSTMATE[ _]/.test(text);
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  return `${text.slice(0, MIRROR_MESSAGE_CAP)}\n[mirror truncated at ${MIRROR_MESSAGE_CAP} characters]`;
}

function readMirrorCursor(): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(mirrorCursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn cursor: re-mirror the current main session from its start.
    // Idempotent context, so over-mirroring is safe; dropping is not.
  }
  return { file: "", index: 0 };
}

function writeMirrorCursor(cursor: MirrorCursor): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(mirrorCursorFile, `${JSON.stringify(cursor)}\n`);
}

// Volatile mirror-collection state. On omp the durable cursor is also what
// carries a same-process session replacement: a /new changes the session FILE,
// the anchor no longer matches, and collection restarts from the new session's
// first entry with no lifecycle event needed.
type MirrorCollectionState = {
  collectAnchor: MirrorCursor | null;
  pendingCursor: MirrorCursor | null;
};

function collectMainDialog(
  sessionManager: ReadonlyEntries,
  collection: MirrorCollectionState,
): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor();
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
  const items: MirrorItem[] = [];
  for (const entry of entries.slice(start)) {
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    items.push({ tag: message.role === "user" ? "captain" : "main", text: capMirrorText(text) });
  }
  collection.collectAnchor = { file, index: entries.length };
  collection.pendingCursor = collection.collectAnchor;
  return items;
}

export default function (pi: OmpExtensionAPI) {
  let branch: OmpBranchSession | null = null;
  let branchBroken = "";
  let shuttingDown = false;
  // ONE generation for the life of the omp PROCESS (see the header). It exists
  // so terminal shutdown can quiesce in-flight branch work, not so a /new can
  // rotate it.
  const generation = 1;
  let activatedGeneration = -1;
  // Serializes branch work: mirror appends and wake turns run strictly in
  // dispatch order, one at a time (the branch runs drain -> handle -> ack
  // serially by design).
  let branchChain: Promise<void> = Promise.resolve();
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: MirrorCollectionState = { collectAnchor: null, pendingCursor: null };

  // The agent_settled substitute (see MERGE GATING in the header).
  // True before main's first turn: a session that has never streamed is settled.
  let mainSettled = true;
  const heldNotes: HeldNote[] = [];
  let settleContext: OmpEventContext | null = null;
  let settleSweepArmed = false;

  function generationOwnsLock(expectedGeneration: number): boolean {
    return !shuttingDown && expectedGeneration === generation && lockOwnership() === "owned";
  }

  function markLoaded(): void {
    try {
      mkdirSync(state, { recursive: true });
      writeFileSync(loadedMarker, `${process.pid}\n`);
    } catch {
      // Diagnostic marker only; never block activation on it.
    }
  }

  // A contract mismatch degrades like any other failure - the wake still
  // reaches main - but it is ALSO said out loud, once per home per defect. The
  // marker is keyed to the defect text rather than merely to "a mismatch
  // happened", so a DIFFERENT shape change later still announces itself
  // instead of being swallowed by a stale flag.
  function announceContractMismatch(defect: string): void {
    let announced = "";
    try {
      announced = readFileSync(contractMismatchMarker, "utf8").trim();
    } catch {
      announced = "";
    }
    if (announced === defect) return;
    try {
      mkdirSync(state, { recursive: true });
      writeFileSync(contractMismatchMarker, `${defect}\n`);
    } catch {
      // A marker we cannot persist costs repetition, never the diagnostic.
    }
    const body =
      "FIRSTMATE SUPERVISION DEGRADED: the omp supervision branch is disabled by a runtime CONTRACT " +
      `MISMATCH, not by absence. Detected: ${defect}. This port's session-manager contract is verified ` +
      `against omp ${VERIFIED_OMP_VERSION}, and the omp running now no longer satisfies it. Wakes are ` +
      "being delivered to this session instead, so nothing is lost, but supervision is running without " +
      "its branch until this is fixed. Re-probe with " +
      "FM_OMP_BRANCH_CAPABILITY=1 tests/fm-omp-branch-capability.test.sh.";
    let content = body;
    try {
      content = encodeFirstmateOperationalInput("watcher", body);
    } catch {
      // An encoding failure must not lose the diagnostic; deliver it unmarked.
    }
    try {
      void pi.sendUserMessage(content);
    } catch {
      // Delivery is omp's; the marker still records that this was raised.
    }
  }

  // A working branch retires the record, so a mismatch that returns later is
  // announced again rather than suppressed by the marker that described it.
  function clearContractMismatch(): void {
    try {
      rmSync(contractMismatchMarker, { force: true });
    } catch {
      // Nothing here is load-bearing; at worst one diagnostic is not repeated.
    }
  }

  // A replaced branch conversation must not leave its per-task leases behind
  // (the session-lock holder pid is still alive, so the sweep alone would keep
  // them). One bulk release per generation, at activation.
  function releaseBranchLeases(expectedGeneration: number): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    try {
      const result = spawnSync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
        cwd: fmRoot,
        encoding: "utf8",
        env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
      });
      return result.status === 0;
    } catch {
      return false;
    }
  }

  // Lazy, per-action ownership evaluation (see the header). Returns true only
  // when this process owns the fleet lock right now; the first true evaluation
  // also writes the diagnostic marker and clears stray branch leases.
  function actingAsOwner(expectedGeneration = generation): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    if (activatedGeneration !== expectedGeneration) {
      if (!releaseBranchLeases(expectedGeneration)) return false;
      if (!generationOwnsLock(expectedGeneration)) return false;
      markLoaded();
      activatedGeneration = expectedGeneration;
    }
    return generationOwnsLock(expectedGeneration);
  }

  function runOutcomeScript(args: string[]): { ok: boolean; stdout: string; detail: string } {
    try {
      const result = spawnSync("bash", [outcomeScript, ...args], {
        cwd: fmRoot,
        encoding: "utf8",
        env: scriptEnv,
      });
      if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
      return {
        ok: false,
        stdout: "",
        detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}`,
      };
    } catch (error) {
      return { ok: false, stdout: "", detail: error instanceof Error ? error.message : String(error) };
    }
  }

  // Bounded re-check so a continuation that never emits its own terminal
  // agent_end cannot strand a held note. Armed only once a context exists, and
  // only ever RELEASES notes - it never marks main unsettled.
  function armSettleSweep(ctx: OmpEventContext): void {
    if (settleSweepArmed) return;
    settleSweepArmed = true;
    try {
      ctx.setInterval(() => {
        if (shuttingDown || heldNotes.length === 0) return;
        const current = settleContext;
        if (!current) return;
        if (!current.isIdle() || current.hasPendingMessages()) return;
        mainSettled = true;
        flushHeldNotes();
      }, SETTLE_SWEEP_MS);
    } catch {
      // A host without the contained-timer helper simply relies on agent_end.
    }
  }

  // omp keeps only `content` when it converts a custom message for the model:
  // customType, display, and details never reach the provider. A captain note
  // therefore has to carry its own identity inside `content`, or main receives
  // an unattributed user message written in main's own captain-facing voice and
  // cannot tell an incoming outcome from its own earlier answer. When that
  // happens main re-emits its previous answer instead of relaying the outcome,
  // and the outcome is lost. Upstream measured that against Pi 0.84.1 as 6
  // failures in 24 turns; omp forks that conversion unchanged, so this port
  // carries the fix rather than waiting to re-measure the same defect here.
  //
  // Encoding shells out, so it can fail on a broken checkout. This file's
  // failure direction applies: an outcome that cannot be typed is still
  // delivered, carrying the same instruction as plain text, because an untyped
  // outcome main can still read beats an outcome the captain never sees.
  function captainOutcomeInput(task: string, summary: string): string {
    const body = `${CAPTAIN_OUTCOME_INSTRUCTION}\n\n${task}: ${summary}`;
    try {
      return encodeFirstmateOperationalInput("branch-outcome", body);
    } catch {
      return body;
    }
  }

  // Append-only merge into main, delivered ONLY while main is fully settled.
  // Routine notes take omp's idle no-turn append; a captain-relevant note takes
  // exactly one follow-up turn, and that turn is itself the captain-visible
  // artefact, so the note it carries is delivered silently rather than printed
  // a second time. The outcome store's read cursor advances only here, after
  // the note is actually handed to omp: an outcome recorded but never merged
  // stays unread and is re-presented by the BRANCH OUTCOMES digest at the next
  // locked session start.
  function deliverNote(note: HeldNote): boolean {
    if (!actingAsOwner()) return false;
    if (note.verdict === "captain") {
      pi.sendMessage(
        {
          customType: "fm-branch-merge",
          content: captainOutcomeInput(note.task, note.summary),
          display: false,
        },
        { triggerTurn: true, deliverAs: "followUp" },
      );
    } else {
      pi.sendMessage(
        {
          customType: "fm-branch-merge",
          content: `${MERGE_NOTE_BOAT} ${note.task}: ${note.summary}`,
          display: !(note.task === "fleet" && note.silent),
        },
        {},
      );
    }
    if (/^[0-9]+$/.test(note.seq)) {
      if (!actingAsOwner()) return false;
      return runOutcomeScript(["mark-read", "--through", note.seq]).ok;
    }
    return true;
  }

  function flushHeldNotes(): void {
    while (mainSettled && !shuttingDown && heldNotes.length > 0) {
      const note = heldNotes[0];
      if (!deliverNote(note)) return;
      heldNotes.shift();
    }
  }

  // Queue a merge note and deliver it as soon as main is settled. Returns false
  // only when this process can no longer act as the lock owner, which is the
  // one condition under which the branch must report the merge refused.
  function mergeIntoMain(
    expectedGeneration: number,
    seq: string,
    task: string,
    verdict: Verdict,
    summary: string,
    silent: boolean,
  ): boolean {
    if (!actingAsOwner(expectedGeneration)) return false;
    heldNotes.push({ seq, task, verdict, summary, silent });
    flushHeldNotes();
    return true;
  }

  function createReportTool(toolGeneration: number): OmpToolDefinition {
    const Type = pi.typebox.Type;
    return {
      name: "fm_branch_report",
      label: "Report supervision outcome",
      description:
        "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge an append-only note into the captain-facing main conversation. verdict captain surfaces it to the captain in one turn; routine notes render unless silent marks a no-change heartbeat.",
      parameters: Type.Object({
        task: Type.String({
          description: "The task id the event belongs to (or 'fleet' for fleet-wide events)",
        }),
        verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
          description: "captain only for what a human must see; routine otherwise",
        }),
        summary: Type.String({
          description:
            "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved",
        }),
        wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
        silent: Type.Optional(
          Type.Boolean({
            description:
              "True only when a fleet-wide heartbeat review found literally nothing worth reporting; omit or use false whenever any action was taken or any routine result is worth a note",
          }),
        ),
      }),
      execute: async (_toolCallId: string, params: unknown) => {
        const task = String((params as { task: unknown }).task || "").trim();
        const verdictRaw = String((params as { verdict: unknown }).verdict || "");
        const summary = String((params as { summary: unknown }).summary || "").trim();
        const wake = String((params as { wake?: unknown }).wake ?? "").trim();
        const silent = (params as { silent?: unknown }).silent === true;
        if (
          !task ||
          !summary ||
          (verdictRaw !== "routine" && verdictRaw !== "captain") ||
          (silent && (task !== "fleet" || verdictRaw !== "routine"))
        ) {
          return {
            content: [
              { type: "text" as const, text: "invalid report: task, verdict (routine|captain), and summary are required" },
            ],
            details: undefined,
            isError: true,
          };
        }
        const verdict = verdictRaw as Verdict;
        const appendArgs = [
          "append",
          "--task",
          task,
          "--verdict",
          verdict,
          "--summary",
          summary,
          "--silent",
          String(silent),
        ];
        if (wake) appendArgs.push("--wake", wake);
        if (!actingAsOwner(toolGeneration)) {
          return {
            content: [
              { type: "text" as const, text: "report refused: supervision lost lock ownership" },
            ],
            details: undefined,
            isError: true,
          };
        }
        const appended = runOutcomeScript(appendArgs);
        if (!appended.ok) {
          return {
            content: [
              { type: "text" as const, text: `outcome store append failed (nothing merged): ${appended.detail}` },
            ],
            details: undefined,
            isError: true,
          };
        }
        if (!mergeIntoMain(toolGeneration, appended.stdout, task, verdict, summary, silent)) {
          return {
            content: [
              {
                type: "text" as const,
                text: `recorded seq ${appended.stdout}, but merge refused after lock loss`,
              },
            ],
            details: undefined,
            isError: true,
          };
        }
        return {
          content: [
            { type: "text" as const, text: `recorded seq ${appended.stdout} and merged [${verdict}] into main` },
          ],
          details: undefined,
        };
      },
    };
  }

  // The branch actor identity, injected natively. omp's compat shim maps Pi's
  // spawnHook onto shellEnv and drops the hook's rewritten command, so the
  // readonly prelude is applied here through a branch-local tool_call revision
  // instead - the one hook omp documents as owning the input a tool executes
  // with. Confused-agent-grade by design; bin/fm-lease-lib.sh owns the model.
  function actorIdentityExtension(leaseHolderPid: string, branchGeneration: number) {
    return {
      name: "fm-branch-actor-identity",
      factory: (branchPi: {
        on: (event: string, handler: (event: unknown) => unknown) => unknown;
      }) => {
        branchPi.on("tool_call", (event: unknown) => {
          const call = event as { toolName?: string; input?: { command?: unknown } };
          if (call?.toolName !== "bash") return undefined;
          if (!actingAsOwner(branchGeneration)) {
            return { block: true, reason: "bash refused: supervision lost lock ownership" };
          }
          const command = typeof call.input?.command === "string" ? call.input.command : "";
          if (!command) return undefined;
          return {
            input: {
              ...call.input,
              command: `export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=${JSON.stringify(leaseHolderPid)}
readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID
(
${command}
)`,
            },
          };
        });
      },
    };
  }

  async function createBranch(branchGeneration: number): Promise<OmpBranchSession> {
    const prompt = spawnSync("bash", [promptScript], {
      cwd: fmRoot,
      encoding: "utf8",
      env: scriptEnv,
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision lost lock ownership");
    mkdirSync(sessionsDir, { recursive: true });
    // Absence is checked before anything is built, and degrades quietly: this
    // omp simply cannot host a branch (see the failure-direction note).
    if (!ompBranchCapabilityPresent()) {
      throw new Error("this omp build exposes no supervision-branch capability");
    }
    let sessionManager: SessionManager | null = null;
    try {
      const recorded = readFileSync(sessionPointer, "utf8").trim();
      if (recorded && existsSync(recorded)) {
        // SessionManager.open is `static async` on every omp this port has been
        // measured against (18.0.4 through 18.0.7). Taking its promise as a
        // value is what removed supervision on 18.0.6. A REJECTED open falls
        // through to a fresh session below, the same degrade a torn pointer
        // gets - which is only reachable because the await is inside the try.
        sessionManager = await SessionManager.open(recorded, sessionsDir);
      }
    } catch {
      sessionManager = null;
    }
    if (!sessionManager) {
      sessionManager = SessionManager.create(fmRoot, sessionsDir);
    }
    // The gate. Whatever the two factories produced must satisfy the contract
    // BEFORE omp is handed it, so a shape change is named here instead of
    // surfacing as an opaque TypeError thrown from inside createAgentSession.
    const defect = sessionManagerContractDefect(sessionManager);
    if (defect) {
      announceContractMismatch(defect);
      throw new Error(`omp session-manager contract mismatch: ${defect}`);
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision lost lock ownership");
    const leaseHolderPid = ownedLockPid;
    // The branch loads no project resources at all: extension discovery off (so
    // it can never spawn its own branch), skills/rules/context files off (they
    // vary per home and would destabilize the byte-stable prefix). Its whole
    // standing context is the generator's prompt, and the tool set is
    // BRANCH_TOOL_NAMES in that fixed order.
    const created = await createAgentSession({
      cwd: fmRoot,
      sessionManager,
      systemPrompt: prompt.stdout,
      providerPromptCacheKey: branchCacheKey,
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
      toolNames: [...BRANCH_TOOL_NAMES],
      restrictToolNames: true,
      allowRestrictedCustomTools: true,
      customTools: [createReportTool(branchGeneration)],
      extensions: [actorIdentityExtension(leaseHolderPid, branchGeneration)],
    });
    const session = created.session as unknown as OmpBranchSession;
    if (!actingAsOwner(branchGeneration)) {
      try {
        void session.dispose();
      } catch {
        // Already gone.
      }
      throw new Error("supervision lost lock ownership");
    }
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile()}\n`);
    } catch {
      // Pointer write failure only costs cross-restart session reuse.
    }
    clearContractMismatch();
    return session;
  }

  async function ensureBranch(expectedGeneration: number): Promise<OmpBranchSession> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision lost lock ownership");
    if (branch) return branch;
    if (branchBroken) throw new Error(branchBroken);
    try {
      const created = await createBranch(expectedGeneration);
      if (!actingAsOwner(expectedGeneration)) {
        try {
          void created.dispose();
        } catch {
          // Already gone.
        }
        throw new Error("supervision lost lock ownership");
      }
      branch = created;
      return created;
    } catch (error) {
      if (expectedGeneration === generation && !shuttingDown) {
        branchBroken = error instanceof Error ? error.message : String(error);
      }
      throw error;
    }
  }

  async function flushMirror(session: OmpBranchSession, expectedGeneration: number): Promise<void> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision no longer owns the fleet lock");
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision no longer owns the fleet lock");
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision was replaced during mirror delivery");
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision no longer owns the fleet lock");
      writeMirrorCursor(mirrorCollection.pendingCursor);
      mirrorCollection.pendingCursor = null;
    }
  }

  async function fallbackToMain(message: string, detail: string): Promise<void> {
    const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. (Supervision branch unavailable, falling back to main: ${detail})`;
    let content = body;
    try {
      // Marked operational like every watcher injection, so the wake is never
      // mistaken for captain input (away-mode return semantics, mirror filter).
      content = encodeFirstmateOperationalInput("watcher", body);
    } catch {
      // An encoding failure must not lose the wake; deliver it unmarked.
    }
    // NO options object, for the reason the omp watcher states once: omp's
    // deliverAs "followUp" only QUEUES, so copying Pi's call would produce a
    // fallback wake that never fires.
    await pi.sendUserMessage(content);
  }

  function enqueueWake(message: string, acceptedGeneration: number): void {
    branchChain = branchChain
      .then(async () => {
        if (shuttingDown || acceptedGeneration !== generation) {
          throw new Error("supervision retired before handling the accepted wake");
        }
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision no longer owns the fleet lock");
        const session = await ensureBranch(acceptedGeneration);
        await flushMirror(session, acceptedGeneration);
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision no longer owns the fleet lock");
        const heartbeat = /^heartbeat($|:)/.test(message);
        const scope = scopeForUnreadWake(state, heartbeat);
        if (scope.status === "empty") return;
        if (scope.status === "unsafe") {
          throw new Error("unread wake queue now contains a main-owned row or could not be read safely");
        }
        // A row can still arrive between this re-check and the model starting
        // the drain; that residual is accepted by the confused-agent-grade
        // boundary.
        await session.prompt(
          `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
        );
      })
      .catch(async (error: unknown) => {
        // Return the wake to main rather than losing it; the durable wake queue
        // additionally re-presents anything never acknowledged.
        try {
          await fallbackToMain(message, error instanceof Error ? error.message : String(error));
        } catch {
          // Delivery errors are omp's; the queue row is still durable.
        }
      });
  }

  function enqueueMirrorFlush(): void {
    if (!branch || pendingMirror.length === 0) return;
    const flushGeneration = generation;
    const flushSession = branch;
    branchChain = branchChain
      .then(async () => {
        if (!actingAsOwner(flushGeneration)) return;
        await flushMirror(flushSession, flushGeneration);
      })
      .catch(() => {
        // Mirror items stay queued in pendingMirror on failure; the next wake or
        // flush retries them in order.
      });
  }

  pi.events.on(FM_BRANCH_DISPATCH_EVENT, (data: unknown) => {
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function") return;
    // Check eligibility before ownership activation so an out-of-scope wake gets
    // neither branch routing nor branch-owned state/lease cleanup side effects.
    if (!offerEligible(offer)) return;
    if (!actingAsOwner()) return; // cold start pre-lock, secondary session, or shutdown
    if (afkActive()) return; // the away daemon owns supervision while afk
    if (branchBroken) return; // fail back to today's wake-to-main path
    // Synchronous through accept(): omp's EventBus.on wraps the handler in an
    // async function whose body runs synchronously up to its first await, and
    // this handler has none before accept(), so the watcher's post-emit read of
    // offer.accepted observes this decision.
    offer.accept();
    enqueueWake(offer.message, generation);
  });

  pi.on("agent_start", (_event: unknown, ctx: OmpEventContext) => {
    settleContext = ctx;
    mainSettled = false;
    armSettleSweep(ctx);
  });

  // The agent_settled substitute (see MERGE GATING in the header). willContinue
  // is omp's own "a continuation is already scheduled" flag, and its absence is
  // the terminal settle; isIdle and hasPendingMessages cover the rest of the
  // queue. All three must hold before a held note may be delivered.
  pi.on("agent_end", (event: unknown, ctx: OmpEventContext) => {
    settleContext = ctx;
    armSettleSweep(ctx);
    const willContinue = (event as OmpAgentEndEvent | undefined)?.willContinue === true;
    mainSettled = !willContinue && ctx.isIdle() && !ctx.hasPendingMessages();
    if (mainSettled) flushHeldNotes();
  });

  // Mirror at main's turn_end: collect the new captain/assistant dialog into the
  // volatile queue, then deliver it through the serialized chain so it lands
  // before any later wake. The durable cursor advances only in flushMirror after
  // the complete pending batch reaches the branch.
  pi.on("turn_end", (_event: unknown, ctx: OmpEventContext) => {
    settleContext = ctx;
    if (!actingAsOwner()) return;
    try {
      pendingMirror.push(...collectMainDialog(ctx.sessionManager, mirrorCollection));
    } catch {
      return;
    }
    enqueueMirrorFlush();
  });

  // Terminal quit only. omp fires no lifecycle event for a same-process session
  // replacement, so this handler cannot be reached by /new and the supervision
  // cycle correctly survives one. Notes still held here stay unread in the
  // durable outcome store and are re-presented as the BRANCH OUTCOMES digest at
  // the next locked session start.
  pi.on("session_shutdown", () => {
    shuttingDown = true;
    pendingMirror.length = 0;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    if (branch) {
      try {
        void branch.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
  });

  pi.registerTool({
    name: "fm_branch_outcomes",
    label: "Read supervision branch outcomes",
    description:
      "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
    promptSnippet: "Read what the supervision branch handled (durable outcome store).",
    parameters: pi.typebox.Type.Object({
      recent: pi.typebox.Type.Optional(
        pi.typebox.Type.Number({ description: "How many most-recent outcomes to read (default 20)" }),
      ),
    }),
    execute: async (_toolCallId: string, params: unknown) => {
      const recentRaw = (params as { recent?: unknown }).recent;
      const recent = typeof recentRaw === "number" && recentRaw >= 1 ? String(Math.floor(recentRaw)) : "20";
      const listed = runOutcomeScript(["list", "--recent", recent]);
      if (!listed.ok) {
        return {
          content: [{ type: "text" as const, text: `could not read the outcome store: ${listed.detail}` }],
          details: undefined,
          isError: true,
        };
      }
      return {
        content: [{ type: "text" as const, text: listed.stdout || "(no branch outcomes recorded)" }],
        details: undefined,
      };
    },
  });
}
