import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeRuntimeState } from "./identity";
import { findGateRoot } from "./policy";
import {
	checkpointedState,
	ensureTaskState,
	taskRuntimePatch,
	taskStates,
	workingSnapshot,
} from "./runtime";
import { runCheckpointTransaction } from "./transactions";

function registerSessionLifecycle(pi: ExtensionAPI): void {
	pi.on("session_stop", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		const state = ensureTaskState(root);
		const current = workingSnapshot(root);
		const currentPaths = Object.keys(current.entries).sort();
		const ownedPending = currentPaths.filter((path) => state.owned.has(path));
		let autoFailure = "";
		if (
			ownedPending.length > 0 &&
			!event.stop_hook_active &&
			!state.trackingError &&
			!current.error &&
			current.fingerprint === state.observed.fingerprint
		) {
			const result = runCheckpointTransaction(
				root,
				ownedPending,
				"chore(agent): checkpoint owned work at session stop",
			);
			if (result.receipt) {
				const after = workingSnapshot(root);
				if (!after.error) {
					const next = checkpointedState(root, after, state, result.receipt.commit);
					taskStates.set(root, next);
					writeRuntimeState(root, { lastCheckpoint: result.receipt, ...taskRuntimePatch(next) });
					ctx.ui.notify(
						`Substrate auto-checkpoint ${result.receipt.commit.slice(0, 12)} committed agent-owned work. No push performed.`,
						"info",
					);
					return;
				}
			}
			autoFailure = result.summary.split("\n").slice(-8).join("\n");
		}
		const revisionBypass = current.revision !== state.initial.revision && !state.checkpointed;
		const hasBlockingState =
			ownedPending.length > 0 ||
			revisionBypass ||
			(Boolean(state.trackingError) && currentPaths.length > 0) ||
			Boolean(current.error);
		if (!hasBlockingState) return;
		const unowned = currentPaths.filter((path) => !state.owned.has(path));
		const details = [
			ownedPending.length > 0 ? `Agent-owned pending paths: ${ownedPending.join(", ")}` : "",
			unowned.length > 0 ? `Unowned pending paths (left in place): ${unowned.join(", ")}` : "",
			revisionBypass ? "Repository revision changed without a Substrate checkpoint receipt." : "",
			state.trackingError ? `Ownership tracking error: ${state.trackingError}` : "",
			current.error ? `Working-copy inspection error: ${current.error}` : "",
			autoFailure ? `Automatic checkpoint failed:\n${autoFailure}` : "",
		].filter(Boolean);
		const reason = [
			"[substrate — completion blocked]",
			...details,
			"Run the required direct verification, then call substrate_checkpoint. Do not push.",
		].join("\n");
		writeRuntimeState(root, {
			lastCheckpoint: { status: "pending", at: new Date().toISOString() },
			...taskRuntimePatch(state),
		});
		if (event.stop_hook_active) {
			ctx.ui.notify(reason, "warning");
			return;
		}
		return {
			continue: true,
			additionalContext: reason,
			decision: "block" as const,
			reason,
		};
	});
}

export { registerSessionLifecycle };
