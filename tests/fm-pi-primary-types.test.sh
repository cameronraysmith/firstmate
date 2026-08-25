#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate primary extensions:
# the Pi set under .pi/extensions/ and the omp set under .omp/extensions/.
#
# The sandbox mirrors the repository's own directory layout instead of flattening
# the sources, because the omp extensions import the shared operational-input and
# branch-dispatch adapters across roots as ../../.pi/extensions/lib/*.ts and those
# relative paths only resolve when both roots keep their real positions.
#
# Two of the three omp files import no vendor module at all - they declare omp's
# API surface structurally - so the installed Pi declarations below serve the Pi
# half alone. The exception is .omp/extensions/fm-branch-supervision.ts, which
# needs real SDK VALUES (createAgentSession, SessionManager) and so names omp's
# own @oh-my-pi/pi-coding-agent. omp ships as a compiled binary with no npm
# declarations to link, so the sandbox supplies a narrow declaration of exactly
# the surface that file uses. Be clear about what that does and does not buy:
# it checks OUR file's internal consistency under strict mode, and it cannot
# check omp's real signatures. The real signatures are checked behaviorally, by
# tests/fm-omp-branch-capability.test.sh, which hands the very same option set to
# a real omp and asserts the session comes back.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for primary extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for primary extension typecheck"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
  echo "not ok - installed Pi package is missing pi-tui, pi-ai, typebox, or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/.pi/extensions/lib" "$TMP_ROOT/.omp/extensions" \
  "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types" \
  "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$TMP_ROOT/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/.pi/extensions/lib/fm-branch-model-picker.ts"
# Retained through the Calm retirement: fm-branch-supervision.ts imports this
# module for its Calm-hidden branch outcome rows, so deleting it would leave
# the branch extension unable to load at all.
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$TMP_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.omp/extensions/fm-branch-supervision.ts" "$TMP_ROOT/.omp/extensions/fm-branch-supervision.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

# The narrow omp declaration described in the header. Every field the branch
# passes is named explicitly, so a typo or a dropped isolation option is a
# compile error here rather than a silently permissive session at runtime.
cat > "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent/package.json" <<'JSON'
{"name":"@oh-my-pi/pi-coding-agent","type":"module","types":"./index.d.ts","exports":{".":{"types":"./index.d.ts","default":"./index.js"}}}
JSON
printf 'export {};\n' > "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent/index.js"
cat > "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent/index.d.ts" <<'DTS'
export declare class SessionManager {
  static create(cwd: string, sessionsDir: string): SessionManager;
  static open(file: string, sessionsDir: string): SessionManager;
  getSessionFile(): string | undefined;
}

export interface CreateAgentSessionOptions {
  cwd?: string;
  sessionManager?: SessionManager;
  systemPrompt?: string | string[];
  providerPromptCacheKey?: string;
  providerPromptCacheKeySource?: "explicit" | "fork";
  disableExtensionDiscovery?: boolean;
  skills?: unknown[];
  rules?: unknown[];
  contextFiles?: Array<{ path: string; content: string }>;
  promptTemplates?: unknown[];
  slashCommands?: unknown[];
  enableMCP?: boolean;
  enableLsp?: boolean;
  enableIrc?: boolean;
  hasUI?: boolean;
  toolNames?: string[];
  restrictToolNames?: boolean;
  allowRestrictedCustomTools?: boolean;
  customTools?: unknown[];
  extensions?: unknown[];
}

export interface CreateAgentSessionResult {
  session: unknown;
}

export declare function createAgentSession(
  options?: CreateAgentSessionOptions,
): Promise<CreateAgentSessionResult>;
DTS

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": [".pi/extensions/*.ts", ".pi/extensions/lib/*.ts", ".omp/extensions/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi and omp primary extensions pass strict no-emit typecheck against Pi %s and a narrow omp declaration\n' "$version"
