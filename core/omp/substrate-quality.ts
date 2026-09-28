// User-scoped OMP enforcement installed by `substrate bootstrap`. Repository
// behavior comes from the target repo's vendored scripts and substrate.json.
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { initializeRuntime, writeRuntimeState } from "./substrate-quality/identity";
import { registerSessionLifecycle } from "./substrate-quality/lifecycle";
import {
	applyPolicyDecision,
	commandTargetCwd,
	hasDirectCommit,
	hasGitMutation,
	hasRawGitPush,
	hasPush,
	findGateRoot,
	findJjRoot,
	hookDecision,
	runCommand,
	SUBSTRATE_POLICY,
	toolPath,
} from "./substrate-quality/policy";
import { registerRestructureTool } from "./substrate-quality/restructure";
import {
	engineBaseCmd,
	engineEnsureStarted,
	engineObserve,
	engineStatus,
	isReadOnlyTool,
	sessionId,
	withRootLock,
} from "./substrate-quality/runtime";
import {
	blockedToolResult,
	confirmRegressionAcceptance,
	parseRegressionAcceptance,
	registerGateTool,
	runCheckpointTransaction,
	runUpdateTransaction,
} from "./substrate-quality/transactions";

const GATE_TOOLS: Record<string, true> = { substrate_checkpoint: true, substrate_restructure: true, substrate_update: true };
function blockedBash(reason: string): { block: true; reason: string } {
	return { block: true, reason };
}
function trackingRoot(event: { toolName: string; input: object }, cwd: string): string | null {
	if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return null;
	const path = toolPath(event.input);
	const root = findGateRoot(path ? dirname(resolve(cwd, path)) : cwd);
	if (!root || !existsSync(join(root, ".substrate", "VERSION"))) return null;
	return root;
}

