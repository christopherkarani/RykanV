import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import {
	allowOnceBypassEnabled,
	askOptionsFor,
	buildDecideFilePayload,
	buildDecideToolPayload,
	buildEvaluateRequest,
	extractDecideFilePath,
	installRykExtension,
	isProtectedPiTool,
	isSubagentSession,
	piCoverageLabel,
	resolveOrcaBin,
	resolveToolPath,
	resolveUnavailableMode,
	formatProtocolErrorReason,
	protocolFailureClassFromReason,
	isTransientProtocolFailure,
	allowWithWarningPermitsProtocolClass,
	runOrcaDecideFile,
	runOrcaDecideTool,
	runOrcaEvaluate,
	safeOrcaReason,
	shouldAutoDenyPolicyAsk,
	PROTOCOL_DEGRADED_THRESHOLD,
	type OrcaEvaluateRequest,
} from "../extensions/ryk.ts";

type Handler = (event: any, ctx: any) => Promise<any> | any;

const packageJson = JSON.parse(
	readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as {
	dependencies: Record<string, string>;
};
const requiredRuntimeVersion =
	packageJson.dependencies["@rykan/ryk"] ??
	packageJson.dependencies["@rykan/ryk"];

class FakeChild {
	stdinWrites: string[] = [];
	stdout = new EventEmitter();
	stderr = new EventEmitter();
	stdin = {
		write: (data: string) => {
			this.stdinWrites.push(data);
		},
		end: () => {},
	};
	private emitter = new EventEmitter();

	on(event: "error" | "close", handler: (...args: any[]) => void): void {
		this.emitter.on(event, handler);
	}

	close(code: number | null): void {
		this.emitter.emit("close", code);
	}

	fail(error: Error): void {
		this.emitter.emit("error", error);
	}
}

function makeSpawn(
	plans: Array<{
		code?: number | null;
		stdout?: string;
		stderr?: string;
		error?: Error;
		run?: (call: {
			file: string;
			args: string[];
			options: any;
			stdin: string[];
		}) => void;
	}> = [],
) {
	const calls: Array<{
		file: string;
		args: string[];
		options: any;
		stdin: string[];
	}> = [];
	const spawn = (file: string, args: string[], options: any): FakeChild => {
		const child = new FakeChild();
		const call = { file, args, options, stdin: child.stdinWrites };
		calls.push(call);
		const plan = plans.shift() ?? { code: 0, stdout: allowJson() };
		queueMicrotask(() => {
			plan.run?.(call);
			if (plan.stdout) child.stdout.emit("data", plan.stdout);
			if (plan.stderr) child.stderr.emit("data", plan.stderr);
			if (plan.error) child.fail(plan.error);
			else child.close(plan.code === undefined ? 0 : plan.code);
		});
		return child;
	};
	return { spawn, calls };
}

async function flushAsyncWork(): Promise<void> {
	await new Promise<void>((resolvePromise) => setImmediate(resolvePromise));
	await new Promise<void>((resolvePromise) => setImmediate(resolvePromise));
}

function makePi() {
	const handlers = new Map<string, Handler[]>();
	const commands = new Map<
		string,
		{ handler: (args: string | undefined, ctx: any) => Promise<void> | void }
	>();
	const messages: Array<{
		message: {
			customType: string;
			content: string;
			display: boolean;
			details?: unknown;
		};
		options?: { triggerTurn?: boolean; deliverAs?: string };
	}> = [];
	const pi = {
		on(event: string, handler: Handler) {
			const list = handlers.get(event) ?? [];
			list.push(handler);
			handlers.set(event, list);
		},
		registerCommand(name: string, options: any) {
			commands.set(name, options);
		},
		sendMessage(message: any, options?: any) {
			messages.push({ message, options });
		},
	};
	return { pi, handlers, commands, messages };
}

function makeCtx(overrides: Record<string, unknown> = {}) {
	const notifications: Array<{ message: string; type?: string }> = [];
	const statuses: Array<{ key: string; text: string | undefined }> = [];
	const widgets: Array<{
		key: string;
		value: string[] | undefined;
		opts?: { placement?: "aboveEditor" | "belowEditor" };
	}> = [];
	const selections: string[] = [];
	const ctx = {
		cwd: process.cwd(),
		mode: "tui",
		hasUI: true,
		sessionManager: { getSessionId: () => "session-a" },
		ui: {
			notify: (message: string, type?: string) =>
				notifications.push({ message, type }),
			setStatus: (key: string, text: string | undefined) =>
				statuses.push({ key, text }),
			setWidget: (
				key: string,
				value: undefined | string[],
				opts?: { placement?: "aboveEditor" | "belowEditor" },
			) => widgets.push({ key, value, opts }),
			select: async () => selections.shift(),
		},
		...overrides,
	};
	return { ctx, notifications, statuses, widgets, selections };
}

function allowJson(): string {
	return JSON.stringify({
		decision: "allow",
		reason: "Command allowed",
		daemon: { status: "healthy", compatible: true },
	});
}

function denyJson(): string {
	return JSON.stringify({
		decision: "deny",
		reason: "destructive filesystem command",
		rule_id: "core.filesystem:destructive-rm",
		daemon: { status: "healthy", compatible: true },
	});
}

function askJson(): string {
	return JSON.stringify({
		decision: "ask",
		reason: "requires approval in ask mode; would deny in strict",
		severity: "high",
		rule_id: "core.git:force-push",
		daemon: { status: "healthy", compatible: true },
	});
}

function errorJson(): string {
	return JSON.stringify({
		decision: "error",
		reason: "daemon is unavailable for shell-command evaluation",
		error: { code: "daemon_unavailable", message: "daemon unavailable" },
	});
}

test("resolveOrcaBin honors executable RYK_BIN before other candidates", () => {
	const result = resolveOrcaBin({
		env: { RYK_BIN: "/trusted/ryk" },
		bundledPackageRoot: "/package",
		isExecutable: (path) => path === "/trusted/ryk",
		isCompatiblePathOrca: () => true,
	});

	assert.deepEqual(result, { rykBin: "/trusted/ryk", source: "explicit" });
});

test("resolveOrcaBin prefers RYK_BIN over RYK_BIN", () => {
	const result = resolveOrcaBin({
		env: { RYK_BIN: "/trusted/ryk", RYK_BIN: "/trusted/ryk" },
		bundledPackageRoot: "/package",
		isExecutable: (path) => path === "/trusted/ryk" || path === "/trusted/ryk",
		isCompatiblePathOrca: () => true,
	});
	assert.deepEqual(result, { rykBin: "/trusted/ryk", source: "explicit" });
});

test("resolveOrcaBin prefers the bundled runtime and requires opt-in for PATH", () => {
	const defaults = {
		bundledPackageRoot: "/package",
		// Prefer ryk vendor binary when present (Phase 5a).
		isExecutable: (path: string) =>
			path.includes("/vendor/ryk") ||
			path.includes("/vendor/ryk") ||
			path.includes("/vendor/ryk-daemon"),
		isCompatiblePathOrca: () => true,
	};

	assert.deepEqual(resolveOrcaBin({ ...defaults, env: {} }), {
		rykBin: resolve("/package/vendor/ryk"),
		daemonBin: resolve("/package/vendor/ryk-daemon"),
		source: "bundled",
	});
	// When only legacy ryk vendor exists (no ryk), fall back to orca.
	assert.deepEqual(
		resolveOrcaBin({
			...defaults,
			isExecutable: (path: string) =>
				path.includes("/vendor/ryk") && !path.includes("/vendor/ryk"),
			env: {},
		}),
		{
			rykBin: resolve("/package/vendor/ryk"),
			daemonBin: resolve("/package/vendor/ryk-daemon"),
			source: "bundled",
		},
	);
	assert.deepEqual(
		resolveOrcaBin({
			...defaults,
			bundledPackageRoot: "/missing-package",
			isExecutable: () => false,
			env: { RYK_PI_USE_PATH: "true" },
		}),
		{
			rykBin: "ryk",
			source: "path",
		},
	);
});

test("resolveOrcaBin uses bundled ryk when PATH is incompatible", () => {
	const result = resolveOrcaBin({
		env: {},
		bundledPackageRoot: "/package",
		isExecutable: () => true,
		isCompatiblePathOrca: () => false,
	});

	assert.equal(result.rykBin, resolve("/package/vendor/ryk"));
	assert.equal(result.daemonBin, resolve("/package/vendor/ryk-daemon"));
	assert.equal(result.source, "bundled");
});

test("resolveOrcaBin validates opted-in PATH version output", () => {
	const compatible = resolveOrcaBin({
		env: { RYK_PI_USE_PATH: "true" },
		bundledPackageRoot: "/missing-package",
		isExecutable: () => false,
		spawnSync: (cmd: string) => ({
			status: 0,
			stdout: `${cmd === "ryk" ? "ryk" : "ryk"} ${requiredRuntimeVersion}\n`,
		}),
	});
	assert.equal(compatible.source, "path");
	assert.equal(compatible.rykBin, "ryk");

	for (const result of [
		{ status: 0, stdout: "orca 0.0.0\n" },
		{ status: 0, stdout: "not-orca\n" },
		{ status: 1, stdout: `ryk ${requiredRuntimeVersion}\n` },
		{ status: null, stdout: "", error: new Error("timeout") },
	]) {
		assert.equal(
			resolveOrcaBin({
				env: { RYK_PI_USE_PATH: "true" },
				bundledPackageRoot: "/missing-package",
				isExecutable: () => false,
				spawnSync: () => result,
			}).source,
			"missing",
		);
	}
});

test("bundled ryk evaluation receives its companion daemon path", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	installRykExtension(pi, {
		spawn,
		resolveBin: () => ({
			rykBin: "/package/vendor/ryk",
			daemonBin: "/package/vendor/ryk-daemon",
			source: "bundled",
		}),
	});

	await fireToolCall(handlers.get("tool_call")![0], makeCtx().ctx);

	assert.equal(calls[0].options.env.RYK_DAEMON, "/package/vendor/ryk-daemon");
});

