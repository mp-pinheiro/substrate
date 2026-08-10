import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { engineVersion, findGateRoot, refreshReport } from "./policy";
import { engineEnsureStarted, engineObserve, readRuntimeState, runtimeStatePath, withRootLock } from "./runtime";

const IDENTITY_PATH = fileURLToPath(import.meta.url);
const MODULE_ROOT = dirname(IDENTITY_PATH);
const EXTENSION_PATH = resolve(MODULE_ROOT, "..", "substrate-quality.ts");
const EXTENSION_HASH = createHash("sha256")
	.update(readFileSync(EXTENSION_PATH))
	.update(readFileSync(join(MODULE_ROOT, "runtime.ts")))
	.update(readFileSync(join(MODULE_ROOT, "lifecycle.ts")))
	.update(readFileSync(IDENTITY_PATH))
	.update(readFileSync(join(MODULE_ROOT, "policy.ts")))
	.update(readFileSync(join(MODULE_ROOT, "transactions.ts")))
	.update(readFileSync(join(MODULE_ROOT, "restructure.ts")))
	.digest("hex");
const RUNTIME_PATH = process.env.HOME ? join(process.env.HOME, ".omp", "run", "substrate-quality.json") : null;

function runtimeState(): Record<string, unknown> {
	if (!RUNTIME_PATH) return {};
	try {
		return JSON.parse(readFileSync(RUNTIME_PATH, "utf8"));
	} catch {
		return {};
	}
}

function writeJsonState(path: string, state: Record<string, unknown>): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	const staged = `${path}.${process.pid}.tmp`;
	writeFileSync(staged, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
	renameSync(staged, path);
}

// The global file carries only install identity (verify/doctor contract);
// task state lives in one file per repo root so repos cannot clobber each other.
function writeRuntimeState(root: string, patch: Record<string, unknown> = {}): boolean {
	if (!RUNTIME_PATH) return false;
	try {
		const identity = {
			extensionPath: realpathSync(EXTENSION_PATH),
			extensionHash: EXTENSION_HASH,
			engineVersion: engineVersion(root),
			repoRoot: root,
			updatedAt: new Date().toISOString(),
		};
		writeJsonState(RUNTIME_PATH, { ...runtimeState(), ...identity });
		const perRoot = runtimeStatePath(root);
		if (perRoot) writeJsonState(perRoot, { ...readRuntimeState(root), ...identity, ...patch });
		return true;
	} catch {
		return false;
	}
}

function runtimeSummary(cwd: string): string {
	const root = findGateRoot(cwd);
	if (!root) {
		return `Substrate inactive in ${cwd}\nExtension: ${EXTENSION_PATH}\nSHA-256: ${EXTENSION_HASH}`;
	}
	writeRuntimeState(root);
	const state = readRuntimeState(root);
	const scan = state.lastScan as { status?: string; at?: string } | undefined;
	const checkpoint = state.lastCheckpoint as { status?: string; at?: string } | undefined;
	return [
		`Substrate active in ${root}`,
		`Extension: ${state.extensionPath ?? EXTENSION_PATH}`,
		`SHA-256: ${state.extensionHash ?? EXTENSION_HASH}`,
		`Engine: ${state.engineVersion ?? engineVersion(root)}`,
		`Last scan: ${scan?.status ?? "none"}${scan?.at ? ` at ${scan.at}` : ""}`,
		`Last checkpoint: ${checkpoint?.status ?? "none"}${checkpoint?.at ? ` at ${checkpoint.at}` : ""}`,
	].join("\n");
}

function initializeRuntime(pi: ExtensionAPI): boolean {
	const global = globalThis as typeof globalThis & { __substrateQualityLoaded?: boolean };
	if (global.__substrateQualityLoaded) return false;
	global.__substrateQualityLoaded = true;
	pi.setLabel(`Substrate ${EXTENSION_HASH.slice(0, 8)}`);
	pi.on("session_start", async (_event, ctx) => {
		const root = findGateRoot(ctx.cwd);
		if (!root) return;
		// report.sh's write_report stages into a gitignored temp file (see
		// core/report.sh ensure_report_ignored), so this can run unlocked.
		const reportWarning = await refreshReport(root);
		await withRootLock(root, async () => {
			await engineEnsureStarted(root);
			await engineObserve(root);
			writeRuntimeState(root, { loadedAt: new Date().toISOString() });
		});
		if (reportWarning) ctx.ui.notify(`Substrate ${reportWarning}`, "warning");
		ctx.ui.notify(`Substrate active · ${EXTENSION_HASH.slice(0, 8)} · ${root}`, "info");
	});
	pi.registerCommand("substrate", {
		description: "Show the active Substrate runtime",
		handler: async (_args, ctx) => {
			ctx.ui.notify(runtimeSummary(ctx.cwd), "info");
		},
	});
	return true;
}

export { initializeRuntime, writeRuntimeState };
