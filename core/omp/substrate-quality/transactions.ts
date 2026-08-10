import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { findGateRoot, runCommand } from "./policy";

type CheckpointReceipt = {
	commit: string;
	vcs: string;
	at: string;
	status: string;
};

type ToolOutcome = {
	content: Array<{ type: "text"; text: string }>;
	details?: unknown;
	isError?: boolean;
};

type ProgressSink = (text: string) => void;

type TransactionIO = { progress?: ProgressSink; signal?: AbortSignal };

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
			return run(root, params, { progress, signal });
		},
	});
}

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

function resolveMaintenanceCmd(root: string): string[] {
	const bin = resolveEngineBin(root);
	return bin ? [bin, "maintenance"] : ["substrate-engine", "maintenance"];
}

async function spawnTransactionScript(
	root: string,
	command: string[],
	tail: number,
	io: TransactionIO,
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
	const result = await runCommand(root, command, { onLine, signal: io.signal });
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
): Promise<{ receipt: CheckpointReceipt | null; ok: boolean; summary: string }> {
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
	if (result.exitCode !== 0) {
		return {
			receipt: null,
			ok: false,
			summary: `${result.summary}\ncheckpoint failed with exit ${result.exitCode}`,
		};
	}
	return { receipt: checkpointReceipt(result.stdout), ok: true, summary: result.summary };
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
	registerGateTool,
	runCheckpointTransaction,
	runRestructureTransaction,
};
export type { CheckpointReceipt };