test("session start quietly initializes a missing policy and probes health", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-"));
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".ryk"));
				writeFileSync(
					resolve(call.options.cwd, ".ryk/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
	]);
	const context = makeCtx({ cwd });
	installRykExtension(pi, { spawn, rykBin: "ryk" });

	const returned = handlers.get("session_start")![0]({}, context.ctx);
	assert.equal(returned, undefined);
	await flushAsyncWork();

	assert.deepEqual(
		calls.map((call) => call.args),
		[["init", "--preset", "generic-agent"], ["doctor"]],
	);
	assert.deepEqual(
		calls.map((call) => call.options.cwd),
		[cwd, cwd],
	);
	assert.equal(context.notifications.length, 0);
	assert.equal(context.statuses.at(-1)?.text, "ryk ready");
	assert.ok(
		context.statuses.every(
			(entry) =>
				entry.text === undefined ||
				entry.text === "ryk degraded" ||
				entry.text === "ryk ready" ||
				entry.text === "ryk bypass",
		),
		"expected footer status to contain ryk state only",
	);
	rmSync(cwd, { recursive: true, force: true });
});

test("first bash evaluation waits for non-blocking session bootstrap", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-"));
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".ryk"));
				writeFileSync(
					resolve(call.options.cwd, ".ryk/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
		{ code: 0, stdout: allowJson() },
	]);
	const context = makeCtx({ cwd });
	installRykExtension(pi, { spawn, rykBin: "ryk" });

	assert.equal(handlers.get("session_start")![0]({}, context.ctx), undefined);
	const decision = await fireToolCall(
		handlers.get("tool_call")![0],
		context.ctx,
	);

	assert.equal(decision, undefined);
	assert.deepEqual(
		calls.map((call) => call.args),
		[
			["init", "--preset", "generic-agent"],
			["doctor"],
			["evaluate", "--json", "--stdin"],
		],
	);
	assert.deepEqual(
		calls.map((call) => call.options.cwd),
		[cwd, cwd, cwd],
	);
	rmSync(cwd, { recursive: true, force: true });
});

test("/ryk-setup ensures policy and probes health without invoking start", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-"));
	const { pi, commands } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".ryk"));
				writeFileSync(
					resolve(call.options.cwd, ".ryk/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
	]);
	const context = makeCtx({ cwd });
	installRykExtension(pi, { spawn, rykBin: "ryk" });

	await commands.get("orca-setup")!.handler("", context.ctx);

	assert.deepEqual(
		calls.map((call) => call.args),
		[["init", "--preset", "generic-agent"], ["doctor"]],
	);
	assert.deepEqual(
		calls.map((call) => call.options.cwd),
		[cwd, cwd],
	);
	assert.equal(
		calls.some((call) => call.args.includes("start")),
		false,
	);
	assert.equal(context.notifications.at(-1)?.type, "info");
	rmSync(cwd, { recursive: true, force: true });
});

async function fireToolCall(
	handler: Handler,
	ctx: any,
	command = "git status",
	toolName = "bash",
	input?: Record<string, unknown>,
) {
	const payload =
		input ??
		(toolName === "bash"
			? { command }
			: { path: command, content: "x" });
	return handler({ toolName, input: payload }, ctx);
}

