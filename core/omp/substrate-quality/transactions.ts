import { existsSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { findGateRoot, runCommand } from "./policy";
import type { ApprovalContext } from "./policy";

type CheckpointReceipt = {
	commit: string;
	vcs: string;
	at: string;
	status: string;
	publicationBookmark?: string | null;
};

type RecoveryReport = {
	status: "blocked" | "incomplete";
	code: string;
	owner: "agent" | "user";
	retry: "after-change" | "terminal";
	summary: string;
	details: string[];
	next: string;
};

type ToolOutcome = {
	content: Array<{ type: "text"; text: string }>;
	details?: unknown;
	isError?: boolean;
};

type ProgressSink = (text: string) => void;
type TransactionIO = { progress?: ProgressSink; signal?: AbortSignal; approval?: ApprovalContext };
type RegressionAcceptance = { keys: string[]; reason?: string };
type UpdateReceipt = {
	id: string;
	operation: string;
	at: string;
	status: string;
	commit: string | null;
	changedPaths: string[];
};

function renderRecovery(report: RecoveryReport): string {
	const label =
		report.status === "incomplete"
			? "[substrate — checkpoint incomplete]"
			: report.owner === "user"
				? "[substrate — hand to user]"
				: "[substrate — fix before proceeding]";
	return [
		`${label} ${report.summary}`,
		...report.details.map((detail) => detail.split("\n").map((line) => `  ${line}`).join("\n")),
		report.next ? `next: ${report.next}` : "",
	]
		.filter(Boolean)
		.join("\n");
}

function checkpointReport(output: string): RecoveryReport | null {
	const candidate = reverseJSONObjects(output, (value) =>
		(value.status === "blocked" || value.status === "incomplete") &&
		typeof value.code === "string" &&
		(value.owner === "agent" || value.owner === "user") &&
		(value.retry === "after-change" || value.retry === "terminal") &&
		typeof value.summary === "string" &&
		Array.isArray(value.details) &&
		value.details.every((detail) => typeof detail === "string") &&
		typeof value.next === "string",
	);
	return candidate as unknown as RecoveryReport | null;
}

function protocolInvalid(output: string): RecoveryReport {
	return {
		status: "blocked",
		code: "recovery.protocol-invalid",
		owner: "user",
		retry: "terminal",
		summary: "checkpoint returned no valid recovery envelope",
		details: [output.trim() || "the checkpoint produced no output"],
		next: "preserve pending work and hand this raw output to the user; do not retry automatically",
	};
}

function checkpointReceipt(output: string): CheckpointReceipt | null {
	const value = reverseJSONObjects(
		output,
		(candidate) =>
			typeof candidate.commit === "string" &&
			typeof candidate.vcs === "string" &&
			typeof candidate.at === "string" &&
			typeof candidate.status === "string",
	);
	if (!value) return null;
	return {
		commit: value.commit as string,
		vcs: value.vcs as string,
		at: value.at as string,
		status: value.status as string,
		publicationBookmark:
			typeof value.publicationBookmark === "string" || value.publicationBookmark === null
				? value.publicationBookmark
				: null,
	};
}

function reverseJSONObjects(
	output: string,
	visit: (value: Record<string, unknown>) => boolean,
): Record<string, unknown> | null {
	for (const line of output.trim().split("\n").reverse()) {
		try {
			const value: unknown = JSON.parse(line);
			if (!value || typeof value !== "object") continue;
			const candidate = value as Record<string, unknown>;
			if (visit(candidate)) return candidate;
		} catch {}
	}
	return null;
}


function blockedToolResult(message: string): ToolOutcome {
	return {
		content: [{ type: "text" as const, text: message }],
		details: { status: "blocked" },
		isError: true,
	};
}

type GateToolParameters = Parameters<ExtensionAPI["registerTool"]>[0]["parameters"];

function registerGateTool(
	pi: ExtensionAPI,
	spec: {
		name: string;
		label: string;
		description: string;
		parameters: GateToolParameters;
		blockedPrefix: string;
	},
	run: (root: string, params: unknown, io: TransactionIO) => Promise<ToolOutcome>,
): void {
	// Registration advertises the tool for the whole session, so a session rooted
	// outside a governed repo must not see gate tools that could only refuse.
	if (!findGateRoot(process.cwd())) return;
	pi.registerTool({
		name: spec.name,
		label: spec.label,
		description: spec.description,
		parameters: spec.parameters,
		loadMode: "essential",
		approval: "exec",
		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const root = findGateRoot(ctx.cwd);
			if (!root) {
				return blockedToolResult(
					`${spec.blockedPrefix} blocked: Substrate is inactive in this working directory`,
				);
			}
			const progress = onUpdate && ((text: string) => onUpdate({ content: [{ type: "text" as const, text }] }));
			return run(root, params, { progress, signal, approval: ctx });
		},
	});
}


