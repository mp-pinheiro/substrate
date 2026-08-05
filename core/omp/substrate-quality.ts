// User-scoped OMP enforcement installed by `substrate bootstrap`. Repository
// behavior comes from the target repo's vendored scripts and substrate.json.
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { initializeRuntime, writeRuntimeState } from "./substrate-quality/identity";
import { registerSessionLifecycle } from "./substrate-quality/lifecycle";
import {
	findGateRoot,
	findJjRoot,
	HARD,
	loadConfig,
	resolveThroughExistingParent,
	SUBSTRATE_POLICY,
	toolPath,
} from "./substrate-quality/policy";
import { registerRestructureTool } from "./substrate-quality/restructure";
import {
	callKey,
	changedBetween,
	checkpointedState,
	ensureTaskState,
	isReadOnlyTool,
	pendingSnapshots,
	rebaseline,
	reconcileInitial,
	taskPreconditions,
	taskRuntimePatch,
	taskStates,
	workingSnapshot,
} from "./substrate-quality/runtime";
import {
	blockedToolResult,
	maintenanceCheckpointReceipt,
	registerGateTool,
	runCheckpointTransaction,
} from "./substrate-quality/transactions";

const GATE_TOOLS: Record<string, true> = { substrate_checkpoint: true, substrate_restructure: true };

