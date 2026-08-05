import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { findGateRoot } from "./policy";
import { commandOutput, type WorkingSnapshot } from "./runtime";

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
	run: (root: string, params: unknown) => Promise<ToolOutcome>,
): void {
	pi.registerTool({
		name: spec.name,
		label: spec.label,
		description: spec.description,
		parameters: spec.parameters,
		loadMode: "essential",
		approval: "exec",
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const root = findGateRoot(ctx.cwd);
			if (!root) {
				return blockedToolResult(
					`${spec.blockedPrefix} blocked: Substrate is inactive in this working directory`,
				);
			}
			return run(root, params);
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

function spawnTransactionScript(
	root: string,
	command: string[],
	tail: number,
): { exitCode: number; stdout: string; summary: string } {
	const proc = Bun.spawnSync(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
	const stdout = new TextDecoder().decode(proc.stdout).trim();
	const stderr = new TextDecoder().decode(proc.stderr).trim();
	const summary = [stdout, stderr].filter(Boolean).join("\n").split("\n").slice(-tail).join("\n");
	return { exitCode: proc.exitCode ?? 1, stdout, summary };
}

function runCheckpointTransaction(
	root: string,
	paths: string[],
	message: string,
): { receipt: CheckpointReceipt | null; ok: boolean; summary: string } {
	const command = [
		join(root, ".substrate", "checkpoint.sh"),
		"--message",
		message,
		...paths.flatMap((path) => ["--path", path]),
		"--json",
	];
	const result = spawnTransactionScript(root, command, 40);
	if (result.exitCode !== 0) {
		return {
			receipt: null,
			ok: false,
			summary: `${result.summary}\ncheckpoint failed with exit ${result.exitCode}`,
		};
	}
	return { receipt: checkpointReceipt(result.stdout), ok: true, summary: result.summary };
}

function runRestructureTransaction(
	root: string,
	args: string[],
): { receipt: Record<string, unknown> | null; ok: boolean; summary: string } {
	const command = [join(root, ".substrate", "restructure.sh"), ...args, "--json"];
	const result = spawnTransactionScript(root, command, 25);
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

export {
	blockedToolResult,
	maintenanceCheckpointReceipt,
	registerGateTool,
	runCheckpointTransaction,
	runRestructureTransaction,
};
export type { CheckpointReceipt };