export default function substrateQuality(pi: ExtensionAPI): void {
	if (!initializeRuntime(pi)) return;

	const checkpointParameters = pi.typebox.Type.Object(
		{
			message: pi.typebox.Type.String({
				description: "Conventional Commit message: type(scope): subject",
			}),
			acceptRegression: pi.typebox.Type.Optional(
				pi.typebox.Type.Array(pi.typebox.Type.String(), {
					description:
						"Ratcheted metric keys whose regression the user reviewed and accepted. Omit unless the gate reported that exact key regressed.",
				}),
			),
			acceptRegressionReason: pi.typebox.Type.Optional(
				pi.typebox.Type.String({
					description:
						"Why the ceiling must move, >=20 chars, no ; & | < > $ ` or newline. Required whenever acceptRegression is set; it is committed to substrate-baseline.json and reviewed in the diff. State the cheaper alternative you rejected and why.",
				}),
			),
		},
		{ additionalProperties: false },
	);
	// mirrors: enforce-conventional-commits.sh
	registerGateTool(
		pi,
		{
			name: "substrate_checkpoint",
			label: "Substrate checkpoint",
			description:
				"After direct verification, gate the exact agent-owned working paths, tighten improved metrics, and create a local commit. Pass acceptRegression only for a metric regression the user reviewed; it requires acceptRegressionReason. Never pushes.",
			parameters: checkpointParameters,
			blockedPrefix: "checkpoint",
		},
		async (root, params, io) => {
			if (
				!params ||
				typeof params !== "object" ||
				!("message" in params) ||
				typeof params.message !== "string"
			) {
				return blockedToolResult("checkpoint blocked: message must be a string");
			}
			const message = params.message;
			const acceptance = parseRegressionAcceptance(params as Record<string, unknown>, "checkpoint");
			if ("content" in acceptance) return acceptance;
			const declined = await confirmRegressionAcceptance(io, acceptance, "This checkpoint");
			if (declined) return declined;
			const status = await withRootLock(root, () => engineStatus(root));
			const pendingOwned = status?.pendingOwned ?? [];
			const dirtyPaths = status?.dirtyPaths ?? [];
			const leftover = dirtyPaths.filter((p) => !pendingOwned.includes(p)).sort();
			if (pendingOwned.length === 0) {
				return blockedToolResult(
					leftover.length > 0
						? `[substrate — hand to user] policy.protected: no pending agent-owned changes; unowned pending paths stay in place: ${leftover.join(", ")}`
						: "[substrate — hand to user] policy.protected: no pending agent-owned changes; preserve the work and ask the user to handle it",
				);
			}
			const sid = sessionId(root);
			const result = await runCheckpointTransaction(root, sid, message, acceptance.keys, acceptance.reason, io);
			const summary = result.summary;
			if (!result.receipt) {
				writeRuntimeState(root, {
					lastCheckpoint: { status: "fail", at: new Date().toISOString() },
				});
				return blockedToolResult(
					result.ok ? `${summary}\ncheckpoint failed: transaction returned no valid receipt` : summary,
				);
			}
			const receipt = result.receipt;
			writeRuntimeState(root, { lastCheckpoint: receipt });
			return {
				content: [
					{
						type: "text" as const,
						text: `Checkpoint ${receipt.commit.slice(0, 12)} passed and committed locally. No push performed.${leftover.length > 0 ? `\nUnowned pending paths left in place: ${leftover.join(", ")}` : ""}\n${summary}`,
					},
				],
				details: receipt,
			};
		},
	);

	const updateParameters = pi.typebox.Type.Object(
		{
			message: pi.typebox.Type.Optional(
				pi.typebox.Type.String({
					description: "Conventional Commit message for the vendor commit; defaults to the maintenance transaction's own message.",
				}),
			),
			fromWorktree: pi.typebox.Type.Optional(
				pi.typebox.Type.Boolean({
					description: "Vendor the kit from this worktree's core/ instead of the pinned kit source. Only meaningful inside the substrate kit repository.",
				}),
			),
			acceptRegression: pi.typebox.Type.Optional(
				pi.typebox.Type.Array(pi.typebox.Type.String(), {
					description: "Ratcheted metric keys whose regression the candidate gate reported; the user is asked to approve before the ceiling moves.",
				}),
			),
			acceptRegressionReason: pi.typebox.Type.Optional(
				pi.typebox.Type.String({
					description: "Why the ceiling must move, >=20 chars, no ; & | < > $ ` or newline. Required whenever acceptRegression is set; committed to substrate-baseline.json.",
				}),
			),
		},
		{ additionalProperties: false },
	);
	registerGateTool(
		pi,
		{
			name: "substrate_update",
			label: "Substrate update",
			description:
				"Vendor the Substrate kit into .substrate/ through the maintenance transaction and commit the result locally (the sanctioned way to land kit changes; never edit .substrate/ directly). Runs the gate on a candidate first. The user's home harness is left alone. Pass acceptRegression only for a metric the candidate gate reported as regressed; the user is asked to approve it. Never pushes.",
			parameters: updateParameters,
			blockedPrefix: "update",
		},
		async (root, params, io) => {
			const input = (params && typeof params === "object" ? params : {}) as Record<string, unknown>;
			if (input.message !== undefined && typeof input.message !== "string") {
				return blockedToolResult("update blocked: message must be a string");
			}
			if (input.fromWorktree !== undefined && typeof input.fromWorktree !== "boolean") {
				return blockedToolResult("update blocked: fromWorktree must be a boolean");
			}
			const acceptance = parseRegressionAcceptance(input, "update");
			if ("content" in acceptance) return acceptance;
			const declined = await confirmRegressionAcceptance(io, acceptance, "This update");
			if (declined) return declined;
			const result = await withRootLock(root, () =>
				runUpdateTransaction(root, { message: input.message as string | undefined, fromWorktree: input.fromWorktree === true, acceptance }, io),
			);
			if (!result.ok) return blockedToolResult(result.summary);
			const receipt = result.receipt;
			if (!receipt) {
				return blockedToolResult(`${result.summary}\nupdate finished but left no readable maintenance receipt for this run`);
			}
			const outcome =
				receipt.status === "committed" && receipt.commit
					? `Update ${receipt.commit.slice(0, 12)} committed locally (${receipt.changedPaths.length} vendored path(s) changed). No push performed.`
					: `Update finished with repository status "${receipt.status}"; nothing was committed.`;
			return {
				content: [{ type: "text" as const, text: `${outcome}\n${result.summary}` }],
				details: receipt,
			};
		},
	);

	registerRestructureTool(pi);

	pi.on("before_agent_start", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root || event.systemPrompt.some((part) => part.includes(SUBSTRATE_POLICY))) return;
	return withRootLock(root, async () => {
		await engineEnsureStarted(root);
		await engineObserve(root);
		writeRuntimeState(root, { loadedAt: new Date().toISOString() });
		const status = await engineStatus(root);
		const dirtyPaths = status?.dirtyPaths ?? [];
		const owned = status?.ownedPaths ?? [];
		const unowned = dirtyPaths.filter((p) => !owned.includes(p)).sort();
		const ownership = status?.trackingError
			? `Automatic checkpoint disabled: ownership tracking failed (${status.trackingError}). Tracking re-baselines at the next clean tool boundary.`
			: unowned.length > 0
				? `The working copy carries changes the agent does not own (${unowned.join(", ")}). substrate_checkpoint commits only agent-owned paths and leaves those in place.`
				: "Automatic local checkpoint is available after direct verification. No automatic push.";
		return { systemPrompt: [...event.systemPrompt, `${SUBSTRATE_POLICY}\n${ownership}`] };
	});
	});

	// mirrors: agent-lifecycle.sh
	registerSessionLifecycle(pi);

	// mirrors: protect-paths.sh
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" && event.toolName !== "edit") return;
		const path = toolPath(event.input);
		if (!path) return;

		const abs = resolve(ctx.cwd, path);
		const root = findGateRoot(dirname(abs));
		if (!root) return;
		if (!existsSync(join(root, ".substrate", "VERSION"))) return;
		const result = await runCommand(root, [...engineBaseCmd(root), "hook", "protect-paths"], {
			stdin: JSON.stringify({ hook_event_name: "PreToolUse", tool_input: { file_path: abs } }),
		});
		return applyPolicyDecision(hookDecision(result, "blocked: protected-path guard failed"), ctx);
	});

	// mirrors: protect-command.sh — shared Bash governance policy backs Claude PreToolUse.
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
	if (!existsSync(join(root, ".substrate", "VERSION"))) return;
	const result = await runCommand(root, [...engineBaseCmd(root), "hook", "protect-command"], {
		stdin: JSON.stringify({ hook_event_name: "PreToolUse", tool_input: event.input }),
	});
		return applyPolicyDecision(hookDecision(result, "BLOCKED: Bash governance guard failed"), ctx);
	});

	// mirrors: enforce-jj.sh — substrate-managed jj repos only (plain jj repos
	// keep their own hooks); `jj git push` is sanctioned and flows to the gate.
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		if (!findGateRoot(ctx.cwd)) return;
		if (!findJjRoot(ctx.cwd)) return;
		const cmd = String(event.input.command ?? "");
		if (hasGitMutation(cmd)) {
			return blockedBash("BLOCKED: this repo is jj-managed — use substrate_checkpoint after direct verification, not direct VCS mutation (see docs/jj-workflow.md).");
		}
		if (hasRawGitPush(cmd) && !/(--tags|\sv\d)/.test(cmd)) {
			return blockedBash("BLOCKED: use 'jj git push', not 'git push', in this jj-managed repo (release tags are the exception: 'git push origin vX.Y.Z'). See docs/jj-workflow.md.");
		}
	});

	// Commits are a transaction, not an arbitrary shell command.
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash" || !findGateRoot(ctx.cwd)) return;
		const cmd = String(event.input.command ?? "");
		if (!hasDirectCommit(cmd)) return;
		return blockedBash("BLOCKED: use the substrate_checkpoint tool after direct verification. It enforces ownership, runs the gate, tightens the baseline, and commits locally.");
	});

	// mirrors: gate-before-push.sh
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		const cmd = String(event.input.command ?? "");
		if (!hasPush(cmd)) return;
		if (/\s-R\s/.test(cmd)) return;
		const root = findGateRoot(commandTargetCwd(cmd, ctx.cwd));
		if (!root) return;
		const result = await runCommand(root, [".substrate/push-gate.sh"]);
		if (result.exitCode === 0) return;
		const report = [result.stdout, result.stderr].join("\n").trim().split("\n").slice(-25).join("\n");
		return blockedBash(`blocked: push guard rejected this state\n${report}`);
	});
	// mirrors: agent-lifecycle.sh observe — feed the engine ledger after each
	// non-read-only tool call; the engine owns snapshot/fingerprint/reconcile.
	pi.on("tool_result", async (event, ctx) => {
		const root = trackingRoot(event, ctx.cwd);
		if (!root) return;
		await withRootLock(root, async () => {
			await engineEnsureStarted(root);
			await engineObserve(root);
		});
	});

	// mirrors: changed-files-scan.sh — only proven read-only tools/actions skip scanning, so unknown tools stay covered
	pi.on("tool_result", async (event, ctx) => {
		const root = trackingRoot(event, ctx.cwd);
		if (!root) return;
		const result = await runCommand(root, [...engineBaseCmd(root), "hook", "changed-files-scan"]);
		const at = new Date().toISOString();
		if (result.exitCode === 0) {
			writeRuntimeState(root, { lastScan: { status: "pass", at } });
			return;
		}
		const report = result.stderr.trim();
		writeRuntimeState(root, { lastScan: { status: "fail", at } });
		if (!report) return;
		return {
			content: [
				...event.content,
				{ type: "text", text: `\n[substrate — fix before proceeding]\n${report}` },
			],
		};
	});
}
