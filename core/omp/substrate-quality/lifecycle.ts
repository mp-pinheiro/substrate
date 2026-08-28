import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeRuntimeState } from "./identity";
import { findGateRoot, runCommand } from "./policy";
import { engineBaseCmd, engineObserve, engineStatus, readRuntimeState, sessionId, withRootLock } from "./runtime";
import { runCheckpointTransaction } from "./transactions";

async function policyProtectedPending(root: string, paths: string[]): Promise<string[]> {
	const protectedPaths: string[] = [];
	for (const path of paths) {
		const result = await runCommand(root, [...engineBaseCmd(root), "hook", "protect-paths"], {
			stdin: JSON.stringify({ tool_input: { file_path: path } }),
		});
		if (result.exitCode !== 0) protectedPaths.push(path);
	}
	return protectedPaths;
}

function registerSessionLifecycle(pi: ExtensionAPI): void {
	pi.on("session_stop", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		await withRootLock(root, async () => {
			await engineObserve(root);
		});
		const status = await engineStatus(root);
		if (!status) {
			const reason = "[substrate — completion blocked]\nOwnership status unavailable; retry the session stop hook.";
			if (event.stop_hook_active) {
				ctx.ui.notify(reason, "warning");
				return;
			}
			return { continue: true, additionalContext: reason, decision: "block" as const, reason };
		}
		const pendingOwned = status?.pendingOwned ?? [];
		const dirtyPaths = status?.dirtyPaths ?? [];
		if (pendingOwned.length === 0) {
			ctx.ui.notify("[substrate] no pending agent-owned changes; nothing to checkpoint", "info");
			return;
		}
		const protectedPending = await policyProtectedPending(root, pendingOwned);
		if (protectedPending.length === pendingOwned.length) {
			ctx.ui.notify(
				`[substrate — hand to user] pending paths are policy-protected and can never be agent-committed: ${pendingOwned.join(", ")}. Ask the user to commit them; no checkpoint retry will succeed.`,
				"warning",
			);
			return;
		}
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
		const blockingOwnership =
			pendingOwned.length > 0 || (Boolean(trackingError) && dirtyPaths.length > 0);
		const revision = status?.revision ?? "";
		const priorDrift = readRuntimeState(root).driftBlocked as
			| { notice?: string; revision?: string }
			| undefined;
		const driftOnly = !blockingOwnership && Boolean(driftNotice);
		const driftAlreadySurfaced =
			driftOnly && priorDrift?.notice === driftNotice && priorDrift?.revision === revision;
		if (!blockingOwnership && !driftNotice) {
			if (priorDrift) writeRuntimeState(root, { driftBlocked: null });
			return;
		}
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
			driftBlocked: driftOnly ? { notice: driftNotice, revision } : null,
		});
		if (event.stop_hook_active || driftAlreadySurfaced) {
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
