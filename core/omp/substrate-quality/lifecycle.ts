import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeRuntimeState } from "./identity";
import { ensureTaskState, findGateRoot, taskRuntimePatch, workingSnapshot } from "./runtime";

function registerSessionLifecycle(pi: ExtensionAPI): void {
	pi.on("session_stop", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		const state = ensureTaskState(root);
		const current = workingSnapshot(root);
		const currentPaths = Object.keys(current.entries).sort();
		const ownedPending = currentPaths.filter((path) => state.owned.has(path));
		const revisionBypass = current.revision !== state.initial.revision && !state.checkpointed;
		const hasBlockingState =
			ownedPending.length > 0 || revisionBypass || Boolean(state.trackingError) || Boolean(current.error);
		if (!hasBlockingState) return;
		const unowned = currentPaths.filter((path) => !state.owned.has(path));
		const details = [
			ownedPending.length > 0 ? `Agent-owned pending paths: ${ownedPending.join(", ")}` : "",
			unowned.length > 0 ? `Unowned pending paths: ${unowned.join(", ")}` : "",
			revisionBypass ? "Repository revision changed without a Substrate checkpoint receipt." : "",
			state.trackingError ? `Ownership tracking error: ${state.trackingError}` : "",
			current.error ? `Working-copy inspection error: ${current.error}` : "",
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
