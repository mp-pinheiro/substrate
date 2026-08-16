import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const SUBSTRATE_POLICY = [
	"This repository is governed by Substrate's deterministic quality gate.",
	"Treat every `[substrate — fix before proceeding]` report as blocking: resolve it before unrelated work.",
	"For workflow-health requests, run `substrate verify` directly and unmodified; do not assemble ad hoc test batteries or run `substrate audit` unless the user explicitly requests committed-plan regression.",
	"Run only direct verification relevant to the requested change.",
	"After direct verification, call `substrate_checkpoint`; it gates, tightens improved metrics, and commits only agent-owned paths.",
	"Never run `jj commit` or `git commit` directly. Never push automatically; publication remains user-owned.",
	"Do not bypass checks, edit generated or protected assets, or relax the baseline unless the user explicitly requests that policy change.",
	"Treat substrate.json as human-approved policy: do not mutate it as an agent; only change it through guarded maintenance when the user explicitly directs the policy decision.",
	"Before accepting a ratchet regression, cost the alternative refactor and present both options; accepting requires a written reason that is committed to substrate-baseline.json.",
].join("\n");

// walk up for the vendored gate so subdirectory sessions resolve the repo
function findGateRoot(cwd: string): string | null {
	let dir = resolve(cwd);
	for (;;) {
		if (existsSync(join(dir, ".substrate", "VERSION"))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function engineVersion(root: string): string {
	try {
		return readFileSync(join(root, ".substrate", "VERSION"), "utf8").trim();
	} catch {
		return "unknown";
	}
}
// jj hooks are runtime-gated: active only when the repo root carries .jj
function findJjRoot(cwd: string): string | null {
	let dir = resolve(cwd);
	for (;;) {
		if (existsSync(join(dir, ".jj"))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function toolPath(input: object): string {
	if ("path" in input && typeof input.path === "string") return input.path;
	if ("file_path" in input && typeof input.file_path === "string") return input.file_path;
	if ("file" in input && typeof input.file === "string") return input.file;
	return "";
}

type CommandResult = { exitCode: number; stdout: string; stderr: string };

async function readStream(
	stream: ReadableStream<Uint8Array>,
	onLine?: (line: string) => void,
): Promise<string> {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let text = "";
	let consumed = 0;
	for (;;) {
		const chunk = await reader.read();
		if (chunk.done) break;
		text += decoder.decode(chunk.value, { stream: true });
		if (!onLine) continue;
		for (let nl = text.indexOf("\n", consumed); nl !== -1; nl = text.indexOf("\n", consumed)) {
			onLine(text.slice(consumed, nl));
			consumed = nl + 1;
		}
	}
	text += decoder.decode();
	if (onLine && consumed < text.length) onLine(text.slice(consumed));
	return text;
}

// spawnSync blocked the Bun event loop the omp TUI renders on: a checkpoint's
// two gate batteries froze the pane for ~25s.
async function runCommand(
	root: string,
	command: string[],
	options: { stdin?: string; onLine?: (line: string) => void; signal?: AbortSignal } = {},
): Promise<CommandResult> {
	const proc = Bun.spawn(command, {
		cwd: root,
		stdin: options.stdin === undefined ? "ignore" : new TextEncoder().encode(options.stdin),
		stdout: "pipe",
		stderr: "pipe",
		signal: options.signal,
		// the engine's grandchild workers inherit its stdout/stderr pipes; killing
		// only `proc` leaves them open. detached makes proc the process-group leader.
		detached: true,
	});
	const killTree = () => {
		try {
			process.kill(-proc.pid, "SIGKILL");
		} catch {
			proc.kill();
		}
	};
	options.signal?.addEventListener("abort", killTree, { once: true });
	try {
		// draining one pipe to completion first deadlocks a child that fills the other
		const [stdout, stderr] = await Promise.all([
			readStream(proc.stdout, options.onLine),
			readStream(proc.stderr, options.onLine),
		]);
		return { exitCode: await proc.exited, stdout, stderr };
	} catch (failure) {
		// a rejected drain must not leave a live VCS transaction tree behind
		killTree();
		await proc.exited;
		throw failure;
	} finally {
		options.signal?.removeEventListener("abort", killTree);
	}
}

async function refreshReport(root: string): Promise<string | null> {
	const report = join(root, ".substrate", "report.sh");
	if (!existsSync(report)) return null;
	const result = await runCommand(root, [report, "--refresh"]);
	const stderr = result.stderr.trim();
	if (result.exitCode !== 0) return stderr || `report refresh exited ${result.exitCode}`;
	return stderr || null;
}

export {
	engineVersion,
	findGateRoot,
	findJjRoot,
	refreshReport,
	runCommand,
	SUBSTRATE_POLICY,
	toolPath,
};
export type { CommandResult };