function decideBlockJson(
	rule = "files.write.deny[0]",
	category = "file.write",
): string {
	return JSON.stringify({
		version: 1,
		decision: "block",
		risk: "high",
		category,
		reason: `matched ${category} deny rule`,
		rule,
		message: `${category} blocked by ryk policy.`,
		redactions: [],
	});
}

function decideAllowJson(category = "file.write"): string {
	return JSON.stringify({
		version: 1,
		decision: "allow",
		risk: "low",
		category,
		reason: "default allow",
		rule: null,
		message: `${category} allowed by ryk policy.`,
		redactions: [],
	});
}

function decideJson(
	decision: "allow" | "block" | "ask" | "warn" | "context_only" | "error",
	category = "file.write",
): string {
	return JSON.stringify({
		version: 1,
		decision,
		risk: "low",
		category,
		reason: `${category} returned ${decision}`,
		rule: null,
		message: `${category} returned ${decision}`,
		redactions: [],
	});
}

test("decide file rejects context_only for write side effects", async () => {
	const { spawn } = makeSpawn([
		{ code: 0, stdout: decideJson("context_only") },
	]);
	const result = await runOrcaDecideFile(
		{ path: "./src/main.ts", operation: "write" },
		{ spawn, rykBin: "ryk", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "deny");
});

test("decide file validates decision and exit-code consistency", async () => {
	for (const plan of [
		{ code: 1, stdout: decideJson("allow") },
		{ code: 0, stdout: decideJson("block") },
		{ code: 0, stdout: decideJson("ask") },
		{ code: 0, stdout: decideJson("warn") },
		{ code: null, stdout: decideJson("allow") },
		{ code: 0, stdout: "" },
	]) {
		// Retry once on protocol error; both attempts fail → still fail-closed.
		const { spawn } = makeSpawn([plan, plan]);
		const result = await runOrcaDecideFile(
			{ path: "./README.md", operation: "read" },
			{ spawn, rykBin: "ryk", timeoutMs: 1_000, cwd: process.cwd() },
		);
		assert.equal(result.kind, "error", JSON.stringify(plan));
		if (result.kind === "error") {
			assert.match(result.reason, /\[[a-z_]+\]/);
		}
	}
});

test("custom/MCP-shaped tools are name-gated via ryk decide tool", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: decideAllowJson("tool") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"hello",
		"mcp_custom_tool",
		{ path: "README.md", args: { secret: "x" } },
	);
	assert.equal(result, undefined);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].args.slice(0, 3), ["decide", "tool", "--json"]);
	const payload = JSON.parse(calls[0].args[3] as string) as { name: string };
	assert.deepEqual(payload, { name: "mcp_custom_tool" });
	assert.equal(isProtectedPiTool("mcp_custom_tool"), false);
	assert.equal(isProtectedPiTool("read"), true);
	assert.equal(isProtectedPiTool("write"), true);
	assert.match(piCoverageLabel(), /bash \+ write \+ edit \+ read policy-protected/);
	assert.match(piCoverageLabel(), /grep \+ find \+ ls approval-gated/);
	assert.match(piCoverageLabel(), /custom tool names gated via decide tool/);
	assert.match(piCoverageLabel(), /not full MCP protocol mediation/);
	assert.doesNotMatch(piCoverageLabel(), /custom\/MCP not intercepted/);
});

test("custom tool deny blocks with rule id on card", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 3, stdout: decideBlockJson("tools.deny[0]", "tool") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"read_file",
		{ uri: "file:///etc/passwd" },
	);

	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /rule tools\.deny\[0\]/);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].args.slice(0, 3), ["decide", "tool", "--json"]);
	const payload = JSON.parse(calls[0].args[3] as string) as { name: string };
	assert.deepEqual(payload, { name: "read_file" });
});

test("custom tool unavailable fails closed", async () => {
	const { pi, handlers } = makePi();
	const missing = { error: new Error("ENOENT") };
	const { spawn } = makeSpawn([missing, missing]);
	installRykExtension(pi, { spawn, rykBin: "missing-orca" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"mcp_custom_tool",
		{},
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /ryk is unavailable|spawn_failed/i);
});

test("session bypass skips decide tool for custom tools", async () => {
	const { pi, handlers } = makePi();
	// Typed decision:error is non-transient → single attempt (no retry).
	const err = { code: 1 as number, stdout: errorJson() };
	const { spawn, calls } = makeSpawn([err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, selections } = makeCtx();
	selections.push("Disable ryk for this Pi session");

	// First call triggers unavailable → user disables session.
	const first = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"mcp_custom_tool",
		{},
	);
	const second = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"mcp_custom_tool",
		{},
	);
	assert.equal(first, undefined);
	assert.equal(second, undefined);
	// Non-transient error: one spawn, then bypass skips further spawns.
	assert.equal(calls.length, 1);
});

test("empty custom tool name fails closed without spawning decide", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn();
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"   ",
		{},
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /missing non-empty tool name|malformed/i);
	assert.equal(calls.length, 0);
});

test("buildDecideToolPayload trims name", () => {
	assert.deepEqual(buildDecideToolPayload({ name: "  read_file  " }), {
		name: "read_file",
	});
});

test("runOrcaDecideTool maps block to deny and validates exit codes", async () => {
	const blocked = await runOrcaDecideTool(
		{ name: "read_file" },
		{
			spawn: makeSpawn([
				{ code: 3, stdout: decideBlockJson("tools.deny[1]", "tool") },
			]).spawn,
			rykBin: "ryk",
			timeoutMs: 1_000,
			cwd: process.cwd(),
		},
	);
	assert.equal(blocked.kind, "deny");

	for (const plan of [
		{ code: 1, stdout: decideAllowJson("tool") },
		{ code: 0, stdout: decideBlockJson("tools.deny[0]", "tool") },
		{ code: 0, stdout: "" },
	]) {
		// Two identical plans: protocol path retries once, still fail-closed.
		const result = await runOrcaDecideTool(
			{ name: "x" },
			{
				spawn: makeSpawn([plan, plan]).spawn,
				rykBin: "ryk",
				timeoutMs: 1_000,
				cwd: process.cwd(),
			},
		);
		assert.equal(result.kind, "error", JSON.stringify(plan));
		if (result.kind === "error") {
			assert.match(result.reason, /\[[a-z_]+\]/);
			assert.ok(result.failureClass);
		}
	}
});