function resolveEngineBin(root: string): string | null {
	const fromEnv = process.env.SUBSTRATE_ENGINE_BIN;
	if (fromEnv && existsSync(fromEnv)) return fromEnv;
	const local = join(root, "build", "substrate-engine");
	if (existsSync(local)) return local;
	const pathDirs = (process.env.PATH || "").split(":");
	for (const dir of pathDirs) {
		const candidate = join(dir, "substrate-engine");
		if (existsSync(candidate)) return candidate;
	}
	return null;
}

function resolveCheckpointCmd(root: string): string[] {
	const bin = resolveEngineBin(root);
	return bin ? [bin, "checkpoint"] : ["substrate-engine", "checkpoint"];
}

function resolveRestructureCmd(root: string): string[] {
	const bin = resolveEngineBin(root);
	return bin ? [bin, "restructure"] : ["substrate-engine", "restructure"];
}

function parseRegressionAcceptance(
	params: Record<string, unknown>,
	prefix: string,
): RegressionAcceptance | ToolOutcome {
	let keys: string[] = [];
	if (params.acceptRegression !== undefined) {
		const raw = params.acceptRegression;
		if (!Array.isArray(raw) || raw.some((k) => typeof k !== "string" || !/^[A-Za-z0-9._:/-]+$/.test(k))) {
			return blockedToolResult(
				`${prefix} blocked: acceptRegression must be an array of metric keys matching [A-Za-z0-9._:/-]+`,
			);
		}
		keys = raw as string[];
	}
	if (keys.includes("max_file_lines")) {
		return blockedToolResult(
			"max_file_lines is an informational measurement; accept oversized_files instead when a reviewed regression is unavoidable",
		);
	}
	let reason: string | undefined;
	if (params.acceptRegressionReason !== undefined) {
		if (typeof params.acceptRegressionReason !== "string") {
			return blockedToolResult(`${prefix} blocked: acceptRegressionReason must be a string`);
		}
		reason = params.acceptRegressionReason;
	}
	if (keys.length > 0 && !reason) {
		return blockedToolResult(
			`${prefix} blocked: --accept-regression requires --reason "<text>" — the justification is committed to substrate-baseline.json`,
		);
	}
	if (reason && keys.length === 0) {
		return blockedToolResult(`${prefix} blocked: --reason applies only to --accept-regression`);
	}
	if (reason) {
		if (reason.length < 20) {
			return blockedToolResult(`${prefix} blocked: --reason must be at least 20 characters`);
		}
		if (/[;&|<>$`\n]/.test(reason)) {
			return blockedToolResult(`${prefix} blocked: --reason must not contain ; & | < > $ \` or a newline`);
		}
	}
	return { keys, reason };
}

async function confirmRegressionAcceptance(
	io: TransactionIO,
	acceptance: RegressionAcceptance,
	action: string,
): Promise<ToolOutcome | null> {
	if (acceptance.keys.length === 0) return null;
	const detail = `${action} raises the ceiling for ${acceptance.keys.join(", ")} and records this reason in substrate-baseline.json:\n${acceptance.reason}`;
	if (!io.approval?.hasUI) {
		return blockedToolResult(
			`[substrate — hand to user] ratchet.acceptance: accepting a regression needs the user's approval and this session has no UI to ask. ${detail}`,
		);
	}
	if (await io.approval.ui.confirm("Substrate: accept ratchet regression?", detail)) return null;
	return blockedToolResult(`The user declined the regression acceptance. ${detail}`);
}

function metadataDir(root: string): string | null {
	for (const candidate of [join(root, ".git"), join(root, ".jj", "repo", "store", "git"), join(root, ".jj")]) {
		if (!existsSync(candidate)) continue;
		const stat = statSync(candidate);
		if (stat.isDirectory()) return candidate;
		if (candidate.endsWith(".git")) {
			const pointer = readFileSync(candidate, "utf8").trim();
			if (pointer.startsWith("gitdir: ")) return resolve(root, pointer.slice("gitdir: ".length));
		}
	}
	return null;
}

function updateReceipt(root: string, startedAt: number): UpdateReceipt | null {
	const dir = metadataDir(root);
	if (!dir) return null;
	const path = join(dir, "substrate", "maintenance-receipt.json");
	if (!existsSync(path)) return null;
	let value: unknown;
	try {
		value = JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return null;
	}
	if (!value || typeof value !== "object") return null;
	const receipt = value as Record<string, unknown>;
	const repository = receipt.repository;
	if (
		typeof receipt.id !== "string" ||
		typeof receipt.operation !== "string" ||
		typeof receipt.at !== "string" ||
		!repository ||
		typeof repository !== "object"
	) {
		return null;
	}
	if (Date.parse(receipt.at) < startedAt - 5000) return null;
	const repo = repository as Record<string, unknown>;
	if (typeof repo.status !== "string") return null;
	return {
		id: receipt.id,
		operation: receipt.operation,
		at: receipt.at,
		status: repo.status,
		commit: typeof repo.commit === "string" ? repo.commit : null,
		changedPaths: Array.isArray(repo.changedPaths) ? repo.changedPaths.filter((p) => typeof p === "string") : [],
	};
}

