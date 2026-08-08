type ProbeContext = { cwd: string; ui: { notify(message: string, type: string): void } };
type ProbeEvent = Record<string, unknown>;
type ProbeHandler = (event: ProbeEvent, ctx: ProbeContext) => Promise<unknown> | unknown;
type ProbeUpdate = (partial: { content: Array<{ type: string; text?: string }> }) => void;
type ProbeTool = {
	name: string;
	execute(
		toolCallId: string,
		params: Record<string, unknown>,
		signal: undefined,
		onUpdate: ProbeUpdate | undefined,
		ctx: ProbeContext,
	): Promise<Record<string, unknown>>;
};

export function createProbe() {
	const handlers: Record<string, ProbeHandler[]> = {};
	const commands: Record<string, unknown> = {};
	const tools: Record<string, ProbeTool> = {};
	const notifications: Array<{ message: string; type: string }> = [];
	let label = "";
	const schema = (..._args: unknown[]): Record<string, never> => ({});
	const pi = {
		setLabel(value: string) {
			label = value;
		},
		on(name: string, handler: ProbeHandler) {
			(handlers[name] ??= []).push(handler);
		},
		registerCommand(name: string, command: unknown) {
			commands[name] = command;
		},
		registerTool(tool: ProbeTool) {
			tools[tool.name] = tool;
		},
		typebox: { Type: { Object: schema, String: schema, Optional: schema, Array: schema } },
	};
	function context(cwd: string): ProbeContext {
		return {
			cwd,
			ui: {
				notify(message: string, type: string) {
					notifications.push({ message, type });
				},
			},
		};
	}
	async function callAll(name: string, event: ProbeEvent, ctx: ProbeContext): Promise<unknown[]> {
		const results: unknown[] = [];
		for (const handler of handlers[name] ?? []) {
			const result = await handler(event, ctx);
			if (result) results.push(result);
		}
		return results;
	}
	async function resultAll(event: ProbeEvent, ctx: ProbeContext): Promise<unknown> {
		let current = event;
		let result: unknown = null;
		for (const handler of handlers.tool_result ?? []) {
			const next = await handler(current, ctx);
			if (next && typeof next === "object") {
				result = next;
				current = { ...current, ...next };
			}
		}
		return result;
	}
	function writeEvent(toolCallId: string, path: string): ProbeEvent {
		return {
			toolName: "write",
			toolCallId,
			input: { path },
			content: [{ type: "text", text: "write complete" }],
			isError: false,
		};
	}
	return {
		pi,
		handlers,
		commands,
		tools,
		notifications,
		context,
		callAll,
		resultAll,
		writeEvent,
		label: () => label,
	};
}

// dynamic import: probes select the kit or installed extension path at runtime
export async function bootProbe(extensionPath: string) {
	const probe = createProbe();
	const extension = await import(extensionPath);
	extension.default(probe.pi);
	return probe;
}