test("runOrcaDecideTool retries once on malformed JSON then fail-closes", async () => {
	const bad = { code: 0, stdout: "{not-json" as string };
	const { spawn, calls } = makeSpawn([bad, bad]);
	const result = await runOrcaDecideTool(
		{ name: "x" },
		{ spawn, rykBin: "ryk", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "error");
	assert.equal(calls.length, 2);
	if (result.kind === "error") {
		assert.equal(result.failureClass, "malformed_json");
		assert.match(result.reason, /\[malformed_json\]/);
	}
});

test("runOrcaDecideTool recovers when second attempt succeeds", async () => {
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: "{not-json" },
		{ code: 0, stdout: decideAllowJson("tool") },
	]);
	const result = await runOrcaDecideTool(
		{ name: "x" },
		{ spawn, rykBin: "ryk", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "allow");
	assert.equal(calls.length, 2);
});

test("formatProtocolErrorReason includes class token", () => {
	const reason = formatProtocolErrorReason("timeout", "ryk decide timed out.");
	assert.equal(protocolFailureClassFromReason(reason), "timeout");
	assert.match(reason, /\[timeout\]/);
});

test("isTransientProtocolFailure covers spawn/json glitches only", () => {
	assert.equal(isTransientProtocolFailure("timeout"), true);
	assert.equal(isTransientProtocolFailure("malformed_json"), true);
	assert.equal(isTransientProtocolFailure("spawn_failed"), true);
	assert.equal(isTransientProtocolFailure("output_too_large"), true);
	assert.equal(isTransientProtocolFailure("inconsistent_exit"), true);
	assert.equal(isTransientProtocolFailure("unexpected"), false);
	assert.equal(isTransientProtocolFailure(undefined), false);
	assert.equal(allowWithWarningPermitsProtocolClass("spawn_failed"), true);
	assert.equal(allowWithWarningPermitsProtocolClass("timeout"), false);
	assert.equal(allowWithWarningPermitsProtocolClass("malformed_json"), false);
	assert.equal(allowWithWarningPermitsProtocolClass("unexpected"), false);
});

test("runOrcaDecideTool does not retry non-transient decision error", async () => {
	const err = {
		code: 1,
		stdout: JSON.stringify({
			decision: "error",
			reason: "ryk decide: evaluation failed; fail closed.",
			error_code: "evaluation_failed",
		}),
	};
	const { spawn, calls } = makeSpawn([err, err]);
	const result = await runOrcaDecideTool(
		{ name: "x" },
		{ spawn, rykBin: "ryk", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "error");
	assert.equal(calls.length, 1);
	if (result.kind === "error") {
		assert.equal(result.failureClass, "unexpected");
	}
});

test("write tool is evaluated via ryk decide file", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 3, stdout: decideBlockJson("files.write.deny[2]") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: ".ryk/policy.yaml", content: "evil" },
	);

	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /write action|blocked/i);
	assert.match(result?.reason ?? "", /rule files\.write\.deny\[2\]/);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].args.slice(0, 3), ["decide", "file", "--json"]);
	const payload = JSON.parse(calls[0].args[3] as string) as {
		path: string;
		operation: string;
	};
	assert.equal(payload.operation, "write");
	assert.ok(payload.path.includes(".ryk/policy.yaml"));
	assert.equal(messages.length, 1);
	assert.equal(messages[0].message.customType, "orca-decision");
	assert.match(messages[0].message.content, /Rule: files\.write\.deny\[2\]/);
});

test("edit tool allow proceeds without block", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: decideAllowJson() }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"edit",
		{ path: "src/main.ts", edits: [{ oldText: "a", newText: "b" }] },
	);
	assert.equal(result, undefined);
	assert.equal(calls[0].args[0], "decide");
	assert.equal(calls[0].args[1], "file");
});

test("read tool is evaluated via ryk decide file with operation read", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 3,
			stdout: decideBlockJson("files.read.deny[0]", "file.read"),
		},
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"read",
		{ path: ".ssh/id_rsa" },
	);

	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /read action|blocked/i);
	assert.match(result?.reason ?? "", /rule files\.read\.deny\[0\]/);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].args.slice(0, 3), ["decide", "file", "--json"]);
	const payload = JSON.parse(calls[0].args[3] as string) as {
		path: string;
		operation: string;
	};
	assert.equal(payload.operation, "read");
	assert.ok(payload.path.includes(".ssh/id_rsa"));
	assert.equal(messages.length, 1);
	assert.match(messages[0].message.content, /Rule: files\.read\.deny\[0\]/);
});

test("grep tool requires approval even when its broad root is allowed", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: decideAllowJson("file.read") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ cwd: process.cwd(), hasUI: false, mode: "print" });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"grep",
		{ pattern: "secret", path: ".env" },
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /broad discovery|approval/i);
	const payload = JSON.parse(calls[0].args[3] as string) as {
		path: string;
		operation: string;
	};
	assert.equal(payload.operation, "read");
	assert.ok(payload.path.includes(".env"));
});

test("find tool defaults missing path to cwd for decide file", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: decideAllowJson("file.read") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const cwd = process.cwd();
	const { ctx } = makeCtx({ cwd, hasUI: false, mode: "print" });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"find",
		{ pattern: "**/*.pem" },
	);
	assert.equal(result?.block, true);
	const payload = JSON.parse(calls[0].args[3] as string) as {
		path: string;
		operation: string;
	};
	assert.equal(payload.operation, "read");
	assert.equal(payload.path, cwd);
});

test("ls tool denies sensitive directory via decide file read", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 3,
			stdout: decideBlockJson("files.read.deny[1]", "file.read"),
		},
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"ls",
		{ path: "~/.ssh" },
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /ls action|blocked/i);
	assert.match(result?.reason ?? "", /rule files\.read\.deny\[1\]/);
	const payload = JSON.parse(calls[0].args[3] as string) as {
		operation: string;
	};
	assert.equal(payload.operation, "read");
});

test("file-policy ask uses truthful policy choices", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();
	let offered: string[] = [];
	(ctx.ui as any).select = async (_title: string, options: string[]) => {
		offered = options;
		return "Block";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.ok(offered.includes("Show policy reason"));
	assert.ok(offered.includes("Run once anyway"));
	assert.ok(!offered.some((choice) => /repair|doctor/i.test(choice)));
});

test("allowOnceBypassEnabled honors env and strict mode", () => {
	assert.equal(allowOnceBypassEnabled({}), true);
	assert.equal(allowOnceBypassEnabled({}, "auto"), true);
	assert.equal(allowOnceBypassEnabled({}, "strict"), false);
	assert.equal(
		allowOnceBypassEnabled({ RYK_PI_ALLOW_ONCE: "false" }, "auto"),
		false,
	);
	assert.equal(
		allowOnceBypassEnabled({ RYK_PI_ALLOW_ONCE: "true" }, "strict"),
		true,
	);
	assert.deepEqual(askOptionsFor("policy", false), [
		"Block",
		"Disable ryk for this Pi session",
		"Show policy reason",
	]);
	assert.ok(askOptionsFor("unavailable", true).includes("Run once anyway"));
	assert.ok(!askOptionsFor("unavailable", false).includes("Run once anyway"));
});

