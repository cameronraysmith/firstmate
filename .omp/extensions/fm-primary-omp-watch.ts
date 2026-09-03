// Firstmate primary watcher bridge for omp.
//
// PROCESS-SCOPED OWNERSHIP (stated once here). Pi binds one arm generation per
// SESSION activation because Pi emits session_shutdown and session_start for every
// same-process replacement (/new, /resume, /fork, reload). omp emits NEITHER for a
// replacement: /new starts a genuinely new session - the header id changes and every
// later handler reports the new one - while this extension's handlers stay
// registered and no lifecycle event fires. An omp extension is therefore scoped to
// the omp PROCESS, not to a conversation, so this file binds exactly ONE generation
// for the life of the process and retires it on terminal shutdown.
//
// That is the correct lifetime rather than a limitation. The arm child supervises
// the fleet home, which a /new does not change, and delivery keeps working across
// one: a wake sent after a replacement reached the new session and was answered.
// Because there is no session-scoped generation to re-activate, an omp primary makes
// its one fm_watch_arm_omp call per PROCESS, not per session.
//
// The wake call is pi.sendUserMessage(content) with NO options object. omp's
// deliverAs: "followUp" only QUEUES while the session is idle, which is the opposite
// of Pi's requirement, so copying Pi's call would have produced a wake that never
// fired. Verified live: the injected message appeared in the pane and the model
// answered it, both in a fresh session and after a /new.
//
// Everything else - the lock-ownership walk, the arm child, close classification,
// bounded retry, successor verification before wake delivery, and recovery delivery
// confirmation - is the same contract Pi implements, because it is plain Node and
// bin/fm-watch-arm.sh rather than anything harness-specific.
//
// Each actionable wake is first OFFERED to the supervision branch extension over
// the shared handshake in .pi/extensions/lib/fm-branch-dispatch.ts; only a wake
// nobody accepts reaches main, so the fallback is the pre-branch behaviour
// unchanged. A wake whose watcher recovery could not be confirmed, and every
// watcher-failure alarm, always go to main and are never offered.
// omp/17.3.5, measured 2026-08-18; docs/verification/runtime-backends.md.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBranchDispatchOffer,
  FM_BRANCH_DISPATCH_EVENT,
  scopeForUnreadWake,
} from "../../.pi/extensions/lib/fm-branch-dispatch.ts";
import { encodeFirstmateOperationalInput } from "../../.pi/extensions/lib/fm-operational-input.ts";

// omp's API surface, declared structurally rather than imported from
// @earendil-works/pi-coding-agent - see the type note in
// .omp/extensions/fm-primary-turnend-guard.ts. Only the members measured on omp
// appear here. omp publishes typebox ON the API object, so the tool schema needs no
// module import, and this extension registers no custom renderers: omp's default
// tool rendering was verified to display the arm result on its own.
type OmpToolResult = {
  content: Array<{ type: "text"; text: string }>;
  details?: unknown;
};

// Every member is REQUIRED rather than optional-chained, for the reason stated in
// .omp/extensions/fm-primary-turnend-guard.ts: silently registering nothing while
// still writing a loaded marker is the exact failure this adapter exists to
// prevent. A missing wake method is the worst of them - the cycle would run and its
// wakes would vanish.
type OmpExtensionAPI = {
  typebox: { Type: { Object: (properties: Record<string, unknown>) => unknown } };
  on: (event: string, handler: (event: unknown) => unknown) => unknown;
  events: { emit: (channel: string, data: unknown) => void };
  sendUserMessage: (content: string) => unknown;
  registerCommand: (
    name: string,
    options: {
      description: string;
      handler: (args: unknown, ctx: { ui: { notify: (message: string, level: string) => void } }) => Promise<void>;
    },
  ) => unknown;
  registerTool: (tool: {
    name: string;
    label: string;
    description: string;
    promptSnippet?: string;
    promptGuidelines?: string[];
    parameters: unknown;
    execute: () => Promise<OmpToolResult>;
  }) => unknown;
};

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type ProcessGeneration = {
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_OMP_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000,
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_omp again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - omp session is shutting down";

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
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

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - omp extension arm cycle ended without an actionable reason",
  };
}

const generation: ProcessGeneration = {
  stopping: false,
  child: null,
  retryTimer: null,
  retryFailures: 0,
  restoring: false,
  seq: 0,
};

const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();

function generationIsLive(): boolean {
  return !generation.stopping;
}

function stopGeneration(): void {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  generation.retryTimer = null;
  if (generation.child) generation.child.kill("SIGTERM");
  generation.child = null;
}

process.once("exit", stopGeneration);

