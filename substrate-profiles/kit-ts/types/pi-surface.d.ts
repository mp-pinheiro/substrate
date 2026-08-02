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
	export type ToolCtx = {
		cwd: string;
		ui: { notify(message: string, level: "info" | "warning" | "error"): void };
	};
	export type BeforeAgentStartEvent = { systemPrompt: string[] };
	export type BeforeAgentStartResult = { systemPrompt: string[] } | undefined;
	export type SessionStopEvent = { stop_hook_active: boolean };
	export type SessionStopResult =
		| {
				continue?: boolean;
				additionalContext?: string;
				decision?: "block";
				reason?: string;
		  }
		| undefined;
	export type HookResult =
		| { block: boolean; reason: string }
		| { content: ToolContent[] }
		| undefined;
	export type ExtensionAPI = {
		setLabel(label: string): void;
		typebox: {
			Type: {
				String(options?: Record<string, unknown>): unknown;
				Object(
					shape: Record<string, unknown>,
					options?: Record<string, unknown>,
				): unknown;
			};
		};
		on(
			event: "tool_call" | "tool_result",
			fn: (event: ToolEvent, ctx: ToolCtx) => Promise<HookResult> | HookResult,
		): void;
		on(
			event: "session_start",
			fn: (event: Record<string, never>, ctx: ToolCtx) => Promise<void> | void,
		): void;
		on(
			event: "session_stop",
			fn: (
				event: SessionStopEvent,
				ctx: ToolCtx,
			) => Promise<SessionStopResult> | SessionStopResult,
		): void;
		on(
			event: "before_agent_start",
			fn: (
				event: BeforeAgentStartEvent,
				ctx: ToolCtx,
			) => Promise<BeforeAgentStartResult> | BeforeAgentStartResult,
		): void;
		registerTool(tool: {
			name: string;
			label: string;
			description: string;
			parameters: unknown;
			loadMode?: "essential" | "discoverable";
			approval?: "read" | "write" | "exec";
			execute(
				toolCallId: string,
				params: unknown,
				signal: unknown,
				onUpdate: unknown,
				ctx: ToolCtx,
			): Promise<{ content: ToolContent[]; details?: unknown; isError?: boolean }>;
		}): void;
		registerCommand(
			name: string,
			options: {
				description?: string;
				handler: (args: string, ctx: ToolCtx) => Promise<void> | void;
			},
		): void;
	};
}
