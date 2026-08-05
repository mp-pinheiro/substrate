import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeRuntimeState } from "./identity";
import { taskPreconditions, taskRuntimePatch, workingSnapshot } from "./runtime";
import { blockedToolResult, registerGateTool, runRestructureTransaction } from "./transactions";

function registerRestructureTool(pi: ExtensionAPI): void {
	const parameters = pi.typebox.Type.Object(
		{
			op: pi.typebox.Type.String({ description: "split | describe | squash" }),
			revision: pi.typebox.Type.String({
				description: "change or commit id of a session-authored commit",
			}),
			message: pi.typebox.Type.String({
				description: "Conventional Commit message for the primary result",
			}),
			message2: pi.typebox.Type.Optional(
				pi.typebox.Type.String({ description: "optional message for the split remainder" }),
			),
			into: pi.typebox.Type.Optional(
				pi.typebox.Type.String({ description: "squash destination change id (session-authored)" }),
			),
			paths: pi.typebox.Type.Optional(
				pi.typebox.Type.Array(pi.typebox.Type.String(), {
					description: "paths moved into the first split commit",
				}),
			),
		},
		{ additionalProperties: false },
	);
	registerGateTool(
		pi,
		{
			name: "substrate_restructure",
			label: "Substrate restructure",
			description:
				"Reshape agent session-authored jj commits with one atomic gated operation: split by paths, describe, or squash. Recoverable via jj op restore. Never pushes.",
			parameters,
			blockedPrefix: "restructure",
		},
		async (root, params) => {
			const input = (params && typeof params === "object" ? params : {}) as Record<string, unknown>;
			const op = typeof input.op === "string" ? input.op : "";
			const revision = typeof input.revision === "string" ? input.revision : "";
			const message = typeof input.message === "string" ? input.message : "";
			const message2 = typeof input.message2 === "string" ? input.message2 : "";
			const into = typeof input.into === "string" ? input.into : "";
			const paths = Array.isArray(input.paths)
				? input.paths.filter((path): path is string => typeof path === "string")
				: [];
			if (!op || !revision || !message) {
				return blockedToolResult("restructure blocked: op, revision, and message are required");
			}
			const check = taskPreconditions(root);
			if (check.failure) return blockedToolResult(`restructure blocked: ${check.failure}`);
			const state = check.state;
			if (state.sessionChanges.size === 0) {
				return blockedToolResult(
					"restructure blocked: no session-authored commits to restructure; checkpoint first",
				);
			}
			const args = [
				"--op",
				op,
				"--revision",
				revision,
				"--message",
				message,
				...(message2 ? ["--message2", message2] : []),
				...(into ? ["--into", into] : []),
				...paths.flatMap((path) => ["--path", path]),
				...[...state.sessionChanges].sort().flatMap((change) => ["--allow-change", change]),
			];
			const result = runRestructureTransaction(root, args);
			if (!result.ok) return blockedToolResult(result.summary);
			const receipt = result.receipt;
			if (!receipt) return blockedToolResult("restructure failed: transaction returned no valid receipt");
			const after = workingSnapshot(root);
			if (after.error) {
				return blockedToolResult(`restructure incomplete: cannot inspect the working copy: ${after.error}`);
			}
			state.observed = after;
			state.initial = { ...state.initial, revision: after.revision };
			state.checkpointed = true;
			const newChanges = Array.isArray(receipt.newChangeIds) ? receipt.newChangeIds : [];
			for (const change of newChanges) {
				if (typeof change === "string" && /^[a-z0-9]+$/.test(change)) state.sessionChanges.add(change);
			}
			writeRuntimeState(root, { lastRestructure: receipt, ...taskRuntimePatch(state) });
			return {
				content: [
					{
						type: "text" as const,
						text: `Restructure ${op} applied to ${String(receipt.changeId).slice(0, 12)}. Undo with: jj op restore ${String(receipt.fromOperation).slice(0, 12)}. No push performed.\n${result.summary}`,
					},
				],
				details: receipt,
			};
		},
	);
}

export { registerRestructureTool };