test("strict mode policy ask omits once-bypass", async () => {
	const { pi, handlers, commands } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();
	await commands.get("orca-mode")!.handler("strict", ctx);
	let offered: string[] = [];
	(ctx.ui as any).select = async (_title: string, options: string[]) => {
		offered = options;
		return "Block";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.ok(!offered.includes("Run once anyway"));
	assert.ok(offered.includes("Show policy reason"));
});

test("once-bypass records an audit event", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const syntheticSecret = "AKIASYNTHETICONLY1234";
	const encodedSecret = "dG9rZW49c3ludGhldGljLW9ubHktc2VjcmV0";
	const { ctx, notifications } = makeCtx({
		cwd: `/tmp/${syntheticSecret}/${encodedSecret}`,
		sessionManager: { getSessionId: () => `session-${syntheticSecret}-${encodedSecret}` },
	});
	(ctx.ui as any).select = async () => "Run once anyway";

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result, undefined);
	assert.ok(
		notifications.some((n) => /ryk audit: once-bypass/i.test(n.message)),
	);
	const audit = messages.find((m) => m.message.customType === "orca.audit");
	assert.ok(audit);
	assert.equal(
		(audit?.message.details as { event?: string } | undefined)?.event,
		"orca_once_bypass",
	);
	assert.equal(
		(audit?.message.details as { tool?: string } | undefined)?.tool,
		"write",
	);
	assert.equal(
		(audit?.message.details as { source?: string } | undefined)?.source,
		"policy",
	);
	const serializedDetails = JSON.stringify(audit?.message.details);
	assert.ok(!serializedDetails.includes(syntheticSecret));
	assert.ok(!serializedDetails.includes(encodedSecret));
	assert.ok(!Object.hasOwn(audit?.message.details as object, "cwd"));
	assert.ok(!Object.hasOwn(audit?.message.details as object, "session_id"));
});

test("once-bypass stays blocked when transcript auditing is unavailable", async () => {
	const { pi, handlers, messages } = makePi();
	delete (pi as { sendMessage?: unknown }).sendMessage;
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, notifications } = makeCtx();
	(ctx.ui as any).select = async () => "Run once anyway";

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.equal(messages.length, 0);
	assert.ok(
		notifications.some((notification) =>
			/transcript auditing is unavailable/i.test(notification.message),
		),
	);
});

test("isSubagentSession and shouldAutoDenyPolicyAsk helpers", () => {
	assert.equal(isSubagentSession({}), false);
	assert.equal(isSubagentSession({ PI_SUBAGENT_PARENT_SESSION: "" }), false);
	assert.equal(isSubagentSession({ PI_SUBAGENT_PARENT_SESSION: "   " }), false);
	assert.equal(
		isSubagentSession({ PI_SUBAGENT_PARENT_SESSION: "parent-session-1" }),
		true,
	);

	assert.equal(
		shouldAutoDenyPolicyAsk({ hasUI: true, mode: "tui" }, {}),
		false,
	);
	assert.equal(shouldAutoDenyPolicyAsk({ hasUI: false }, {}), true);
	assert.equal(
		shouldAutoDenyPolicyAsk({ hasUI: true, mode: "print" }, {}),
		true,
	);
	assert.equal(
		shouldAutoDenyPolicyAsk({ hasUI: true, mode: "json" }, {}),
		true,
	);
	assert.equal(
		shouldAutoDenyPolicyAsk({ hasUI: true, mode: "noninteractive" }, {}),
		true,
	);
	assert.equal(
		shouldAutoDenyPolicyAsk(
			{ hasUI: true, mode: "tui" },
			{ PI_SUBAGENT_PARENT_SESSION: "parent-1" },
		),
		true,
	);
});

test("policy ask auto-denies noninteractive sessions without calling select", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });
	let selectCalled = false;
	(ctx.ui as any).select = async () => {
		selectCalled = true;
		return "Run once anyway";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.equal(selectCalled, false, "select must not be called for auto-deny");
	assert.match(result?.reason ?? "", /auto-denied/i);
	assert.match(result?.reason ?? "", /non-interactive/i);
	assert.notEqual(result, undefined, "auto-deny must never proceed");
	const audit = messages.find((m) => m.message.customType === "orca.audit");
	assert.ok(audit, "expected orca.audit transcript event");
	assert.equal(
		(audit?.message.details as { event?: string } | undefined)?.event,
		"orca_ask_auto_deny",
	);
});

test("policy ask auto-denies print mode even when hasUI is true", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: true, mode: "print" });
	let selectCalled = false;
	(ctx.ui as any).select = async () => {
		selectCalled = true;
		return "Run once anyway";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.equal(selectCalled, false);
	assert.match(result?.reason ?? "", /auto-denied/i);
});

test("policy ask auto-denies subagent sessions even when hasUI is true", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	process.env.PI_SUBAGENT_PARENT_SESSION = "parent-session-stress";
	try {
		const { pi, handlers, messages } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installRykExtension(pi, { spawn, rykBin: "ryk" });
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });
		let selectCalled = false;
		(ctx.ui as any).select = async () => {
			selectCalled = true;
			return "Run once anyway";
		};

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "src/main.ts", content: "x" },
		);
		assert.equal(result?.block, true);
		assert.equal(
			selectCalled,
			false,
			"subagent must auto-deny even with hasUI",
		);
		assert.match(result?.reason ?? "", /auto-denied/i);
		assert.match(result?.reason ?? "", /subagent/i);
		assert.notEqual(result, undefined);
		const audit = messages.find((m) => m.message.customType === "orca.audit");
		assert.equal(
			(audit?.message.details as { event?: string } | undefined)?.event,
			"orca_ask_auto_deny",
		);
		assert.equal(
			(audit?.message.details as { session_class?: string } | undefined)
				?.session_class,
			"subagent",
		);
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
	}
});

test("policy ask still invokes select in interactive parent TUI", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	delete process.env.PI_SUBAGENT_PARENT_SESSION;
	try {
		const { pi, handlers } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installRykExtension(pi, { spawn, rykBin: "ryk" });
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });
		let selectCalled = false;
		(ctx.ui as any).select = async () => {
			selectCalled = true;
			return "Block";
		};

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "src/main.ts", content: "x" },
		);
		assert.equal(result?.block, true);
		assert.equal(selectCalled, true, "interactive TUI must call select");
		assert.ok(
			!/auto-denied/i.test(result?.reason ?? ""),
			"interactive block should not use auto-deny wording",
		);
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
	}
});