export default function (pi: OmpExtensionAPI) {
  async function sendWake(message: string): Promise<void> {
    if (!generationIsLive()) return;
    const content = encodeFirstmateOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    await pi.sendUserMessage(content);
  }

  function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): boolean {
    const result = spawnSync(
      "bash",
      [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
      {
        cwd: fmRoot,
        env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
      },
    );
    return result.status === 0;
  }

  // Offer one actionable wake to the supervision branch extension
  // (.omp/extensions/fm-branch-supervision.ts) over the shared handshake. The
  // branch accepts SYNCHRONOUSLY inside its handler, so reading offer.accepted
  // after emit returns is a valid decision: omp's EventBus.on wraps each handler
  // in an async function whose body runs synchronously up to its first await,
  // and the branch's accept() precedes any await. true means the branch now owns
  // delivering and handling this wake, including its own fallback back to main;
  // false means nobody took it and main receives it exactly as before the branch
  // existed. Watcher-failure alarms are never offered, because only main holds
  // fm_watch_arm_omp.
  // Unlike every other member of OmpExtensionAPI, a failure here is CONTAINED
  // rather than fatal. The other members are required because their absence
  // would lose a wake; this one only decides WHICH session handles a wake that
  // is delivered either way, so any failure - a host with no event bus, a
  // throwing branch handler, an unreadable wake queue - must degrade to the
  // pre-branch wake-to-main path rather than take the watcher cycle down with
  // it. A watcher that refused to load would leave the home with no supervision
  // at all, which is strictly worse than no branch.
  function offerWakeToBranch(message: string): boolean {
    try {
      const heartbeat = /^heartbeat($|:)/.test(message);
      const scope = scopeForUnreadWake(state, heartbeat);
      const offer = createBranchDispatchOffer(message, scope.projects, heartbeat, scope.eligible);
      pi.events.emit(FM_BRANCH_DISPATCH_EVENT, offer);
      return offer.accepted === true;
    } catch {
      return false;
    }
  }

  // Confirm handling delivery BEFORE routing, so a wake whose recovery could not
  // be confirmed reaches main and is never offered to the branch, and so the
  // confirmation runs exactly once whichever session ends up handling it.
  async function deliverActionableWake(
    message: string,
    repairFailed: boolean,
    recovery?: { generation: string; watcherPid: string },
  ): Promise<void> {
    if (!generationIsLive()) return;
    if (recovery && !confirmHandlingDelivery(recovery)) {
      await sendWake(message);
      throw new Error("watcher recovery delivery could not be confirmed");
    }
    if (!repairFailed && offerWakeToBranch(message)) return;
    await sendWake(message);
  }

  function surfaceFailure(message: string): void {
    void sendWake(message).catch(() => {
      // omp owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(predecessorArmPid: string): Promise<{
    failure: string;
    recovery?: { generation: string; watcherPid: string };
  }> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive()) return { failure: "" };
      const replacement = startArm(predecessorArmPid);
      const successorChild = generation.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - omp extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - omp extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(message: string, predecessorArmPid: string): void {
    if (!generationIsLive() || generation.child || generation.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(`watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    generation.retryFailures += 1;
    if (generation.retryFailures > retryLimit) {
      surfaceFailure(`watcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (generation.retryTimer === timer) generation.retryTimer = null;
      if (!generationIsLive()) return;
      const result = startArm(predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - omp extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(generation.retryFailures));
    timer.unref();
    generation.retryTimer = timer;
  }

  function startArm(predecessorArmPid = ""): ArmResult {
    if (!generationIsLive()) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (generation.child) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (generation.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++generation.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    generation.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
    };
    const releaseChild = (): void => {
      if (generation.child === armChild) generation.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive()) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        generation.retryFailures = 0;
        generation.restoring = true;
        void (async () => {
          const restoration = await restoreAfterActionableClose(predecessor);
          if (generationIsLive()) generation.restoring = false;
          if (!generationIsLive()) return;
          const message = restoration.failure ? `${classification.message}\n\n${restoration.failure}` : classification.message;
          await deliverActionableWake(message, restoration.failure !== "", restoration.recovery);
        })().catch(() => {
        });
        return;
      }
      if (generation.restoring) return;
      scheduleRetry(classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive()) return;
      if (generation.restoring) return;
      scheduleRetry(`watcher: FAILED - omp extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started omp extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  // Terminal quit only. omp fires no lifecycle event for a same-process session
  // replacement, so this handler cannot be reached by /new and the arm child
  // correctly survives one.
  pi.on("session_shutdown", () => {
    stopGeneration();
  });

  pi.registerCommand("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the omp extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first required omp watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the omp extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required omp watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_omp only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the omp extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: pi.typebox.Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
