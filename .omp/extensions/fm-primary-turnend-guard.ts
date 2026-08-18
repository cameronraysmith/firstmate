// Firstmate turn-end guard, session-start nudge, and PreToolUse seatbelts for an
// omp PRIMARY session.
//
// This file is deliberately NOT a copy of .pi/extensions/fm-primary-turnend-guard.ts.
// omp is a Pi fork whose loader rewrites @earendil-works/* specifiers onto its own
// bundled copies, so Pi's extension imports and RUNS on omp without error while its
// central handler never fires: omp emits no agent_settled. Loading Pi's guard on omp
// therefore produces a disarmed primary that still writes its own "loaded" marker.
// Every mechanism below was measured on omp itself (omp/17.3.5, 2026-08-18); see
// docs/verification/runtime-backends.md "omp (oh-my-pi)".
//
// Discovery: omp auto-discovers only TOP-LEVEL .omp/extensions/*.ts, with no project
// trust prompt and no recursion into subdirectories. It does not discover .pi/, and
// Pi does not discover .omp/, so the two harnesses cannot pick up each other's
// primary extensions by discovery. omp also loads none of .claude/settings.json's
// hooks despite exporting CLAUDECODE=1, so the Claude Stop guard cannot double-fire
// here.
//
// TURN END. omp's session_stop is a Claude-shaped BLOCKING stop hook rather than
// Pi's passive agent_settled notification, so this guard blocks the turn outright
// instead of forcing a follow-up message. omp awaits an async handler (verified with
// a 1.5s child), which is what makes spawning the guard from inside it viable. The
// payload's own stop_hook_active is forwarded to bin/fm-turnend-guard.sh rather than
// Pi's hardcoded false: omp marks exactly the stop that follows a block, so the
// guard's default-mode loop guard bounds this to one forced continuation per turn.
// Claude's --claude mode is deliberately NOT used - it exists because Claude marks
// every stop after ANY continuation, including its own auto-arm's, which omp does
// not do.
//
// The block reason is the guard's own stderr, unwrapped. Unlike Pi's follow-up this
// is hook-channel text rather than an injected user message, so it carries no
// operational-input encoding, exactly as the Claude and Codex hook paths do.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
// The operational-input adapter has ONE TypeScript owner. Its physical home under
// .pi/extensions/lib/ is where the first harness to need it put it; it wraps
// bin/fm-operational-input.sh and contains no Pi behaviour, and it resolves that
// script from its OWN module path, so importing it across roots is correct rather
// than a Pi dependency. Verified loading and round-tripping under omp.
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "../../.pi/extensions/lib/fm-operational-input.ts";

// omp's own API surface, declared structurally instead of imported from
// @earendil-works/pi-coding-agent: that package's ExtensionAPI describes Pi's
// events, and typing an omp extension with it is the exact confusion this adapter
// exists to prevent. Only the members measured on omp appear here.
type OmpSessionHeader = {
  id?: unknown;
  timestamp?: unknown;
  parentSession?: unknown;
};

type OmpEventContext = {
  sessionManager?: {
    getHeader?: () => OmpSessionHeader | null | undefined;
  };
};

type OmpStopEvent = { stop_hook_active?: unknown };
type OmpToolCallEvent = { type?: unknown; toolName?: unknown; input?: unknown };

// Every member is REQUIRED rather than optional-chained. An extension that
// optional-chains its registrations still runs markLoaded() when the harness lacks
// them, which is the silently-disarmed-primary shape this adapter exists to
// prevent; a hard call fails at load instead, and the session-start diagnostic then
// reports the missing marker.
type OmpExtensionAPI = {
  on: (
    event: string,
    handler: (event: unknown, ctx: OmpEventContext) => unknown,
  ) => unknown;
  sendMessage: (message: {
    customType: string;
    content: string;
    display: boolean;
    details?: Record<string, unknown>;
  }) => unknown;
};

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

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
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nOMP SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

// omp's session_start carries only {type}: it has no Pi "reason" field, and it fires
// exactly ONCE per omp process. /new starts a genuinely new session - the header id
// changes and later handlers report it - but emits neither session_shutdown nor
// session_start, so omp has no clear-source equivalent and no re-emit on /new.
// omp does supply direct restoration evidence Pi lacks: header.parentSession names
// the session a fork descends from.
function restoredSessionEvidence(header: OmpSessionHeader | undefined): boolean {
  const timestamp = header?.timestamp;
  const createdAt = typeof timestamp === "string" ? Date.parse(timestamp) : Number.NaN;
  return Number.isFinite(createdAt) && createdAt < performance.timeOrigin;
}

function sessionHeader(ctx: OmpEventContext): OmpSessionHeader | undefined {
  try {
    return ctx.sessionManager?.getHeader?.() ?? undefined;
  } catch {
    return undefined;
  }
}

function startupSource(ctx: OmpEventContext): "startup" | "resume" | "fork" {
  const header = sessionHeader(ctx);
  if (header?.parentSession) return "fork";
  const args = process.argv.slice(2);
  const restored = restoredSessionEvidence(header);
  for (const arg of args) {
    if (arg === "--fork" || arg.startsWith("--fork=")) return "fork";
    if (
      restored && (
        arg === "-c" || arg === "--continue" ||
        arg === "-r" || arg === "--resume" ||
        arg === "--session" || arg.startsWith("--session=") ||
        arg === "--session-id" || arg.startsWith("--session-id=")
      )
    ) return "resume";
  }
  return "startup";
}

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    let retainedBytes = 0;
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => {
      if (code !== 0) {
        resolveResult("");
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker}` : raw);
    });
  });
}

// pi.sendMessage throws "Extension runtime not initialized" at module scope, so the
// digest is only ever injected from inside a handler.
async function injectSessionstart(pi: OmpExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // Like Pi, omp injects a MESSAGE rather than hook stdout, so it must carry
    // operational provenance or the Ahoy skill would have to guess whether it was
    // captain-authored. The wrapper already returns an encoded nudge on a
    // context-preserving open, so only an unencoded digest needs the marker added.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    pi.sendMessage({
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

function runGuard(stopHookActive: boolean): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end(JSON.stringify({ stop_hook_active: stopHookActive }));
  });
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). They ride this already-loaded
// extension so no extra -e flag is needed, the same arrangement Pi uses. omp honours
// {block: true, reason} from a tool_call handler: a blocked bash call did not run and
// the model was shown the reason. Each owner script owns its own decision and is
// inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: OmpExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    markLoaded();
    await injectSessionstart(pi, startupSource(ctx));
  });

  // omp's compaction equivalent, and the one context-reset it does report. The
  // digest is what a compacted session has just lost, so re-emitting it here is the
  // point rather than a side effect.
  pi.on("session_compact", async () => {
    await injectSessionstart(pi, "compact");
  });

  pi.on("tool_call", async (event) => {
    const call = event as OmpToolCallEvent;
    if (call?.type !== "tool_call" || call?.toolName !== "bash") return {};
    const command = String((call.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("session_stop", async (event) => {
    const stopHookActive = (event as OmpStopEvent)?.stop_hook_active === true;
    const result = await runGuard(stopHookActive);
    if (result.code !== 2) return undefined;
    return {
      decision: "block",
      reason: result.stderr.trim() ||
        "TURN WOULD END BLIND - supervision is off, and the turn-end guard gave no reason. Restore supervision before ending the turn.",
    };
  });

  markLoaded();
}