test("policy ask auto-deny still blocks when audit is unavailable", async () => {
	const { pi, handlers, messages } = makePi();
	delete (pi as { sendMessage?: unknown }).sendMessage;
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });
	let selectCalled = false;
	(ctx.ui as any).select = async () => {
		selectCalled = true;
		return "Run once anyway";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "src/main.ts", content: "x" },
	);
	assert.equal(result?.block, true);
	assert.equal(selectCalled, false);
	assert.match(result?.reason ?? "", /auto-denied/i);
	assert.equal(messages.length, 0);
});

test("bash policy ask auto-denies noninteractive sessions", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: askJson() }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });
	let selectCalled = false;
	(ctx.ui as any).select = async () => {
		selectCalled = true;
		return "Run once anyway";
	};

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"git push --force",
	);
	assert.equal(result?.block, true);
	assert.equal(selectCalled, false);
	assert.match(result?.reason ?? "", /auto-denied/i);
});

test("interactive policy ask blocks when select returns undefined (timeout)", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	delete process.env.PI_SUBAGENT_PARENT_SESSION;
	try {
		const { pi, handlers } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installRykExtension(pi, { spawn, rykBin: "ryk" });
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });
		(ctx.ui as any).select = async () => undefined;

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "src/main.ts", content: "x" },
		);
		assert.equal(result?.block, true);
		assert.notEqual(result, undefined);
		assert.ok(!/auto-denied/i.test(result?.reason ?? ""));
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
	}
});

test("malformed read tool call fails closed", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn();
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"read",
		{ path: "   " },
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /malformed Pi read tool call/);
	assert.equal(calls.length, 0);
});

test("read tool unavailable path fails closed in noninteractive mode", async () => {
	const { pi, handlers } = makePi();
	const missing = { error: new Error("spawn ENOENT") };
	const { spawn } = makeSpawn([missing, missing]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"read",
		{ path: "README.md" },
	);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /ryk is unavailable|could not evaluate this read|spawn_failed/i);
});

test("session bypass skips write and read evaluation", async () => {
	const { pi, handlers, commands } = makePi();
	const { spawn, calls } = makeSpawn();
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-stop")!.handler("", ctx);
	const writeResult = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: "/tmp/x", content: "y" },
	);
	const readResult = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"read",
		{ path: "/tmp/secret" },
	);
	assert.equal(writeResult, undefined);
	assert.equal(readResult, undefined);
	assert.equal(calls.length, 0);
	assert.ok(
		notifications.some((n) => /write allowed without ryk/i.test(n.message)),
	);
	assert.ok(
		notifications.some((n) => /read allowed without ryk/i.test(n.message)),
	);
});

test("buildDecideFilePayload, resolveToolPath, extractDecideFilePath", () => {
	const payload = buildDecideFilePayload("/tmp/a", "write");
	assert.deepEqual(payload, { path: "/tmp/a", operation: "write" });
	assert.deepEqual(buildDecideFilePayload("/tmp/b", "read"), {
		path: "/tmp/b",
		operation: "read",
	});
	const { ctx } = makeCtx({ cwd: "/workspace" });
	assert.equal(resolveToolPath("/abs/file", ctx), "/abs/file");
	assert.equal(resolveToolPath("/workspace/src/../.env", ctx), "/workspace/.env");
	assert.equal(
		resolveToolPath("rel.txt", { cwd: process.cwd() }),
		resolve(process.cwd(), "rel.txt"),
	);
	assert.deepEqual(extractDecideFilePath("read", { path: "a.txt" }), {
		path: "a.txt",
		required: true,
	});
	assert.deepEqual(extractDecideFilePath("grep", { pattern: "x" }), {
		path: ".",
		required: false,
	});
	assert.deepEqual(extractDecideFilePath("find", { pattern: "*", path: "src" }), {
		path: "src",
		required: false,
	});
	assert.deepEqual(extractDecideFilePath("ls", {}), {
		path: ".",
		required: false,
	});
});

test("bash safe command with ryk allow returns undefined", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"git status",
	);
	assert.equal(result, undefined);
});

test("bash dangerous command with ryk deny returns block", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([{ code: 2, stdout: denyJson() }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, widgets } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"rm -rf /",
	);
	assert.deepEqual(result, {
		block: true,
		reason:
			"ryk blocked this bash command: destructive filesystem command • rule core.filesystem:destructive-rm",
	});
	assert.equal(messages.length, 1);
	assert.equal(messages[0].message.customType, "orca-decision");
	assert.equal(messages[0].message.display, true);
	assert.deepEqual(messages[0].options, { triggerTurn: false });
	assert.equal(
		widgets.some((entry) => entry.key === "orca-block" && entry.value !== undefined),
		false,
		"expected deny output to avoid the docked widget surface",
	);
	const inlineDecision = messages[0].message.content;
	assert.match(inlineDecision, /┏━+/);
	assert.match(inlineDecision, /RYK \/\/ BLOCKED/);
	assert.match(
		inlineDecision,
		/COMMAND STOPPED BEFORE EXECUTION/,
	);
	assert.match(inlineDecision, /destructive filesystem command/);
	assert.match(inlineDecision, /Why: destructive filesystem command/);
	assert.match(
		inlineDecision,
		/Rule: core\.filesystem:destructive-rm/,
	);
	assert.ok(
		inlineDecision.split("\n").every((line) => line.length === 56),
		"expected a compact, aligned 56-column ryk card",
	);
});

test("ryk inline decision keeps long reasons inside the compact frame", async () => {
	const longReason = `unsafe-${"x".repeat(120)} command escaped policy`;
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([
		{
			code: 2,
			stdout: JSON.stringify({
				decision: "deny",
				reason: longReason,
				rule_id: "custom.long-reason",
			}),
		},
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	await fireToolCall(handlers.get("tool_call")![0], ctx, "dangerous-command");

	const inlineDecision = messages[0]?.message.content;
	assert.ok(inlineDecision, "expected inline ryk decision content");
	assert.ok(
		inlineDecision.split("\n").every((line) => line.length === 56),
		"expected every long-reason card line to stay inside the frame",
	);
	assert.match(inlineDecision, /Why: unsafe-/);
	assert.match(inlineDecision, /command escaped policy/);
});

test("bash dangerous command with ryk deny blocks even when exit code is not 2", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: denyJson() }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"rm -rf /",
	);
	assert.deepEqual(result, {
		block: true,
		reason:
			"ryk blocked this bash command: destructive filesystem command • rule core.filesystem:destructive-rm",
	});
});

test("ryk error in non-interactive mode blocks", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /\/ryk-setup/i);
});

