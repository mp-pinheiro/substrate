// User-scoped OMP enforcement installed by `substrate bootstrap`. Repository
// behavior comes from the target repo's vendored scripts and substrate.json.
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { initializeRuntime, writeRuntimeState } from "./substrate-quality/identity";
import { registerSessionLifecycle } from "./substrate-quality/lifecycle";
import {
	callKey,
	changedBetween,
	checkpointReceipt,
	ensureTaskState,
	findGateRoot,
	findJjRoot,
	HARD,
	isReadOnlyTool,
	loadConfig,
	maintenanceCheckpointReceipt,
	pendingSnapshots,
	resolveThroughExistingParent,
	SUBSTRATE_POLICY,
	taskRuntimePatch,
	taskStates,
	toolPath,
	workingSnapshot,
	type AgentTaskState,
} from "./substrate-quality/runtime";

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
	pi.registerTool({
		name: "substrate_checkpoint",
		label: "Substrate checkpoint",
		description:
			"After direct verification, gate the exact agent-owned working paths, tighten improved metrics, and create a local commit. Never pushes.",
		parameters: checkpointParameters,
		loadMode: "essential",
		approval: "exec",
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const root = findGateRoot(ctx.cwd);
			const fail = (message: string) => ({
				content: [{ type: "text" as const, text: message }],
				details: { status: "blocked" },
				isError: true,
			});
			if (!root) return fail("checkpoint blocked: Substrate is inactive in this working directory");
			if (
				!params ||
				typeof params !== "object" ||
				!("message" in params) ||
				typeof params.message !== "string"
			) {
				return fail("checkpoint blocked: message must be a string");
			}
			const message = params.message;
			const state = ensureTaskState(root);
			const initialDirty = Object.keys(state.initial.entries);
			if (initialDirty.length > 0) {
				return fail(
					`checkpoint blocked: task began with pre-existing work (${initialDirty.join(", ")}); no paths will be committed automatically`,
				);
			}
			if (state.trackingError) {
				return fail(`checkpoint blocked: ownership tracking failed: ${state.trackingError}`);
			}
			const current = workingSnapshot(root);
			if (current.error) return fail(`checkpoint blocked: cannot inspect working copy: ${current.error}`);
			if (current.fingerprint !== state.observed.fingerprint) {
				return fail("checkpoint blocked: working copy changed outside an observed agent tool call");
			}
			const currentPaths = Object.keys(current.entries).sort();
			if (currentPaths.length === 0) return fail("checkpoint blocked: no pending agent-owned changes");
			const unowned = currentPaths.filter((path) => !state.owned.has(path));
			if (unowned.length > 0) {
				return fail(`checkpoint blocked: unowned changed paths: ${unowned.join(", ")}`);
			}
			const command = [
				join(root, ".substrate", "checkpoint.sh"),
				"--message",
				message,
				...currentPaths.flatMap((path) => ["--path", path]),
				"--json",
			];
			const proc = Bun.spawnSync(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
			const stdout = new TextDecoder().decode(proc.stdout).trim();
			const stderr = new TextDecoder().decode(proc.stderr).trim();
			const output = [stdout, stderr].filter(Boolean).join("\n");
			const summary = output.split("\n").slice(-40).join("\n");
			if (proc.exitCode !== 0) {
				const at = new Date().toISOString();
				writeRuntimeState(root, {
					lastCheckpoint: { status: "fail", at },
					...taskRuntimePatch(state),
				});
				return fail(`${summary}\ncheckpoint failed with exit ${proc.exitCode}`);
			}
			const receipt = checkpointReceipt(stdout);
			if (!receipt) return fail("checkpoint failed: transaction returned no valid receipt");
			const after = workingSnapshot(root);
			if (after.error || Object.keys(after.entries).length > 0) {
				return fail("checkpoint incomplete: transaction returned success but the working copy is not clean");
			}
			const next: AgentTaskState = {
				root,
				initial: after,
				observed: after,
				owned: new Set<string>(),
				checkpointed: true,
			};
			taskStates.set(root, next);
			writeRuntimeState(root, {
				lastCheckpoint: receipt,
				...taskRuntimePatch(next),
			});
			return {
				content: [
					{
						type: "text" as const,
						text: `Checkpoint ${receipt.commit.slice(0, 12)} passed and committed locally. No push performed.\n${summary}`,
					},
				],
				details: receipt,
			};
		},
	});

	pi.on("before_agent_start", async (event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root || event.systemPrompt.some((part) => part.includes(SUBSTRATE_POLICY))) return;
		const state = ensureTaskState(root);
		const initialDirty = Object.keys(state.initial.entries);
		const ownership = state.trackingError
			? `Automatic checkpoint disabled: ownership tracking failed (${state.trackingError}).`
			: initialDirty.length > 0
				? `Automatic checkpoint disabled: the task began dirty (${initialDirty.join(", ")}). Preserve that work and ask the user to checkpoint or clean it explicitly.`
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
		if (!/(jj\s+(commit|describe|squash)|git\s+commit)(\s|$)/.test(cmd)) return;
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
		if (event.toolName === "substrate_checkpoint" || isReadOnlyTool(event.toolName, event.input)) return;
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
		if (before.fingerprint !== state.observed.fingerprint) {
			state.trackingError = "working copy drifted before an agent tool call";
			writeRuntimeState(root, taskRuntimePatch(state));
			return;
		}
		pendingSnapshots.set(callKey(event), { root, before });
	});

	pi.on("tool_result", async (event, ctx) => {
		if (event.toolName === "substrate_checkpoint" || isReadOnlyTool(event.toolName, event.input)) return;
		const pending = pendingSnapshots.get(callKey(event));
		const path = toolPath(event.input);
		const root = pending?.root ?? findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		const state = ensureTaskState(root);
		if (!pending) {
			state.trackingError = `missing pre-tool ownership snapshot for ${event.toolName}`;
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
				state.initial = { ...state.initial, revision: after.revision };
				state.observed = after;
				state.checkpointed = true;
				state.trackingError = undefined;
				writeRuntimeState(root, {
					lastCheckpoint: maintenance,
					...taskRuntimePatch(state),
				});
				return;
			}
			const changedPaths = changedBetween(pending.before, after);
			for (const changed of changedPaths) state.owned.add(changed);
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
		if (event.toolName === "substrate_checkpoint" || isReadOnlyTool(event.toolName, event.input)) return;
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
