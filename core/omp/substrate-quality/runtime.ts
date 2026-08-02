import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";

const HARD: Array<[RegExp, string]> = [
	[/(^|\/)substrate-baseline\.json$/, "baseline changes only via the gate (--update-baseline)"],
	[/(^|\/)\.substrate(\/|$)/, "vendored substrate core — change the kit and run: substrate update"],
	[/(^|\/)CLAUDE\.md$/, "governance doc — propose the edit to the user instead"],
];

const SUBSTRATE_POLICY = [
	"This repository is governed by Substrate's deterministic quality gate.",
	"Treat every `[substrate — fix before proceeding]` report as blocking: resolve it before unrelated work.",
	"For workflow-health requests, run `substrate verify` once; do not assemble ad hoc test batteries or run `substrate audit` unless the user explicitly requests committed-plan regression.",
	"Run only direct verification relevant to the requested change.",
	"After direct verification, call `substrate_checkpoint`; it gates, tightens improved metrics, and commits only agent-owned paths.",
	"Never run `jj commit` or `git commit` directly. Never push automatically; publication remains user-owned.",
	"Do not bypass checks, edit generated or protected assets, or relax the baseline unless the user explicitly requests that policy change.",
].join("\n");

// walk up for the vendored gate so subdirectory sessions resolve the repo
function findGateRoot(cwd: string): string | null {
	let dir = resolve(cwd);
	for (;;) {
		if (existsSync(join(dir, ".substrate", "gate.sh"))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function engineVersion(root: string): string {
	try {
		return readFileSync(join(root, ".substrate", "VERSION"), "utf8").trim();
	} catch {
		return "unknown";
	}
}
// jj hooks are runtime-gated: active only when the repo root carries .jj
function findJjRoot(cwd: string): string | null {
	let dir = resolve(cwd);
	for (;;) {
		if (existsSync(join(dir, ".jj"))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function globToRegExp(glob: string): RegExp {
	let out = "";
	for (let i = 0; i < glob.length; i++) {
		const c = glob[i];
		if (c === "*") {
			if (glob[i + 1] === "*") {
				out += ".*";
				i++;
			} else {
				out += "[^/]*";
			}
		} else if (c === "?") {
			out += "[^/]";
		} else if ("\\^$.|+()[]{}".includes(c)) {
			out += `\\${c}`;
		} else {
			out += c;
		}
	}
	return new RegExp(`^${out}$`);
}

type Config = {
	ok: boolean;
	missing: boolean;
	protectedGlobs: RegExp[];
	contractPaths: string[];
	contractsInvalid: boolean;
};

function loadConfig(cwd: string): Config {
	let raw: string;
	try {
		raw = readFileSync(resolve(cwd, "substrate.json"), "utf8");
	} catch {
		return { ok: true, missing: true, protectedGlobs: [], contractPaths: [], contractsInvalid: false };
	}
	try {
		const cfg = JSON.parse(raw);
		const globs = Array.isArray(cfg.protected_paths) ? cfg.protected_paths : [];
		const contracts = Array.isArray(cfg.contracts) ? cfg.contracts : [];
		const contractsInvalid = contracts.some(
			(c: { name?: unknown; regen?: unknown; paths?: unknown }) =>
				!c || typeof c.name !== "string" || typeof c.regen !== "string" || !Array.isArray(c.paths),
		);
		const contractPaths: string[] = contracts.flatMap((c: { paths?: string[] }) =>
			Array.isArray(c.paths) ? c.paths : [],
		);
		return {
			ok: true,
			missing: false,
			protectedGlobs: globs.map(globToRegExp),
			contractPaths,
			contractsInvalid,
		};
	} catch {
		return { ok: false, missing: false, protectedGlobs: [], contractPaths: [], contractsInvalid: false };
	}
}

function toolPath(input: object): string {
	if ("path" in input && typeof input.path === "string") return input.path;
	if ("file_path" in input && typeof input.file_path === "string") return input.file_path;
	if ("file" in input && typeof input.file === "string") return input.file;
	return "";
}
function resolveThroughExistingParent(path: string): string {
	let current = path;
	const missing: string[] = [];
	while (!existsSync(current)) {
		const parent = dirname(current);
		if (parent === current) return path;
		missing.unshift(basename(current));
		current = parent;
	}
	try {
		return join(realpathSync(current), ...missing);
	} catch {
		return path;
	}
}

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
	trackingError?: string;
};

const taskStates = new Map<string, AgentTaskState>();
const pendingSnapshots = new Map<string, { root: string; before: WorkingSnapshot }>();

function isReadOnlyTool(toolName: string, input: object): boolean {
	if (TRACKING_READ_ONLY_TOOLS[toolName]) return true;
	if (toolName !== "lsp" || !("action" in input)) return false;
	return Boolean(TRACKING_LSP_READ_ONLY_ACTIONS[String(input.action ?? "")]);
}

function callKey(event: { toolName: string; input: object }): string {
	let toolCallId: unknown;
	if ("toolCallId" in event) toolCallId = event.toolCallId;
	if (typeof toolCallId === "string" && toolCallId) return toolCallId;
	return `${event.toolName}\0${JSON.stringify(event.input)}`;
}

function commandOutput(root: string, command: string[]): { stdout: Uint8Array; error?: string } {
	const proc = Bun.spawnSync(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
	if (proc.exitCode === 0) return { stdout: proc.stdout };
	const stderr = new TextDecoder().decode(proc.stderr).trim();
	return { stdout: proc.stdout, error: stderr || `${command[0]} exited ${proc.exitCode}` };
}
function maintenanceReceiptPath(root: string): string | null {
	const result = commandOutput(root, ["git", "rev-parse", "--git-common-dir"]);
	if (result.error) return null;
	const metadata = new TextDecoder().decode(result.stdout).trim();
	return metadata ? join(resolve(root, metadata), "substrate", "maintenance-receipt.json") : null;
}

function maintenanceCheckpointReceipt(
	root: string,
	before: WorkingSnapshot,
	after: WorkingSnapshot,
): CheckpointReceipt | null {
	if (!before.revision || !after.revision || before.revision === after.revision) return null;
	const validator = commandOutput(root, [
		join(root, ".substrate", "maintenance-lib.sh"),
		"repository-receipt-matches",
	]);
	if (validator.error) return null;
	const path = maintenanceReceiptPath(root);
	if (!path) return null;
	try {
		const value: unknown = JSON.parse(readFileSync(path, "utf8"));
		if (!value || typeof value !== "object") return null;
		const receipt = value as {
			at?: unknown;
			noPush?: unknown;
			operation?: unknown;
			repository?: {
				commit?: unknown;
				fromRevision?: unknown;
				status?: unknown;
				toRevision?: unknown;
				vcs?: unknown;
			};
		};
		if (
			!["init", "bootstrap", "update"].includes(String(receipt.operation)) ||
			receipt.noPush !== true ||
			receipt.repository?.status !== "committed" ||
			receipt.repository.fromRevision !== before.revision ||
			receipt.repository.toRevision !== after.revision ||
			receipt.repository.commit !== after.revision ||
			typeof receipt.repository.vcs !== "string" ||
			typeof receipt.at !== "string"
		) {
			return null;
		}
		return {
			commit: after.revision,
			vcs: receipt.repository.vcs,
			at: receipt.at,
			status: "committed",
		};
	} catch {
		return null;
	}
}
function refreshReport(root: string): string | null {
	const report = join(root, ".substrate", "report.sh");
	if (!existsSync(report)) return null;
	const proc = Bun.spawnSync([report, "--refresh"], { cwd: root, stdout: "pipe", stderr: "pipe" });
	const stderr = new TextDecoder().decode(proc.stderr).trim();
	if (proc.exitCode !== 0) return stderr || `report refresh exited ${proc.exitCode}`;
	return stderr || null;
}


function workingPaths(root: string): { paths: string[]; error?: string } {
	const paths: string[] = [];
	if (existsSync(join(root, ".jj"))) {
		const result = commandOutput(root, ["jj", "diff", "--name-only"]);
		if (result.error) return { paths, error: result.error };
		paths.push(...new TextDecoder().decode(result.stdout).split("\n").filter(Boolean));
	} else {
		for (const command of [
			["git", "diff", "--name-only", "-z", "--diff-filter=ACDMRTUXB", "HEAD", "--"],
			["git", "ls-files", "--others", "--exclude-standard", "-z"],
		]) {
			const result = commandOutput(root, command);
			if (result.error) return { paths, error: result.error };
			paths.push(...new TextDecoder().decode(result.stdout).split("\0").filter(Boolean));
		}
	}
	const normalized = [...new Set(paths)].sort();
	const invalid = normalized.find(
		(path) => path.includes("\n") || relative(root, resolve(root, path)).startsWith(".."),
	);
	if (invalid) return { paths: normalized, error: `unsafe changed path: ${JSON.stringify(invalid)}` };
	return { paths: normalized };
}

function workingSnapshot(root: string): WorkingSnapshot {
	const revisionResult = existsSync(join(root, ".jj"))
		? commandOutput(root, ["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id"])
		: commandOutput(root, ["git", "rev-parse", "HEAD"]);
	const revision = new TextDecoder().decode(revisionResult.stdout).trim();
	const result = workingPaths(root);
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

function ensureTaskState(root: string): AgentTaskState {
	const existing = taskStates.get(root);
	if (existing) return existing;
	const snapshot = workingSnapshot(root);
	const state: AgentTaskState = {
		root,
		initial: snapshot,
		observed: snapshot,
		owned: new Set<string>(),
		checkpointed: false,
		trackingError: snapshot.error,
	};
	taskStates.set(root, state);
	return state;
}

function taskRuntimePatch(state: AgentTaskState): Record<string, unknown> {
	return {
		task: {
			initialDirty: Object.keys(state.initial.entries),
			ownedPaths: [...state.owned].sort(),
			checkpointed: state.checkpointed,
			trackingError: state.trackingError ?? null,
		},
	};
}

type CheckpointReceipt = {
	commit: string;
	vcs: string;
	at: string;
	status: string;
};

function checkpointReceipt(output: string): CheckpointReceipt | null {
	for (const line of output.trim().split("\n").reverse()) {
		try {
			const value: unknown = JSON.parse(line);
			if (!value || typeof value !== "object") continue;
			if (
				!("commit" in value) ||
				typeof value.commit !== "string" ||
				!("vcs" in value) ||
				typeof value.vcs !== "string" ||
				!("at" in value) ||
				typeof value.at !== "string" ||
				!("status" in value) ||
				typeof value.status !== "string"
			) {
				continue;
			}
			return { commit: value.commit, vcs: value.vcs, at: value.at, status: value.status };
		} catch {}
	}
	return null;
}

export {
	callKey,
	changedBetween,
	checkpointReceipt,
	engineVersion,
	ensureTaskState,
	findGateRoot,
	findJjRoot,
	HARD,
	isReadOnlyTool,
	loadConfig,
	maintenanceCheckpointReceipt,
	pendingSnapshots,
	refreshReport,
	resolveThroughExistingParent,
	SUBSTRATE_POLICY,
	taskRuntimePatch,
	taskStates,
	toolPath,
	workingSnapshot,
};
export type { AgentTaskState };