test("ryk error in interactive mode waits for the user's decision", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, widgets } = makeCtx();
	let resolveSelection: (choice: string) => void = () => {};
	ctx.ui.select = () =>
		new Promise<string>((resolvePromise) => {
			resolveSelection = resolvePromise;
		});

	let settled = false;
	const pendingResult = fireToolCall(handlers.get("tool_call")![0], ctx).then(
		(result) => {
			settled = true;
			return result;
		},
	);
	await flushAsyncWork();
	assert.equal(settled, false, "expected bash tool call to wait for select()");
	const askWidget = widgets.find((entry) => entry.key === "orca-block");
	assert.ok(askWidget, "expected ryk ask widget");
	assert.deepEqual(askWidget.opts, { placement: "aboveEditor" });
	assert.match(askWidget.value?.join("\n") ?? "", /RYK \/\/ YOUR CALL/);
	assert.match(
		askWidget.value?.join("\n") ?? "",
		/RYK PAUSED THIS COMMAND/,
	);
	assert.match(
		askWidget.value?.join("\n") ?? "",
		/Choose: Run once, repair ryk, or keep it blocked\./,
	);
	assert.ok(
		askWidget.value?.every((line) => line.length === 56),
		"expected a compact, aligned 56-column ryk ask card",
	);

	resolveSelection("Run once anyway");
	const result = await pendingResult;
	assert.equal(result, undefined);
	assert.equal(settled, true);
	assert.equal(widgets.at(-1)?.value, undefined);
});

test("auto mode blocks print sessions even when hasUI is true", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: true, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /\/ryk-setup/i);
});

test("strict mode blocks", async () => {
	const { pi, handlers, commands } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();
	await commands.get("orca-mode")!.handler("strict", ctx);

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
});

test("allow-with-warning allows only spawn_failed unavailability", async () => {
	const { pi, handlers, commands } = makePi();
	const missing = { error: new Error("ENOENT") };
	// spawn_failed is transient → one retry, then allow-with-warning soft-allows.
	const { spawn } = makeSpawn([missing, missing]);
	installRykExtension(pi, { spawn, rykBin: "missing-orca" });
	const { ctx, notifications } = makeCtx();
	await commands.get("orca-mode")!.handler("allow-with-warning", ctx);

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result, undefined);
	assert.equal(notifications.at(-1)?.type, "warning");
	assert.match(notifications.at(-1)?.message ?? "", /allowing bash with warning/i);
});

test("allow-with-warning still fail-closes on protocol decision error", async () => {
	const { pi, handlers, commands } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn, calls } = makeSpawn([err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();
	await commands.get("orca-mode")!.handler("allow-with-warning", ctx);

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /Failure class|unexpected|daemon/i);
	// Non-transient: single attempt.
	assert.equal(calls.length, 1);
});

test("malformed ryk JSON follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	// Retry once: both attempts malformed → still fail-closed with class token.
	const { spawn } = makeSpawn([
		{ code: 0, stdout: "{not-json" },
		{ code: 0, stdout: "{not-json" },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /malformed JSON/);
	assert.match(result.reason, /malformed_json|Failure class/i);
});

test("child process failure follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([
		{ error: new Error("ENOENT") },
		{ error: new Error("ENOENT") },
	]);
	installRykExtension(pi, { spawn, rykBin: "missing-orca" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /ryk is unavailable|spawn_failed/i);
});

test("repeated protocol failures notify degraded once without allowing", async () => {
	const { pi, handlers } = makePi();
	const plans = Array.from({ length: PROTOCOL_DEGRADED_THRESHOLD * 2 }, () => ({
		code: 0 as number,
		stdout: "{not-json",
	}));
	const { spawn, calls } = makeSpawn(plans);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, notifications } = makeCtx({ hasUI: false, mode: "print" });

	for (let i = 0; i < PROTOCOL_DEGRADED_THRESHOLD; i++) {
		const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
		assert.equal(result.block, true, `call ${i} must fail closed`);
	}
	// Two attempts per tool call (retry) × N failures.
	assert.equal(calls.length, PROTOCOL_DEGRADED_THRESHOLD * 2);
	const degraded = notifications.filter((n) =>
		/protocol degraded/i.test(n.message),
	);
	assert.equal(degraded.length, 1);
	assert.equal(degraded[0]?.type, "warning");
});

test("session bypass allows subsequent bash calls during same session", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	// Non-transient decision:error → single spawn, then session bypass.
	const { spawn, calls } = makeSpawn([err]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, selections } = makeCtx();
	selections.push("Disable ryk for this Pi session");

	const first = await fireToolCall(handlers.get("tool_call")![0], ctx);
	const second = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(first, undefined);
	assert.equal(second, undefined);
	assert.equal(calls.length, 1);
});

test("session bypass does not leak across Pi session ids", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn, calls } = makeSpawn([
		err,
		{ code: 0, stdout: allowJson() },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const firstSession = makeCtx();
	const secondSession = makeCtx({
		sessionManager: { getSessionId: () => "session-b" },
	});
	firstSession.selections.push("Disable ryk for this Pi session");

	await fireToolCall(handlers.get("tool_call")![0], firstSession.ctx);
	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		secondSession.ctx,
	);
	assert.equal(result, undefined);
	// 1 non-transient error on first session + 1 allow on second session.
	assert.equal(calls.length, 2);
});

test("malformed bash tool calls fail closed", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn();
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx();

	const result = await handlers.get("tool_call")![0](
		{ toolName: "bash", input: { command: 123 } },
		ctx,
	);
	assert.equal(result.block, true);
	assert.match(result.reason, /malformed Pi bash tool call/);
	assert.equal(calls.length, 0);
});

test("/ryk-doctor handles ryk present", async () => {
	const { pi, commands } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: '{"ok":true}' }]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-doctor")!.handler("", ctx);
	assert.equal(notifications.at(-1)?.type, "info");
	assert.match(notifications.at(-1)!.message, /ok/);
	assert.match(notifications.at(-1)!.message, /Coverage:/);
	assert.match(notifications.at(-1)!.message, /bash \+ write \+ edit \+ read policy-protected/);
});

