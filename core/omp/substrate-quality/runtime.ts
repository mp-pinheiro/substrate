import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
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

type WorkingSnapshot = {
	entries: Record<string, string>;
	fingerprint: string;
	revision: string;
	error?: string;
};

type AgentTaskState = {
	root: string;
	initial: WorkingSnapshot;
	observed: WorkingSnapshot;
	owned: Set<string>;
	checkpointed: boolean;
	sessionChanges: Set<string>;
	trackingError?: string;
	driftNotice?: string;
};

const taskStates = new Map<string, AgentTaskState>();
const pendingSnapshots = new Map<string, { root: string; before: WorkingSnapshot }>();

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
	const digest = createHash("sha256").update(resolve(root)).digest("hex").slice(0, 16);
	return join(process.env.HOME, ".omp", "run", "substrate-quality", `${digest}.json`);
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

async function commandOutput(root: string, command: string[]): Promise<{ stdout: string; error?: string }> {
	const result = await runCommand(root, command);
	if (result.exitCode === 0) return { stdout: result.stdout };
	const stderr = result.stderr.trim();
	return { stdout: result.stdout, error: stderr || `${command[0]} exited ${result.exitCode}` };
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

async function workingPaths(root: string): Promise<{ paths: string[]; error?: string }> {
	const paths: string[] = [];
	if (existsSync(join(root, ".jj"))) {
		const result = await commandOutput(root, ["jj", "diff", "--name-only"]);
		if (result.error) return { paths, error: result.error };
		paths.push(...result.stdout.split("\n").filter(Boolean));
	} else {
		for (const command of [
			["git", "diff", "--name-only", "-z", "--diff-filter=ACDMRTUXB", "HEAD", "--"],
			["git", "ls-files", "--others", "--exclude-standard", "-z"],
		]) {
			const result = await commandOutput(root, command);
			if (result.error) return { paths, error: result.error };
			paths.push(...result.stdout.split("\0").filter(Boolean));
		}
	}
	const normalized = [...new Set(paths)].sort();
	const invalid = normalized.find(
		(path) => path.includes("\n") || relative(root, resolve(root, path)).startsWith(".."),
	);
	if (invalid) return { paths: normalized, error: `unsafe changed path: ${JSON.stringify(invalid)}` };
	return { paths: normalized };
}

async function workingSnapshot(root: string): Promise<WorkingSnapshot> {
	const revisionResult = existsSync(join(root, ".jj"))
		? await commandOutput(root, ["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id"])
		: await commandOutput(root, ["git", "rev-parse", "HEAD"]);
	const revision = revisionResult.stdout.trim();
	const result = await workingPaths(root);
	const error = revisionResult.error ?? result.error;
	if (error) {
		return {
			entries: {},
			fingerprint: createHash("sha256").update(error).digest("hex"),
			revision,
			error,
		};
	}
	const entries: Record<string, string> = {};
	for (const path of result.paths) {
		const abs = resolve(root, path);
		try {
			if (lstatSync(abs).isSymbolicLink()) {
				entries[path] = "symlink";
				continue;
			}
			entries[path] = `file:${createHash("sha256").update(readFileSync(abs)).digest("hex")}`;
		} catch {
			entries[path] = existsSync(abs) ? "unreadable" : "deleted";
		}
	}
	return {
		entries,
		fingerprint: createHash("sha256")
			.update(
				JSON.stringify({
					revision,
					entries: Object.entries(entries).sort(([a], [b]) => a.localeCompare(b)),
				}),
			)
			.digest("hex"),
		revision,
	};
}

function changedBetween(before: WorkingSnapshot, after: WorkingSnapshot): string[] {
	const paths = new Set([...Object.keys(before.entries), ...Object.keys(after.entries)]);
	return [...paths].filter((path) => before.entries[path] !== after.entries[path]).sort();
}

// "Pre-existing" = currently pending and not owned; resolved entries stop counting.
function reconcileInitial(state: AgentTaskState, current: WorkingSnapshot): void {
	for (const path of Object.keys(state.initial.entries)) {
		if (!(path in current.entries)) delete state.initial.entries[path];
	}
	if (state.initial.revision !== current.revision) {
		state.initial = { ...state.initial, revision: current.revision };
	}
}

// Drift re-baselines instead of bricking: externally-changed paths lose ownership
// (the agent must not commit unauthored work); trackingError heals on a clean snapshot.
function rebaseline(state: AgentTaskState, current: WorkingSnapshot): void {
	const drifted = changedBetween(state.observed, current);
	for (const path of drifted) state.owned.delete(path);
	for (const path of [...state.owned]) {
		if (!(path in current.entries)) state.owned.delete(path);
	}
	reconcileInitial(state, current);
	state.observed = current;
	if (state.trackingError) {
		state.driftNotice = `ownership tracking recovered (${state.trackingError}); unobserved changes are not owned`;
	} else if (drifted.length > 0) {
		state.driftNotice = `working copy changed outside observed tool calls; not owned: ${drifted.join(", ")}`;
	}
	state.trackingError = undefined;
}

// Hydration re-owns only fingerprint-verified paths: matching content proves prior
// agent authorship across restarts; user-touched paths fail the match, stay unowned.
async function ensureTaskState(root: string): Promise<AgentTaskState> {
	const existing = taskStates.get(root);
	if (existing) return existing;
	const snapshot = await workingSnapshot(root);
	const state: AgentTaskState = {
		root,
		initial: { ...snapshot, entries: { ...snapshot.entries } },
		observed: snapshot,
		owned: new Set<string>(),
		checkpointed: false,
		sessionChanges: new Set<string>(),
		trackingError: snapshot.error,
	};
	if (!snapshot.error) {
		const task = readRuntimeState(root).task;
		const record = task && typeof task === "object" ? (task as Record<string, unknown>) : {};
		const persisted =
			record.ownedEntries && typeof record.ownedEntries === "object"
				? (record.ownedEntries as Record<string, unknown>)
				: {};
		for (const [path, entry] of Object.entries(persisted)) {
			if (typeof entry === "string" && snapshot.entries[path] === entry) {
				state.owned.add(path);
				delete state.initial.entries[path];
			}
		}
		const changes = Array.isArray(record.sessionChanges) ? record.sessionChanges : [];
		for (const change of changes) {
			if (typeof change === "string" && /^[a-z0-9]+$/.test(change)) state.sessionChanges.add(change);
		}
	}
	taskStates.set(root, state);
	return state;
}

// Shared gate-tool preconditions: tracked state must be inspectable and current.
async function taskPreconditions(root: string): Promise<{
	state: AgentTaskState;
	current: WorkingSnapshot;
	failure?: string;
}> {
	const state = await ensureTaskState(root);
	if (state.trackingError) {
		return { state, current: state.observed, failure: `ownership tracking failed: ${state.trackingError}` };
	}
	const current = await workingSnapshot(root);
	if (current.error) return { state, current, failure: `cannot inspect working copy: ${current.error}` };
	if (current.fingerprint !== state.observed.fingerprint) {
		return { state, current, failure: "working copy changed outside an observed agent tool call" };
	}
	return { state, current };
}

async function checkpointedState(
	root: string,
	after: WorkingSnapshot,
	previous: AgentTaskState,
	commit: string,
	committedPaths: readonly string[],
): Promise<AgentTaskState> {
	// `previous` predates the unlocked transaction; a concurrent locked op may
	// have recorded new ownership on the live entry since — merge onto that.
	const live = taskStates.get(root) ?? previous;
	const owned = new Set([...live.owned].filter((path) => !committedPaths.includes(path) && path in after.entries));
	const sessionChanges = new Set(live.sessionChanges);
	const changeId = await changeIdOf(root, commit);
	if (changeId) sessionChanges.add(changeId);
	return {
		root,
		initial: { ...after, entries: { ...after.entries } },
		observed: after,
		owned,
		checkpointed: true,
		sessionChanges,
	};
}

function taskRuntimePatch(state: AgentTaskState): Record<string, unknown> {
	const ownedEntries: Record<string, string> = {};
	for (const path of [...state.owned].sort()) {
		const entry = state.observed.entries[path];
		if (entry !== undefined) ownedEntries[path] = entry;
	}
	return {
		task: {
			initialDirty: Object.keys(state.initial.entries),
			ownedPaths: [...state.owned].sort(),
			ownedEntries,
			checkpointed: state.checkpointed,
			trackingError: state.trackingError ?? null,
			driftNotice: state.driftNotice ?? null,
			sessionChanges: [...state.sessionChanges].sort(),
		},
	};
}

async function changeIdOf(root: string, commit: string): Promise<string | null> {
	if (!existsSync(join(root, ".jj"))) return null;
	const result = await commandOutput(root, ["jj", "log", "-r", commit, "--no-graph", "-T", "change_id"]);
	if (result.error) return null;
	const change = result.stdout.trim();
	return /^[a-z0-9]+$/.test(change) ? change : null;
}

export {
	callKey,
	changedBetween,
	changeIdOf,
	checkpointedState,
	commandOutput,
	ensureTaskState,
	isReadOnlyTool,
	pendingSnapshots,
	readRuntimeState,
	rebaseline,
	reconcileInitial,
	runtimeStatePath,
	taskPreconditions,
	taskRuntimePatch,
	taskStates,
	withRootLock,
	workingSnapshot,
};
export type { AgentTaskState, WorkingSnapshot };