async function runUpdateTransaction(
	root: string,
	options: { message?: string; fromWorktree: boolean; acceptance: RegressionAcceptance },
	io: TransactionIO = {},
): Promise<{ receipt: UpdateReceipt | null; ok: boolean; summary: string }> {
	const localCli = join(root, "bin", "substrate");
	const command = [
		existsSync(localCli) ? localCli : "substrate",
		"update",
		"--apply",
		"--checkpoint",
		"--repo-only",
		...(options.message ? ["--message", options.message] : []),
		...(options.fromWorktree ? ["--from-worktree"] : []),
		...(options.acceptance.keys.length > 0
			? [`--accept-regression=${options.acceptance.keys.join(",")}`, "--reason", options.acceptance.reason ?? ""]
			: []),
	];
	const startedAt = Date.now();
	const result = await spawnTransactionScript(root, command, 40, io, { SUBSTRATE_NO_USER_HARNESS: "1" });
	if (result.exitCode !== 0) {
		return { receipt: null, ok: false, summary: result.summary || `update failed with exit ${result.exitCode}` };
	}
	return { receipt: updateReceipt(root, startedAt), ok: true, summary: result.summary };
}

async function spawnTransactionScript(
	root: string,
	command: string[],
	tail: number,
	io: TransactionIO,
	env?: Record<string, string>,
): Promise<{ exitCode: number; stdout: string; summary: string }> {
	const progress = io.progress;
	const recent: string[] = [];
	let emittedAt = 0;
	const onLine = progress
		? (line: string) => {
				recent.push(line);
				if (recent.length > tail) recent.shift();
				if (Date.now() - emittedAt < 100) return;
				emittedAt = Date.now();
				progress(recent.join("\n"));
			}
		: undefined;
	const result = await runCommand(root, command, { onLine, signal: io.signal, env });
	const stdout = result.stdout.trim();
	const stderr = result.stderr.trim();
	const summary = [stdout, stderr].filter(Boolean).join("\n").split("\n").slice(-tail).join("\n");
	if (progress && recent.length > 0) progress(recent.join("\n"));
	return { exitCode: result.exitCode, stdout, summary };
}

async function runCheckpointTransaction(
	root: string,
	session: string,
	message: string,
	acceptRegression: string[] = [],
	reason?: string,
	io: TransactionIO = {},
): Promise<{ receipt: CheckpointReceipt | null; report: RecoveryReport | null; ok: boolean; summary: string }> {
	const command = [
		...resolveCheckpointCmd(root),
		"--message",
		message,
		...["--session", session],
		...(acceptRegression.length > 0 ? [`--accept-regression=${acceptRegression.join(",")}`] : []),
		...(reason ? ["--reason", reason] : []),
		"--json",
	];
	const result = await spawnTransactionScript(root, command, 40, io);
	const report = checkpointReport(result.stdout + "\n" + result.summary);
	if (result.exitCode !== 0) {
		const terminal = report ?? protocolInvalid(result.stdout + "\n" + result.summary);
		return { receipt: null, report: terminal, ok: false, summary: renderRecovery(terminal) };
	}
	const receipt = checkpointReceipt(result.stdout);
	if (!receipt) {
		const terminal = protocolInvalid(result.stdout + "\n" + result.summary);
		return { receipt: null, report: terminal, ok: false, summary: renderRecovery(terminal) };
	}
	return { receipt, report: null, ok: true, summary: result.summary };
}

async function runRestructureTransaction(
	root: string,
	args: string[],
	io: TransactionIO = {},
): Promise<{ receipt: Record<string, unknown> | null; ok: boolean; summary: string }> {
	const command = [...resolveRestructureCmd(root), ...args, "--json"];
	const result = await spawnTransactionScript(root, command, 25, io);
	if (result.exitCode !== 0) {
		return {
			receipt: null,
			ok: false,
			summary: result.summary || `restructure failed with exit ${result.exitCode}`,
		};
	}
	let receipt: Record<string, unknown> | null = null;
	for (const line of result.stdout.split("\n").reverse()) {
		try {
			const value: unknown = JSON.parse(line);
			if (value && typeof value === "object" && "status" in value && value.status === "restructured") {
				receipt = value as Record<string, unknown>;
				break;
			}
		} catch {}
	}
	return { receipt, ok: true, summary: result.summary };
}


export {
	blockedToolResult,
	confirmRegressionAcceptance,
	parseRegressionAcceptance,
	registerGateTool,
	runCheckpointTransaction,
	runRestructureTransaction,
	runUpdateTransaction,
};
export type { CheckpointReceipt, RegressionAcceptance, UpdateReceipt };
