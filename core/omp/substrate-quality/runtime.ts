// Ownership-tracking policy lives in the Go engine (internal/lifecycle); this
// module is the omp shim that feeds tool events to the engine and reads
// ownership back. The per-file sha256 / fingerprint / reconcile / rebaseline
// state machine that previously lived here was a parallel implementation of
// internal/lifecycle and is deleted — one home for policy (issue #12 rc #3).
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { runCommand, toolPath } from "./policy";

const TRACKING_READ_ONLY_TOOLS: Record<string, true> = {
	read: true,
	grep: true,
	glob: true,
	todo: true,
	hub: true,
	ask: true,
	web_search: true,
};
const TRACKING_LSP_READ_ONLY_ACTIONS: Record<string, true> = {
	diagnostics: true,
	definition: true,
	type_definition: true,
	implementation: true,
	references: true,
	hover: true,
	symbols: true,
	status: true,
	capabilities: true,
};

function isReadOnlyTool(toolName: string, input: object): boolean {
	if (TRACKING_READ_ONLY_TOOLS[toolName]) return true;
	if (/^[a-z][a-z0-9+.-]*:\/\//i.test(toolPath(input))) return true;
	if (toolName !== "lsp" || !("action" in input)) return false;
	return Boolean(TRACKING_LSP_READ_ONLY_ACTIONS[String(input.action ?? "")]);
}

function callKey(event: { toolName: string; input: object }): string {
	let toolCallId: unknown;
	if ("toolCallId" in event) toolCallId = event.toolCallId;
	if (typeof toolCallId === "string" && toolCallId) return toolCallId;
	return `${event.toolName}\0${JSON.stringify(event.input)}`;
}

function runtimeStatePath(root: string): string | null {
	if (!process.env.HOME) return null;
	const hash = createHash("sha256").update(resolve(root)).digest("hex").slice(0, 16);
	return join(process.env.HOME, ".omp", "run", "substrate-quality", `${hash}.json`);
}

function readRuntimeState(root: string): Record<string, unknown> {
	const path = runtimeStatePath(root);
	if (!path) return {};
	try {
		const value: unknown = JSON.parse(readFileSync(path, "utf8"));
		return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
	} catch {
		return {};
	}
}

// Deterministic per-repo session id: same repo → same id → same engine ledger,
// so ownership carries forward across omp restarts (observe reconciles).
function sessionId(root: string): string {
	return `substrate-omp-${createHash("sha256").update(resolve(root)).digest("hex").slice(0, 16)}`;
}

function engineBaseCmd(root: string): string[] {
	const fromEnv = process.env.SUBSTRATE_ENGINE_BIN;
	if (fromEnv && existsSync(fromEnv)) return [fromEnv];
	const local = join(root, "build", "substrate-engine");
	if (existsSync(local)) return [local];
	return ["substrate-engine"];
}

// Ensure the engine ledger exists for this session (start creates it; observe
// requires it). Idempotent: if status answers, the ledger is already live.
async function engineEnsureStarted(root: string): Promise<void> {
	const sid = sessionId(root);
	const status = await runCommand(root, [...engineBaseCmd(root), "hook", "agent-lifecycle", "status", sid]);
	if (status.exitCode === 0) return;
	await runCommand(root, [...engineBaseCmd(root), "hook", "agent-lifecycle", "start"], {
		stdin: JSON.stringify({ session_id: sid }),
	});
}

// Feed the engine ledger after a tool call; the engine computes the snapshot,
// reconciles observed/initial, recomputes ownedPaths, and detects maintenance
// transitions — all ownership policy stays in Go.
async function engineObserve(root: string): Promise<void> {
	const sid = sessionId(root);
	await runCommand(root, [...engineBaseCmd(root), "hook", "agent-lifecycle", "observe"], {
		stdin: JSON.stringify({ session_id: sid }),
	});
}

type OwnershipStatus = {
	ownedPaths: string[];
	dirtyPaths: string[];
	pendingOwned: string[];
	trackingError: string | null;
	driftNotice: string | null;
	revision: string;
	fingerprint: string;
	stale: boolean;
	error: string | null;
};

async function engineStatus(root: string): Promise<OwnershipStatus | null> {
	const sid = sessionId(root);
	const result = await runCommand(root, [...engineBaseCmd(root), "hook", "agent-lifecycle", "status", sid]);
	if (result.exitCode !== 0) return null;
	try {
		return JSON.parse(result.stdout.trim()) as OwnershipStatus;
	} catch {
		return null;
	}
}

// spawnSync made every handler an implicit critical section; async spawns end that.
// Omp drops any handler running past 30s, so transaction subprocesses are always
// awaited outside the lock, and withRootLock is never nested. gate:allow-comment
const rootLocks = new Map<string, Promise<unknown>>();

function withRootLock<T>(root: string, run: () => Promise<T>): Promise<T> {
	const queued = (rootLocks.get(root) ?? Promise.resolve()).then(run);
	rootLocks.set(
		root,
		queued.then(
			() => undefined,
			() => undefined,
		),
	);
	return queued;
}

export {
	callKey,
	engineBaseCmd,
	engineEnsureStarted,
	engineObserve,
	engineStatus,
	isReadOnlyTool,
	readRuntimeState,
	sessionId,
	runtimeStatePath,
	withRootLock,
};
export type { OwnershipStatus };
