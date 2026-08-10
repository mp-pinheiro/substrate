import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeRuntimeState } from "./identity";
import { findGateRoot } from "./policy";
import { engineObserve, engineStatus, sessionId, withRootLock } from "./runtime";
import { runCheckpointTransaction } from "./transactions";

function registerSessionLifecycle(pi: ExtensionAPI): void {
	pi.on("session_stop", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		await withRootLock(root, async () => {
			await engineObserve(root);
		});
		const status = await engineStatus(root);
		const pendingOwned = status?.pendingOwned ?? [];
		const dirtyPaths = status?.dirtyPaths ?? [];
		const trackingError = status?.trackingError ?? null;
		const driftNotice = status?.driftNotice ?? null;
		let autoFailure = "";
		if (pendingOwned.length > 0 && !event.stop_hook_active && !trackingError) {
			const result = await runCheckpointTransaction(
				root,
				sessionId(root),
				"chore(agent): checkpoint owned work at session stop",
			);
			const receipt = result.receipt;
			if (receipt) {
				writeRuntimeState(root, { lastCheckpoint: receipt });
				ctx.ui.notify(
					`Substrate auto-checkpoint ${receipt.commit.slice(0, 12)} committed agent-owned work. No push performed.`,
					"info",
				);
				return;
			}
			autoFailure = result.summary.split("\n").slice(-8).join("\n");
		}
		const unowned = dirtyPaths.filter((path) => !pendingOwned.includes(path)).sort();
		const hasBlockingState =
			pendingOwned.length > 0 ||
			Boolean(driftNotice) ||
			(Boolean(trackingError) && dirtyPaths.length > 0);
		if (!hasBlockingState) return;
		const details = [
			pendingOwned.length > 0 ? `Agent-owned pending paths: ${pendingOwned.join(", ")}` : "",
			unowned.length > 0 ? `Unowned pending paths (left in place): ${unowned.join(", ")}` : "",
			driftNotice ? driftNotice : "",
			trackingError ? `Ownership tracking error: ${trackingError}` : "",
			autoFailure ? `Automatic checkpoint failed:\n${autoFailure}` : "",
		].filter(Boolean);
		const reason = [
			"[substrate — completion blocked]",
			...details,
			"Run the required direct verification, then call substrate_checkpoint. Do not push.",
		].join("\n");
		writeRuntimeState(root, {
			lastCheckpoint: { status: "pending", at: new Date().toISOString() },
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
