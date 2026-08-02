// runtime globals for the kit's TS check — Bun host + the node builtins the
// extension imports; the omp SDK itself resolves from the installed package
// (falling back to types/pi-surface.d.ts when absent — see 71-kit-tsc.sh)
declare const Bun: {
	spawnSync(
		cmd: string[],
		opts?: { cwd?: string; stdin?: unknown; stdout?: unknown; stderr?: unknown },
	): { exitCode: number; stdout: Uint8Array; stderr: Uint8Array };
};

declare const process: {
	env: Record<string, string | undefined>;
	pid: number;
};

declare module "node:fs" {
	export function readFileSync(path: string, encoding: string): string;
	export function readFileSync(path: string): Uint8Array;
	export function lstatSync(path: string): { isSymbolicLink(): boolean };
	export function realpathSync(path: string): string;
	export function existsSync(path: string): boolean;
	export function mkdirSync(path: string, options?: { recursive?: boolean; mode?: number }): string | undefined;
	export function writeFileSync(path: string, data: string, options?: { mode?: number }): void;
	export function renameSync(oldPath: string, newPath: string): void;
}

declare module "node:path" {
	export function resolve(...parts: string[]): string;
	export function relative(from: string, to: string): string;
	export function join(...parts: string[]): string;
	export function dirname(path: string): string;
	export function basename(path: string): string;
	export function isAbsolute(path: string): boolean;
}

declare module "node:crypto" {
	type Hash = {
		update(data: string | Uint8Array): Hash;
		digest(encoding: "hex"): string;
	};
	export function createHash(algorithm: string): Hash;
}

declare module "node:url" {
	export function fileURLToPath(url: string): string;
}

