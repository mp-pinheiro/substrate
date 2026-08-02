import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import {
	engineVersion,
	ensureTaskState,
	findGateRoot,
	refreshReport,
	taskRuntimePatch,
} from "./runtime";

const IDENTITY_PATH = fileURLToPath(import.meta.url);
const EXTENSION_PATH = resolve(dirname(IDENTITY_PATH), "..", "substrate-quality.ts");
const EXTENSION_HASH = createHash("sha256")
	.update(readFileSync(EXTENSION_PATH))
	.update(readFileSync(join(dirname(IDENTITY_PATH), "runtime.ts")))
	.update(readFileSync(join(dirname(IDENTITY_PATH), "lifecycle.ts")))
	.update(readFileSync(IDENTITY_PATH))
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

function writeRuntimeState(root: string, patch: Record<string, unknown> = {}): boolean {
	if (!RUNTIME_PATH) return false;
	try {
		const state = {
			...runtimeState(),
			extensionPath: realpathSync(EXTENSION_PATH),
			extensionHash: EXTENSION_HASH,
			engineVersion: engineVersion(root),
			repoRoot: root,
			updatedAt: new Date().toISOString(),
			...patch,
		};
		mkdirSync(dirname(RUNTIME_PATH), { recursive: true, mode: 0o700 });
		const staged = `${RUNTIME_PATH}.${process.pid}.tmp`;
		writeFileSync(staged, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
		renameSync(staged, RUNTIME_PATH);
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
	const state = runtimeState();
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
		const reportWarning = refreshReport(root);
		if (reportWarning) ctx.ui.notify(`Substrate ${reportWarning}`, "warning");
		const state = ensureTaskState(root);
		writeRuntimeState(root, { loadedAt: new Date().toISOString(), ...taskRuntimePatch(state) });
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