export default function substrateQuality(pi: ExtensionAPI): void {
	if (!initializeRuntime(pi)) return;

	const checkpointParameters = pi.typebox.Type.Object(
		{
			message: pi.typebox.Type.String({
				description: "Conventional Commit message: type(scope): subject",
			}),
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
				"After direct verification, gate the exact agent-owned working paths, tighten improved metrics, and create a local commit. Never pushes.",
			parameters: checkpointParameters,
			blockedPrefix: "checkpoint",
		},
		async (root, params) => {
			if (
				!params ||
				typeof params !== "object" ||
				!("message" in params) ||
				typeof params.message !== "string"
			) {
				return blockedToolResult("checkpoint blocked: message must be a string");
			}
			const message = params.message;
			const check = taskPreconditions(root);
			if (check.failure) return blockedToolResult(`checkpoint blocked: ${check.failure}`);
			const state = check.state;
			const currentPaths = Object.keys(check.current.entries).sort();
			const ownedPending = currentPaths.filter((path) => state.owned.has(path));
			const leftover = currentPaths.filter((path) => !state.owned.has(path));
			if (ownedPending.length === 0) {
				return blockedToolResult(
					leftover.length > 0
						? `checkpoint blocked: no pending agent-owned changes; unowned pending paths stay in place: ${leftover.join(", ")}`
						: "checkpoint blocked: no pending agent-owned changes",
				);
			}
			const result = runCheckpointTransaction(root, ownedPending, message);
			const summary = result.summary;
			if (!result.receipt) {
				writeRuntimeState(root, {
					lastCheckpoint: { status: "fail", at: new Date().toISOString() },
					...taskRuntimePatch(state),
				});
				return blockedToolResult(
					result.ok ? `${summary}\ncheckpoint failed: transaction returned no valid receipt` : summary,
				);
			}
			const receipt = result.receipt;
			const after = workingSnapshot(root);
			if (after.error) {
				return blockedToolResult(
					`checkpoint incomplete: cannot inspect the working copy after commit: ${after.error}`,
				);
			}
			const stillOwned = Object.keys(after.entries).filter((path) => state.owned.has(path));
			if (stillOwned.length > 0) {
				return blockedToolResult(
					`checkpoint incomplete: transaction returned success but owned paths are still pending: ${stillOwned.join(", ")}`,
				);
			}
			const next = checkpointedState(root, after, state, receipt.commit);
			taskStates.set(root, next);
			writeRuntimeState(root, {
				lastCheckpoint: receipt,
				...taskRuntimePatch(next),
			});
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

	registerRestructureTool(pi);

	pi.on("before_agent_start", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root || event.systemPrompt.some((part) => part.includes(SUBSTRATE_POLICY))) return;
		const state = ensureTaskState(root);
		const current = workingSnapshot(root);
		if (current.error) {
			state.trackingError = current.error;
		} else if (state.trackingError || current.fingerprint !== state.observed.fingerprint) {
			rebaseline(state, current);
		}
		writeRuntimeState(root, taskRuntimePatch(state));
		const unowned = Object.keys(state.observed.entries)
			.filter((path) => !state.owned.has(path))
			.sort();
		const ownership = state.trackingError
			? `Automatic checkpoint disabled: ownership tracking failed (${state.trackingError}). Tracking re-baselines at the next clean tool boundary.`
			: unowned.length > 0
				? `The working copy carries changes the agent does not own (${unowned.join(", ")}). substrate_checkpoint commits only agent-owned paths and leaves those in place.`
				: "Automatic local checkpoint is available after direct verification. No automatic push.";
		return { systemPrompt: [...event.systemPrompt, `${SUBSTRATE_POLICY}\n${ownership}`] };
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
		const cfg = loadConfig(root);
		if (!cfg.ok) {
			return { block: true, reason: "blocked: substrate.json is corrupt — fix it before writing anything else" };
		}
		if (cfg.contractsInvalid) {
			return {
				block: true,
				reason: "blocked: substrate.json contracts entries need name/regen/paths — fix the config",
			};
		}
		try {
			if (lstatSync(abs).isSymbolicLink()) {
				let target = "unknown";
				try {
					target = realpathSync(abs);
				} catch {}
				return {
					block: true,
					reason: `blocked: ${path} is a symlink to ${target} — writing through it clobbers the target; edit the target explicitly if that is intended`,
				};
			}
		} catch {}

		const rel = relative(root, abs);
		const real = relative(root, resolveThroughExistingParent(abs));
		if (real.startsWith("..") || isAbsolute(real)) {
			return {
				block: true,
				reason: `blocked: ${path} resolves outside the repo (${real}) — a parent directory is a symlink`,
			};
		}

		for (const [re, why] of HARD) {
			if (re.test(rel) || re.test(real)) {
				return { block: true, reason: `blocked: ${rel} — ${why}` };
			}
		}
		for (const re of cfg.protectedGlobs) {
			if (re.test(rel) || re.test(real)) {
				return { block: true, reason: `blocked: ${rel} is protected by substrate.json protected_paths` };
			}
		}
		for (const p of cfg.contractPaths) {
			if (rel === p || rel.startsWith(`${p}/`) || real === p || real.startsWith(`${p}/`)) {
				return {
					block: true,
					reason: `blocked: ${rel} is generated from a contract — edit the contract source; the gate regenerates (substrate.json contracts)`,
				};
			}
		}
	});

	// mirrors: protect-command.sh — shared Bash governance policy backs Claude PreToolUse.
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		const hook = join(root, ".substrate", "hooks", "protect-command.sh");
		if (!existsSync(hook)) return;
		const proc = Bun.spawnSync([hook], {
			cwd: root,
			stdin: new TextEncoder().encode(JSON.stringify({ tool_input: event.input })),
			stdout: "pipe",
			stderr: "pipe",
		});
		if (proc.exitCode === 0) return;
		const reason = new TextDecoder().decode(proc.stderr).trim();
		return {
			block: true,
			reason: reason || `BLOCKED: Bash governance guard failed with exit ${proc.exitCode}`,
		};
	});

	// mirrors: enforce-jj.sh
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		if (!findJjRoot(ctx.cwd)) return;
		const cmd = String(event.input.command ?? "").replaceAll(/jj\s+git/g, "JJ_GIT");
		if (/git\s+(commit|add|rebase|merge|reset|restore|switch|checkout|cherry-pick|revert|stash|clean|am|apply)([\s"\\]|$)/.test(cmd)) {
			return {
				block: true,
				reason: "BLOCKED: this repo is jj-managed — use jj, not git, for VCS changes: 'jj commit -m', 'jj tug', 'jj git push' (see docs/jj-workflow.md). Read-only git (log/status/diff/show) and release 'git tag' are fine.",
			};
		}
		if (/git\s+push/.test(cmd) && !/(--tags|\sv\d)/.test(cmd)) {
			return {
				block: true,
				reason: "BLOCKED: use 'jj git push', not 'git push', in this jj-managed repo (release tags are the exception: 'git push origin vX.Y.Z'). See docs/jj-workflow.md.",
			};
		}
	});

	// Commits are a transaction, not an arbitrary shell command.
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash" || !findGateRoot(ctx.cwd)) return;
		const cmd = String(event.input.command ?? "");
		if (!/(^|[;&|(`]\s*)(jj\s+(commit|describe|squash)|git\s+commit)(\s|$)/m.test(cmd)) return;
		return {
			block: true,
			reason:
				"BLOCKED: use the substrate_checkpoint tool after direct verification. It enforces ownership, runs the gate, tightens the baseline, and commits locally.",
		};
	});

	// mirrors: gate-before-push.sh
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		const cmd = String(event.input.command ?? "");
		if (!/(^|[;&|]\s*|\s)(jj\s+git\s+push|git\s+push)\b/.test(cmd)) return;
		if (/\s-R\s/.test(cmd)) return;
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		const proc = Bun.spawnSync([".substrate/push-gate.sh"], {
			cwd: root,
			stdout: "pipe",
			stderr: "pipe",
		});
		if (proc.exitCode === 0) return;
		const report = [
			new TextDecoder().decode(proc.stdout),
			new TextDecoder().decode(proc.stderr),
		]
			.join("\n")
			.trim()
			.split("\n")
			.slice(-25)
			.join("\n");
		return {
			block: true,
			reason: `blocked: push guard rejected this state\n${report}`,
		};
	});

	pi.on("tool_call", async (event, ctx) => {
		if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return;
		const path = toolPath(event.input);
		const root = findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		const state = ensureTaskState(root);
		const before = workingSnapshot(root);
		if (before.error) {
			state.trackingError = before.error;
			writeRuntimeState(root, taskRuntimePatch(state));
			return;
		}
		if (state.trackingError || before.fingerprint !== state.observed.fingerprint) {
			rebaseline(state, before);
			writeRuntimeState(root, taskRuntimePatch(state));
		}
		pendingSnapshots.set(callKey(event), { root, before });
	});

	pi.on("tool_result", async (event, ctx) => {
		if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return;
		const pending = pendingSnapshots.get(callKey(event));
		const path = toolPath(event.input);
		const root = pending?.root ?? findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		const state = ensureTaskState(root);
		if (!pending) {
			state.trackingError ??= `missing pre-tool ownership snapshot for ${event.toolName}`;
			writeRuntimeState(root, taskRuntimePatch(state));
			return;
		}
		pendingSnapshots.delete(callKey(event));
		const after = workingSnapshot(root);
		if (after.error) {
			state.trackingError = after.error;
		} else {
			const maintenance =
				pending.before.revision !== after.revision
					? maintenanceCheckpointReceipt(root, pending.before, after)
					: null;
			if (maintenance) {
				reconcileInitial(state, after);
				state.observed = after;
				state.checkpointed = true;
				state.trackingError = undefined;
				state.driftNotice = undefined;
				writeRuntimeState(root, {
					lastCheckpoint: maintenance,
					...taskRuntimePatch(state),
				});
				return;
			}
			const changedPaths = changedBetween(pending.before, after);
			reconcileInitial(state, after);
			for (const changed of changedPaths) {
				if (!(changed in state.initial.entries)) state.owned.add(changed);
			}
			for (const ownedPath of state.owned) {
				if (!(ownedPath in after.entries)) state.owned.delete(ownedPath);
			}
			if (pending.before.revision !== after.revision) {
				state.trackingError = "repository revision changed outside the checkpoint transaction";
			}
			if (changedPaths.length > 0) state.checkpointed = false;
			state.observed = after;
		}
		writeRuntimeState(root, taskRuntimePatch(state));
	});

	// mirrors: changed-files-scan.sh — only proven read-only tools/actions skip scanning, so unknown tools stay covered
	pi.on("tool_result", async (event, ctx) => {
		if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return;
		const path = toolPath(event.input);
		const root = findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		// pre-cutover vendored copies lack the hook — never throw ENOENT machine-wide
		if (!existsSync(join(root, ".substrate", "hooks", "changed-files-scan.sh"))) return;
		const proc = Bun.spawnSync([".substrate/hooks/changed-files-scan.sh"], {
			cwd: root,
			stdout: "pipe",
			stderr: "pipe",
		});
		const at = new Date().toISOString();
		if (proc.exitCode === 0) {
			writeRuntimeState(root, { lastScan: { status: "pass", at } });
			return;
		}
		const report = new TextDecoder().decode(proc.stderr).trim();
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
