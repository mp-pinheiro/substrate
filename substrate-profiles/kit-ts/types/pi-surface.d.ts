// RECORDED omp SDK surface — used ONLY when the installed
// @oh-my-pi/pi-coding-agent package is not resolvable (e.g. CI). A green run
// against this file means "internally consistent with the recorded surface",
// NOT "conforms to the installed omp API"; 71-kit-tsc prints which mode ran.
declare module "@oh-my-pi/pi-coding-agent" {
	export type ToolContent = { type: string; text?: string };
	export type ToolEvent = {
		toolName: string;
		input: Record<string, unknown>;
		isError?: boolean;
		content: ToolContent[];
	};
	export type ToolCtx = { cwd: string };
	export type HookResult =
		| { block: boolean; reason: string }
		| { content: ToolContent[] }
		| undefined;
	export type ExtensionAPI = {
		setLabel(label: string): void;
		on(
			event: "tool_call" | "tool_result",
			fn: (event: ToolEvent, ctx: ToolCtx) => Promise<HookResult> | HookResult,
		): void;
	};
}
