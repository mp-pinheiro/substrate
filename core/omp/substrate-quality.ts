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
			acceptRegression: pi.typebox.Type.Optional(
				pi.typebox.Type.Array(pi.typebox.Type.String(), {
					description:
						"Ratcheted metric keys whose regression the user reviewed and accepted, e.g. [\"max_file_lines\"]. Omit unless the gate reported that exact key regressed.",
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
			let acceptRegression: string[] = [];
			if ("acceptRegression" in params && params.acceptRegression !== undefined) {
				const raw = params.acceptRegression;
				if (!Array.isArray(raw) || raw.some((k) => typeof k !== "string" || !/^[A-Za-z0-9._:/-]+$/.test(k))) {
					return blockedToolResult(
						"checkpoint blocked: acceptRegression must be an array of metric keys matching [A-Za-z0-9._:/-]+",
					);
				}
				acceptRegression = raw as string[];
			}
			let reason: string | undefined;
			if ("acceptRegressionReason" in params && params.acceptRegressionReason !== undefined) {
				const rawReason = params.acceptRegressionReason;
				if (typeof rawReason !== "string") {
					return blockedToolResult("checkpoint blocked: acceptRegressionReason must be a string");
				}
				reason = rawReason;
			}
			if (acceptRegression.length > 0 && !reason) {
				return blockedToolResult(
					"checkpoint blocked: --accept-regression requires --reason \"<text>\" — the justification is committed to substrate-baseline.json",
				);
			}
			if (reason && acceptRegression.length === 0) {
				return blockedToolResult("checkpoint blocked: --reason applies only to --accept-regression");
			}
			if (reason) {
				if (reason.length < 20) {
					return blockedToolResult("checkpoint blocked: --reason must be at least 20 characters");
				}
				if (/[;&|<>$`\n]/.test(reason)) {
					return blockedToolResult(
						"checkpoint blocked: --reason must not contain ; & | < > $ ` or a newline",
					);
				}
			}
			const status = await withRootLock(root, () => engineStatus(root));
			const pendingOwned = status?.pendingOwned ?? [];
			const dirtyPaths = status?.dirtyPaths ?? [];
			const leftover = dirtyPaths.filter((p) => !pendingOwned.includes(p)).sort();
			if (pendingOwned.length === 0) {
				return blockedToolResult(
					leftover.length > 0
						? `checkpoint blocked: no pending agent-owned changes; unowned pending paths stay in place: ${leftover.join(", ")}`
						: "checkpoint blocked: no pending agent-owned changes",
				);
			}
			const sid = sessionId(root);
			const result = await runCheckpointTransaction(root, sid, message, acceptRegression, reason, io);
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
	if (!existsSync(join(root, ".substrate", "VERSION"))) return;
	const result = await runCommand(root, [...engineBaseCmd(root), "hook", "protect-command"], {
		stdin: JSON.stringify({ tool_input: event.input }),
	});
		if (result.exitCode === 0) return;
		return {
			block: true,
			reason: result.stderr.trim() || `BLOCKED: Bash governance guard failed with exit ${result.exitCode}`,
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
		const result = await runCommand(root, [".substrate/push-gate.sh"]);
		if (result.exitCode === 0) return;
		const report = [result.stdout, result.stderr].join("\n").trim().split("\n").slice(-25).join("\n");
		return {
			block: true,
			reason: `blocked: push guard rejected this state\n${report}`,
		};
	});

	// mirrors: agent-lifecycle.sh observe — feed the engine ledger after each
	// non-read-only tool call; the engine owns snapshot/fingerprint/reconcile.
	pi.on("tool_result", async (event, ctx) => {
		if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return;
		const path = toolPath(event.input);
		const root = findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		if (!existsSync(join(root, ".substrate", "VERSION"))) return;
		await withRootLock(root, async () => {
			await engineEnsureStarted(root);
			await engineObserve(root);
		});
	});

	// mirrors: changed-files-scan.sh — only proven read-only tools/actions skip scanning, so unknown tools stay covered
	pi.on("tool_result", async (event, ctx) => {
		if (GATE_TOOLS[event.toolName] || isReadOnlyTool(event.toolName, event.input)) return;
		const path = toolPath(event.input);
		const root = findGateRoot(path ? dirname(resolve(ctx.cwd, path)) : ctx.cwd);
		if (!root) return;
		if (!existsSync(join(root, ".substrate", "VERSION"))) return;
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