test("/ryk-doctor handles ryk missing", async () => {
	const { pi, commands } = makePi();
	const { spawn } = makeSpawn([{ error: new Error("ENOENT") }]);
	installRykExtension(pi, { spawn, rykBin: "missing-orca" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-doctor")!.handler("", ctx);
	assert.equal(notifications.at(-1)?.type, "error");
	assert.match(notifications.at(-1)!.message, /not found/);
	assert.match(notifications.at(-1)!.message, /Coverage:/);
});

test("/ryk-stop disables Pi bash protection until /ryk-start re-enables it", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-"));
	mkdirSync(resolve(cwd, ".ryk"));
	writeFileSync(resolve(cwd, ".ryk/policy.yaml"), "version: 1\n");
	const { pi, commands, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: "healthy" },
		{ code: 0, stdout: allowJson() },
	]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx, notifications, statuses } = makeCtx({ cwd });

	await commands.get("orca-stop")!.handler("", ctx);
	const stopped = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"git status",
	);
	await commands.get("orca-start")!.handler("", ctx);
	const restarted = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"git status",
	);

	assert.equal(stopped, undefined);
	assert.equal(restarted, undefined);
	assert.deepEqual(
		calls.map((call) => call.args),
		[["doctor"], ["evaluate", "--json", "--stdin"]],
	);
	assert.equal(
		notifications.some((entry) =>
			entry.message.includes("disabled for this Pi session"),
		),
		true,
	);
	assert.equal(
		notifications.some((entry) => entry.message.includes("enabled")),
		true,
	);
	assert.equal(
		statuses.some((entry) => entry.text === "ryk bypass"),
		true,
	);
	assert.equal(statuses.at(-1)?.text, "ryk ready");
	rmSync(cwd, { recursive: true, force: true });
});

test("/ryk-start re-enables without invoking the CLI start command", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-"));
	mkdirSync(resolve(cwd, ".ryk"));
	writeFileSync(resolve(cwd, ".ryk/policy.yaml"), "version: 1\n");
	const present = makePi();
	const presentSpawn = makeSpawn([{ code: 0, stdout: "healthy" }]);
	installRykExtension(present.pi, {
		spawn: presentSpawn.spawn,
		rykBin: "ryk",
	});
	const presentCtx = makeCtx({ cwd });
	await present.commands.get("orca-start")!.handler("", presentCtx.ctx);
	assert.deepEqual(
		presentSpawn.calls.map((call) => call.args),
		[["doctor"]],
	);
	assert.equal(presentCtx.notifications.at(-1)?.type, "info");

	const missing = makePi();
	const missingSpawn = makeSpawn([{ error: new Error("ENOENT") }]);
	installRykExtension(missing.pi, {
		spawn: missingSpawn.spawn,
		rykBin: "missing-orca",
	});
	const missingCtx = makeCtx();
	await missing.commands.get("orca-start")!.handler("", missingCtx.ctx);
	assert.equal(missingCtx.notifications.at(-1)?.type, "error");
	assert.equal(
		missingSpawn.calls.some((call) => call.args.includes("start")),
		false,
	);
	rmSync(cwd, { recursive: true, force: true });
});

test("/ryk-mode changes mode", async () => {
	const { pi, commands } = makePi();
	installRykExtension(pi, { spawn: makeSpawn().spawn, rykBin: "ryk" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-mode")!.handler("strict", ctx);
	assert.match(notifications.at(-1)!.message, /strict/);
	assert.match(notifications.at(-1)!.message, /Coverage:/);
	assert.match(notifications.at(-1)!.message, /ryk run/);
	assert.match(notifications.at(-1)!.message, /prefer strict|Production/i);

	await commands.get("orca-mode")!.handler("", ctx);
	assert.match(notifications.at(-1)!.message, /ryk Pi mode: strict/);
	assert.match(notifications.at(-1)!.message, /bash \+ write \+ edit \+ read policy-protected/);
});

test("no shell interpolation is used when invoking ryk", async () => {
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	await runOrcaEvaluate(
		buildEvaluateRequest("echo safe", { cwd: process.cwd(), mode: "print" }),
		{
			spawn,
			rykBin: "ryk",
			timeoutMs: 1_000,
		},
	);

	assert.equal(calls[0].file, "ryk");
	assert.deepEqual(calls[0].args, ["evaluate", "--json", "--stdin"]);
	assert.equal(calls[0].options.shell, false);
	const request = JSON.parse(calls[0].stdin[0]) as OrcaEvaluateRequest;
	assert.equal(request.command, "echo safe");
	assert.equal(request.source.host, "pi");
});

test("runOrcaEvaluate maps decision ask exit 0 to kind ask", async () => {
	const { spawn } = makeSpawn([{ code: 0, stdout: askJson() }]);
	const decision = await runOrcaEvaluate(
		buildEvaluateRequest("git push --force", {
			cwd: process.cwd(),
			mode: "tui",
		}),
		{
			spawn,
			rykBin: "ryk",
			timeoutMs: 1_000,
		},
	);

	assert.equal(decision.kind, "ask");
	if (decision.kind === "ask") {
		assert.match(decision.reason, /requires approval/i);
		assert.equal(
			(decision.response as { decision?: string }).decision,
			"ask",
		);
	}
});

test("oversized ryk output follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const huge = "x".repeat(1024 * 1024 + 1);
	const plan = { code: 0 as number, stdout: huge };
	const { spawn } = makeSpawn([plan, plan]);
	installRykExtension(pi, { spawn, rykBin: "ryk" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /maximum size|output_too_large/i);
});

test("helpers resolve modes and sanitize reasons", () => {
	assert.equal(resolveUnavailableMode("auto", { hasUI: true }), "ask");
	assert.equal(
		resolveUnavailableMode("auto", { hasUI: false }),
		"noninteractive-block",
	);
	assert.equal(
		resolveUnavailableMode("auto", { hasUI: true, mode: "print" }),
		"noninteractive-block",
	);
	assert.equal(
		resolveUnavailableMode("auto", { hasUI: true, mode: "json" }),
		"noninteractive-block",
	);
	assert.equal(
		resolveUnavailableMode("ask", { hasUI: true, mode: "print" }),
		"noninteractive-block",
	);
	assert.match(
		safeOrcaReason({ reason: "blocked token=abc123", rule_id: "rule" }),
		/ryk blocked this bash command: blocked token=\[redacted\] • rule rule/,
	);
});

test("buildEvaluateRequest resolves relative cwd", () => {
	const request = buildEvaluateRequest("git status", { cwd: ".", mode: "tui" });
	assert.equal(request.cwd, resolve("."));
});

test("buildEvaluateRequest includes the stable Pi session id", () => {
	const request = buildEvaluateRequest("git status", {
		cwd: process.cwd(),
		mode: "tui",
		sessionManager: { getSessionId: () => "pi-session-42" },
	});
	assert.equal(request.source.session_id, "pi-session-42");
});

test("ryk timeout follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const spawn = (): FakeChild => {
		const child = new FakeChild();
		setTimeout(() => child.close(143), 5);
		return child;
	};
	installRykExtension(pi, { spawn, rykBin: "ryk", timeoutMs: 1 });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /timed out/);
});
