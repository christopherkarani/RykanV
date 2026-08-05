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
import { writeAskRequest } from "../extensions/parent_ask.ts";
import {
	allowOnceBypassEnabled,
	askOptionsFor,
	buildAutoDenyCopy,
	buildDecideFilePayload,
	buildDecideToolPayload,
	buildEvaluateRequest,
	DISPLAY_BRAND,
	extractDecideFilePath,
	installOrcaExtension,
	isPassthroughPiTool,
	isProtectedPiTool,
	isSubagentSession,
	listPendingRequests,
	parentAskDir,
	piCoverageLabel,
	PRODUCT_NAME,
	protocolBlockOptionLabel,
	repairMessage,
	resolveOrcaBin,
	resolvePiAskRoot,
	resolveToolPath,
	resolveUnavailableMode,
	formatProtocolErrorReason,
	formatMalformedJsonDetail,
	previewProcessOutput,
	protocolFailureClassFromReason,
	isTransientProtocolFailure,
	allowWithWarningPermitsProtocolClass,
	runOrcaDecideFile,
	runOrcaDecideTool,
	runOrcaEvaluate,
	safeOrcaReason,
	SESSION_GRANT_OPTION,
	shouldAutoDenyPolicyAsk,
	shouldLocalSelectPolicyAsk,
	shouldNameGateTool,
	writeAskResponse,
	addSessionGrant,
	hasSessionGrant,
	PROTOCOL_DEGRADED_THRESHOLD,
	type OrcaEvaluateRequest,
} from "../extensions/orca.ts";

type Handler = (event: any, ctx: any) => Promise<any> | any;

const packageJson = JSON.parse(
	readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as {
	dependencies: Record<string, string>;
};
const requiredRuntimeVersion =
	packageJson.dependencies["@orca-sec/ryk"] ??
	packageJson.dependencies["@orca-sec/orca"];

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

test("resolveOrcaBin honors executable ORCA_BIN before other candidates", () => {
	const result = resolveOrcaBin({
		env: { ORCA_BIN: "/trusted/orca" },
		bundledPackageRoot: "/package",
		isExecutable: (path) => path === "/trusted/orca",
		isCompatiblePathOrca: () => true,
	});

	assert.deepEqual(result, { orcaBin: "/trusted/orca", source: "explicit" });
});

test("resolveOrcaBin prefers RYK_BIN over ORCA_BIN", () => {
	const result = resolveOrcaBin({
		env: { RYK_BIN: "/trusted/ryk", ORCA_BIN: "/trusted/orca" },
		bundledPackageRoot: "/package",
		isExecutable: (path) => path === "/trusted/ryk" || path === "/trusted/orca",
		isCompatiblePathOrca: () => true,
	});
	assert.deepEqual(result, { orcaBin: "/trusted/ryk", source: "explicit" });
});

test("resolveOrcaBin prefers the bundled runtime and requires opt-in for PATH", () => {
	const defaults = {
		bundledPackageRoot: "/package",
		// Prefer ryk vendor binary when present (Phase 5a).
		isExecutable: (path: string) =>
			path.includes("/vendor/ryk") ||
			path.includes("/vendor/orca") ||
			path.includes("/vendor/orca-daemon"),
		isCompatiblePathOrca: () => true,
	};

	assert.deepEqual(resolveOrcaBin({ ...defaults, env: {} }), {
		orcaBin: resolve("/package/vendor/ryk"),
		daemonBin: resolve("/package/vendor/orca-daemon"),
		source: "bundled",
	});
	// When only legacy orca vendor exists (no ryk), fall back to orca.
	assert.deepEqual(
		resolveOrcaBin({
			...defaults,
			isExecutable: (path: string) =>
				path.includes("/vendor/orca") && !path.includes("/vendor/ryk"),
			env: {},
		}),
		{
			orcaBin: resolve("/package/vendor/orca"),
			daemonBin: resolve("/package/vendor/orca-daemon"),
			source: "bundled",
		},
	);
	assert.deepEqual(
		resolveOrcaBin({
			...defaults,
			bundledPackageRoot: "/missing-package",
			isExecutable: () => false,
			env: { ORCA_PI_USE_PATH: "true" },
		}),
		{
			orcaBin: "ryk",
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

	assert.equal(result.orcaBin, resolve("/package/vendor/ryk"));
	assert.equal(result.daemonBin, resolve("/package/vendor/orca-daemon"));
	assert.equal(result.source, "bundled");
});

test("resolveOrcaBin validates opted-in PATH version output", () => {
	const compatible = resolveOrcaBin({
		env: { ORCA_PI_USE_PATH: "true" },
		bundledPackageRoot: "/missing-package",
		isExecutable: () => false,
		spawnSync: (cmd: string) => ({
			status: 0,
			stdout: `${cmd === "ryk" ? "ryk" : "orca"} ${requiredRuntimeVersion}\n`,
		}),
	});
	assert.equal(compatible.source, "path");
	assert.equal(compatible.orcaBin, "ryk");

	for (const result of [
		{ status: 0, stdout: "orca 0.0.0\n" },
		{ status: 0, stdout: "not-orca\n" },
		{ status: 1, stdout: `orca ${requiredRuntimeVersion}\n` },
		{ status: null, stdout: "", error: new Error("timeout") },
	]) {
		assert.equal(
			resolveOrcaBin({
				env: { ORCA_PI_USE_PATH: "true" },
				bundledPackageRoot: "/missing-package",
				isExecutable: () => false,
				spawnSync: () => result,
			}).source,
			"missing",
		);
	}
});

test("bundled Orca evaluation receives its companion daemon path", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	installOrcaExtension(pi, {
		spawn,
		resolveBin: () => ({
			orcaBin: "/package/vendor/orca",
			daemonBin: "/package/vendor/orca-daemon",
			source: "bundled",
		}),
	});

	await fireToolCall(handlers.get("tool_call")![0], makeCtx().ctx);

	assert.equal(calls[0].options.env.ORCA_DAEMON, "/package/vendor/orca-daemon");
});

test("session start quietly initializes a missing policy and probes health", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-"));
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".orca"));
				writeFileSync(
					resolve(call.options.cwd, ".orca/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
	]);
	const context = makeCtx({ cwd });
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });

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
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-"));
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".orca"));
				writeFileSync(
					resolve(call.options.cwd, ".orca/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
		{ code: 0, stdout: allowJson() },
	]);
	const context = makeCtx({ cwd });
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });

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

test("/orca-setup ensures policy and probes health without invoking start", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-"));
	const { pi, commands } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 0,
			run: (call) => {
				mkdirSync(resolve(call.options.cwd, ".orca"));
				writeFileSync(
					resolve(call.options.cwd, ".orca/policy.yaml"),
					"version: 1\n",
				);
			},
		},
		{ code: 0, stdout: "healthy" },
	]);
	const context = makeCtx({ cwd });
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });

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
		message: `${category} blocked by Orca policy.`,
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
		message: `${category} allowed by Orca policy.`,
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
		{ spawn, orcaBin: "orca", timeoutMs: 1_000, cwd: process.cwd() },
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
			{ spawn, orcaBin: "orca", timeoutMs: 1_000, cwd: process.cwd() },
		);
		assert.equal(result.kind, "error", JSON.stringify(plan));
		if (result.kind === "error") {
			assert.match(result.reason, /\[[a-z_]+\]/);
		}
	}
});

test("custom/MCP-shaped tools are name-gated via orca decide tool", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: decideAllowJson("tool") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	assert.match(piCoverageLabel(), /decide tool/);
	assert.match(piCoverageLabel(), /passthrough/);
	assert.equal(shouldNameGateTool("mcp_custom_tool"), true);
	assert.equal(shouldNameGateTool("contact_supervisor"), false);
	assert.equal(isPassthroughPiTool("intercom"), true);
	assert.equal(shouldNameGateTool("bash"), false);
});

test("Pi control-plane tools skip name-only decide (passthrough)", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: decideAllowJson("tool") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	for (const tool of ["contact_supervisor", "intercom", "subagent"] as const) {
		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			tool,
			{ message: "hello" },
		);
		assert.equal(result, undefined, tool);
	}
	assert.equal(calls.length, 0, "passthrough tools must not spawn decide");
});

test("custom tool deny blocks with rule id on card", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 3, stdout: decideBlockJson("tools.deny[0]", "tool") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "missing-orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
			orcaBin: "orca",
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
				orcaBin: "orca",
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
		{ spawn, orcaBin: "orca", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "error");
	assert.equal(calls.length, 2);
	if (result.kind === "error") {
		assert.equal(result.failureClass, "malformed_json");
		assert.match(result.reason, /\[malformed_json\]/);
		assert.match(result.reason, /exit 0/);
		assert.match(result.reason, /stdout "\{not-json"/);
		assert.match(result.reason, /stderr empty/);
	}
});

test("formatMalformedJsonDetail includes exit and stream previews", () => {
	assert.equal(previewProcessOutput(""), "empty");
	assert.equal(previewProcessOutput("  hi  "), '"hi"');
	const detail = formatMalformedJsonDetail(
		{ code: 2, stdout: "", stderr: "ryk decide: --json requires a value.\n" },
		"decide",
	);
	assert.match(detail, /exit 2/);
	assert.match(detail, /stdout empty/);
	assert.match(detail, /--json requires a value/);
});

test("runOrcaDecideTool recovers when second attempt succeeds", async () => {
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: "{not-json" },
		{ code: 0, stdout: decideAllowJson("tool") },
	]);
	const result = await runOrcaDecideTool(
		{ name: "x" },
		{ spawn, orcaBin: "orca", timeoutMs: 1_000, cwd: process.cwd() },
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
		{ spawn, orcaBin: "orca", timeoutMs: 1_000, cwd: process.cwd() },
	);
	assert.equal(result.kind, "error");
	assert.equal(calls.length, 1);
	if (result.kind === "error") {
		assert.equal(result.failureClass, "unexpected");
	}
});

test("write tool is evaluated via orca decide file", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 3, stdout: decideBlockJson("files.write.deny[2]") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx({ cwd: process.cwd() });

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"",
		"write",
		{ path: ".orca/policy.yaml", content: "evil" },
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
	assert.ok(payload.path.includes(".orca/policy.yaml"));
	assert.equal(messages.length, 1);
	assert.equal(messages[0].message.customType, "orca-decision");
	assert.match(messages[0].message.content, /Rule: files\.write\.deny\[2\]/);
});

test("edit tool allow proceeds without block", async () => {
	const { pi, handlers } = makePi();
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: decideAllowJson() }]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("read tool is evaluated via orca decide file with operation read", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn, calls } = makeSpawn([
		{
			code: 3,
			stdout: decideBlockJson("files.read.deny[0]", "file.read"),
		},
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
		allowOnceBypassEnabled({ ORCA_PI_ALLOW_ONCE: "false" }, "auto"),
		false,
	);
	assert.equal(
		allowOnceBypassEnabled({ ORCA_PI_ALLOW_ONCE: "true" }, "strict"),
		true,
	);
	assert.deepEqual(askOptionsFor("policy", false), [
		"Block",
		SESSION_GRANT_OPTION,
		"Disable ryk for this Pi session",
		"Show policy reason",
	]);
	// Policy: once first, then block.
	assert.deepEqual(askOptionsFor("policy", true).slice(0, 2), [
		"Run once anyway",
		"Block",
	]);
	// Protocol: session allow, once, block (no doctor option).
	assert.deepEqual(askOptionsFor("unavailable", true), [
		"Allow for this session",
		"Run once anyway",
		"Block",
	]);
	assert.ok(askOptionsFor("unavailable", true).includes("Run once anyway"));
	assert.ok(!askOptionsFor("unavailable", false).includes("Run once anyway"));
	assert.deepEqual(askOptionsFor("unavailable", false), [
		"Allow for this session",
		"Block",
	]);
	assert.ok(
		!askOptionsFor("unavailable", true).some((o) => /doctor|repair/i.test(o)),
	);
});

test("strict mode policy ask omits once-bypass", async () => {
	const { pi, handlers, commands } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	assert.equal(
		shouldLocalSelectPolicyAsk({ hasUI: true, mode: "tui" }, {}),
		true,
	);
	assert.equal(
		shouldLocalSelectPolicyAsk(
			{ hasUI: true, mode: "tui" },
			{ PI_SUBAGENT_PARENT_SESSION: "parent-1" },
		),
		false,
	);
});

test("buildAutoDenyCopy locks Why/Next product voice", () => {
	const sub = buildAutoDenyCopy("subagent", "needs approval for write", "write");
	assert.equal(sub.title, DISPLAY_BRAND);
	assert.match(sub.summary, new RegExp(PRODUCT_NAME));
	assert.match(sub.summary, /can't prompt \(subagent\)/);
	assert.match(sub.nextStep, /parent Pi session/);
	assert.match(sub.nextStep, /mcp\.allow/);
	assert.equal(sub.rule, "rykanv:ask-no-ui");
	assert.match(sub.reason, /auto-denied \(subagent\)/);

	const non = buildAutoDenyCopy(
		"non-interactive",
		"needs approval",
		"bash",
		{ rule: "rykanv:parent-ask-timeout" },
	);
	assert.match(non.summary, /non-interactive/);
	assert.match(non.nextStep, /interactive Pi/);
	assert.equal(non.rule, "rykanv:parent-ask-timeout");
});

test("askOptionsFor policy includes session grant option", () => {
	const opts = askOptionsFor("policy", true);
	assert.ok(opts.includes(SESSION_GRANT_OPTION));
	assert.ok(opts.includes("Run once anyway"));
	const noOnce = askOptionsFor("policy", false);
	assert.ok(!noOnce.includes("Run once anyway"));
	assert.ok(noOnce.includes(SESSION_GRANT_OPTION));
});

test("policy ask auto-denies noninteractive sessions without calling select", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installOrcaExtension(pi, {
		spawn,
		orcaBin: "orca",
		parentAskPollMs: 0,
	});
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
	assert.match(result?.reason ?? "", new RegExp(PRODUCT_NAME));
	assert.notEqual(result, undefined, "auto-deny must never proceed");
	const audit = messages.find((m) => m.message.customType === "orca.audit");
	assert.ok(audit, "expected orca.audit transcript event");
	assert.equal(
		(audit?.message.details as { event?: string } | undefined)?.event,
		"orca_ask_auto_deny",
	);
	// Decision card should carry Next guidance for noninteractive.
	const decision = messages.find(
		(m) => m.message.customType === "orca-decision",
	);
	const details = decision?.message.details as
		| { nextStep?: string; summary?: string }
		| undefined;
	assert.match(details?.nextStep ?? "", /interactive Pi|pre-allow/i);
	assert.match(details?.summary ?? "", /can't prompt \(non-interactive\)/);
});

test("policy ask auto-denies print mode even when hasUI is true", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([
		{ code: 7, stdout: decideJson("ask", "file.write") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("policy ask subagent fails closed on parent timeout (no local select)", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	const previousTimeout = process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-ask-"));
	process.env.PI_SUBAGENT_PARENT_SESSION = "parent-session-stress";
	process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = "500";
	process.env.RYK_PI_ASK_ROOT = askRoot;
	let clock = 0;
	try {
		const { pi, handlers, messages } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
			now: () => clock,
			sleep: async (ms) => {
				clock += ms;
			},
		});
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
			"subagent must not local-select even with hasUI",
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
		const decision = messages.find(
			(m) => m.message.customType === "orca-decision",
		);
		const details = decision?.message.details as
			| { nextStep?: string; rule?: string; summary?: string }
			| undefined;
		assert.match(details?.nextStep ?? "", /parent Pi session/i);
		assert.match(details?.summary ?? "", /can't prompt \(subagent\)/);
		assert.ok(
			details?.rule === "rykanv:parent-ask-timeout" ||
				details?.rule === "rykanv:ask-no-ui",
		);
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
		if (previousTimeout === undefined)
			delete process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
		else process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = previousTimeout;
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		rmSync(askRoot, { recursive: true, force: true });
	}
});

test("policy ask subagent allows when parent responds run_once", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	const previousTimeout = process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-ask-"));
	const parentId = "parent-session-forward";
	process.env.PI_SUBAGENT_PARENT_SESSION = parentId;
	process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = "2000";
	process.env.RYK_PI_ASK_ROOT = askRoot;
	let clock = 0;
	try {
		const { pi, handlers, messages } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
			now: () => clock,
			sleep: async (ms) => {
				// First poll: answer any pending request from parent side.
				const dir = parentAskDir(askRoot, parentId);
				const pending = listPendingRequests(dir);
				for (const req of pending) {
					writeAskResponse(dir, {
						v: 1,
						id: req.id,
						choice: "run_once",
						decided_at_ms: clock,
					});
				}
				clock += ms;
			},
		});
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });
		(ctx.ui as any).select = async () => {
			throw new Error("child must not call select");
		};

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "src/main.ts", content: "x" },
		);
		assert.equal(result, undefined, "parent run_once should allow");
		const onceAudit = messages.find(
			(m) =>
				(m.message.details as { event?: string } | undefined)?.event ===
				"orca_once_bypass",
		);
		assert.ok(onceAudit, "expected once-bypass audit after parent allow");
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
		if (previousTimeout === undefined)
			delete process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
		else process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = previousTimeout;
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		rmSync(askRoot, { recursive: true, force: true });
	}
});

test("policy ask subagent denies when parent responds block", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	const previousTimeout = process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-ask-"));
	const parentId = "parent-session-block";
	process.env.PI_SUBAGENT_PARENT_SESSION = parentId;
	process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = "2000";
	process.env.RYK_PI_ASK_ROOT = askRoot;
	let clock = 0;
	try {
		const { pi, handlers } = makePi();
		const { spawn } = makeSpawn([
			{ code: 7, stdout: decideJson("ask", "file.write") },
		]);
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
			now: () => clock,
			sleep: async (ms) => {
				const dir = parentAskDir(askRoot, parentId);
				for (const req of listPendingRequests(dir)) {
					writeAskResponse(dir, {
						v: 1,
						id: req.id,
						choice: "block",
						decided_at_ms: clock,
					});
				}
				clock += ms;
			},
		});
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "src/main.ts", content: "x" },
		);
		assert.equal(result?.block, true);
		assert.ok(!/auto-denied/i.test(result?.reason ?? ""));
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
		if (previousTimeout === undefined)
			delete process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
		else process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = previousTimeout;
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		rmSync(askRoot, { recursive: true, force: true });
	}
});

test("session grant short-circuits decide for granted tool name", async () => {
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-ask-"));
	process.env.RYK_PI_ASK_ROOT = askRoot;
	try {
		const sessionId = "session-grant-main";
		const dir = parentAskDir(askRoot, sessionId);
		addSessionGrant(dir, "ctx_batch_execute", Date.now());
		assert.equal(hasSessionGrant(dir, "ctx_batch_execute"), true);

		const { pi, handlers, messages } = makePi();
		const { spawn, calls } = makeSpawn();
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
		});
		const { ctx } = makeCtx({
			hasUI: true,
			mode: "tui",
			sessionManager: { getSessionId: () => sessionId },
		});

		const result = await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"ctx_batch_execute",
			{ query: "x" },
		);
		assert.equal(result, undefined, "grant hit must allow");
		assert.equal(calls.length, 0, "grant hit must skip decide spawn");
		const grantAudit = messages.find(
			(m) =>
				(m.message.details as { event?: string } | undefined)?.event ===
				"orca_session_grant_hit",
		);
		assert.ok(grantAudit, "expected orca_session_grant_hit audit");
	} finally {
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		rmSync(askRoot, { recursive: true, force: true });
	}
});

test("parent main session answers pending child ask via select", async () => {
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const previousParent = process.env.PI_SUBAGENT_PARENT_SESSION;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-ask-"));
	process.env.RYK_PI_ASK_ROOT = askRoot;
	delete process.env.PI_SUBAGENT_PARENT_SESSION;
	const parentId = "parent-poll-session";
	try {
		const dir = parentAskDir(askRoot, parentId);
		// Seed a pending child request.
		writeAskRequest(dir, {
			v: 1,
			id: "req-test-1",
			parent_session: parentId,
			tool: "write",
			reason: "needs approval",
			command_or_name: "src/main.ts",
			created_at_ms: 1,
			timeout_ms: 60_000,
		});

		const { pi, handlers, messages } = makePi();
		const { spawn } = makeSpawn([
			{ code: 0, stdout: decideAllowJson("file.write") },
		]);
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
			now: () => 100,
		});
		const { ctx, selections } = makeCtx({
			hasUI: true,
			mode: "tui",
			sessionManager: { getSessionId: () => parentId },
		});
		selections.push("Block");

		// Fire any tool call so parent poll drains pending asks.
		await fireToolCall(
			handlers.get("tool_call")![0],
			ctx,
			"",
			"write",
			{ path: "ok.ts", content: "y" },
		);

		const resPath = resolve(dir, "res-req-test-1.json");
		const res = JSON.parse(readFileSync(resPath, "utf8")) as {
			choice: string;
			id: string;
		};
		assert.equal(res.id, "req-test-1");
		assert.equal(res.choice, "block");
		const parentAudit = messages.find(
			(m) =>
				(m.message.details as { event?: string } | undefined)?.event ===
				"orca_parent_ask_response",
		);
		assert.ok(parentAudit, "expected parent ask response audit");
	} finally {
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		if (previousParent === undefined)
			delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previousParent;
		rmSync(askRoot, { recursive: true, force: true });
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
		installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
		installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("bash safe command with Orca allow returns undefined", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx();

	const result = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"git status",
	);
	assert.equal(result, undefined);
});

test("bash dangerous command with Orca deny returns block", async () => {
	const { pi, handlers, messages } = makePi();
	const { spawn } = makeSpawn([{ code: 2, stdout: denyJson() }]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
		"expected a compact, aligned 56-column Orca card",
	);
});

test("Orca inline decision keeps long reasons inside the compact frame", async () => {
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx();

	await fireToolCall(handlers.get("tool_call")![0], ctx, "dangerous-command");

	const inlineDecision = messages[0]?.message.content;
	assert.ok(inlineDecision, "expected inline Orca decision content");
	assert.ok(
		inlineDecision.split("\n").every((line) => line.length === 56),
		"expected every long-reason card line to stay inside the frame",
	);
	assert.match(inlineDecision, /Why: unsafe-/);
	assert.match(inlineDecision, /command escaped policy/);
});

test("bash dangerous command with Orca deny blocks even when exit code is not 2", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: denyJson() }]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("Orca error in non-interactive mode blocks", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /\/ryk-doctor|Fail-closed|malformed|unavailable|error/i);
});

test("Orca error in interactive mode waits for the user's decision", async () => {
	const { pi, handlers } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	assert.ok(askWidget, "expected Orca ask widget");
	assert.deepEqual(askWidget.opts, { placement: "aboveEditor" });
	assert.match(askWidget.value?.join("\n") ?? "", /RYK \/\/ YOUR CALL/);
	assert.match(
		askWidget.value?.join("\n") ?? "",
		/RYK PAUSED THIS COMMAND/,
	);
	assert.match(
		askWidget.value?.join("\n") ?? "",
		/Choose: Allow session, allow once, or block\./,
	);
	assert.ok(
		askWidget.value?.every((line) => line.length === 56),
		"expected a compact, aligned 56-column Orca ask card",
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx({ hasUI: true, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /\/ryk-doctor|Fail-closed|malformed|unavailable|error/i);
});

test("strict mode blocks", async () => {
	const { pi, handlers, commands } = makePi();
	const err = { code: 3 as number, stdout: errorJson() };
	const { spawn } = makeSpawn([err, err]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "missing-orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx();
	await commands.get("orca-mode")!.handler("allow-with-warning", ctx);

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /Failure class|unexpected|daemon/i);
	// Non-transient: single attempt.
	assert.equal(calls.length, 1);
});

test("malformed Orca JSON follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	// Retry once: both attempts malformed → still fail-closed with class token.
	const { spawn } = makeSpawn([
		{ code: 0, stdout: "{not-json" },
		{ code: 0, stdout: "{not-json" },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /malformed JSON|malformed_json|Fail-closed/i);
	// Diagnostics must surface what the child actually emitted.
	assert.match(result.reason, /exit 0/);
	assert.match(result.reason, /\{not-json/);
});

test("repairMessage stays short enough for the ask card", () => {
	const long = formatProtocolErrorReason(
		"malformed_json",
		formatMalformedJsonDetail(
			{
				code: 0,
				stdout: "{not-json " + "x".repeat(200),
				stderr: "noise",
			},
			"evaluate",
		),
	);
	const card = repairMessage(long, "bash");
	assert.ok(card.length <= 220, card);
	assert.match(card, /Fail-closed/);
	assert.match(card, /\/ryk-doctor/);
	assert.doesNotMatch(card, /Coverage:/);
	assert.doesNotMatch(card, /not a permanent session brick/i);
});

test("protocol block choice sticks for the rest of the session", async () => {
	const { pi, handlers } = makePi();
	const bad = { code: 0 as number, stdout: "{not-json" };
	// Two tools × one retry each = 4 spawns if both go through evaluate; sticky may still evaluate.
	const { spawn, calls } = makeSpawn([bad, bad, bad, bad, bad, bad]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx, selections } = makeCtx();
	selections.push(protocolBlockOptionLabel());

	const first = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(first?.block, true);
	const selectsBefore = selections.length;

	// Second protocol failure must not open another select (sticky block).
	const second = await fireToolCall(
		handlers.get("tool_call")![0],
		ctx,
		"echo again",
	);
	assert.equal(second?.block, true);
	assert.equal(selections.length, selectsBefore, "no second select");
	assert.ok(calls.length >= 2);
});

test("subagent protocol failure parent-forwards instead of silent local brick", async () => {
	const previous = process.env.PI_SUBAGENT_PARENT_SESSION;
	const previousTimeout = process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
	const previousRoot = process.env.RYK_PI_ASK_ROOT;
	const askRoot = mkdtempSync(resolve(tmpdir(), "ryk-pi-proto-"));
	const parentId = "parent-proto-session";
	process.env.PI_SUBAGENT_PARENT_SESSION = parentId;
	process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = "2000";
	process.env.RYK_PI_ASK_ROOT = askRoot;
	let clock = 0;
	let sawProtocolAsk = false;
	try {
		const { pi, handlers, messages } = makePi();
		const bad = { code: 0 as number, stdout: "{not-json" };
		const { spawn } = makeSpawn([bad, bad]);
		installOrcaExtension(pi, {
			spawn,
			orcaBin: "orca",
			piAskRoot: askRoot,
			parentAskPollMs: 0,
			now: () => clock,
			sleep: async (ms) => {
				const dir = parentAskDir(askRoot, parentId);
				const pending = listPendingRequests(dir);
				for (const req of pending) {
					if (/\[protocol\]|malformed/i.test(req.reason)) sawProtocolAsk = true;
					writeAskResponse(dir, {
						v: 1,
						id: req.id,
						choice: "run_once",
						decided_at_ms: clock,
					});
				}
				clock += ms;
			},
		});
		const { ctx } = makeCtx({ hasUI: true, mode: "tui" });
		(ctx.ui as any).select = async () => {
			throw new Error("child must not local-select on protocol recovery");
		};

		const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
		assert.equal(result, undefined, "parent run_once should allow through");
		assert.equal(sawProtocolAsk, true, "expected [protocol] parent-forward ask");
		const onceAudit = messages.find(
			(m) =>
				(m.message.details as { event?: string } | undefined)?.event ===
				"orca_once_bypass",
		);
		assert.ok(onceAudit, "expected once-bypass audit after parent allow");
	} finally {
		if (previous === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION;
		else process.env.PI_SUBAGENT_PARENT_SESSION = previous;
		if (previousTimeout === undefined)
			delete process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS;
		else process.env.RYK_PI_PARENT_ASK_TIMEOUT_MS = previousTimeout;
		if (previousRoot === undefined) delete process.env.RYK_PI_ASK_ROOT;
		else process.env.RYK_PI_ASK_ROOT = previousRoot;
		rmSync(askRoot, { recursive: true, force: true });
	}
});

test("child process failure follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const { spawn } = makeSpawn([
		{ error: new Error("ENOENT") },
		{ error: new Error("ENOENT") },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "missing-orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx } = makeCtx();

	const result = await handlers.get("tool_call")![0](
		{ toolName: "bash", input: { command: 123 } },
		ctx,
	);
	assert.equal(result.block, true);
	assert.match(result.reason, /malformed Pi bash tool call/);
	assert.equal(calls.length, 0);
});

test("/orca-doctor handles Orca present", async () => {
	const { pi, commands } = makePi();
	const { spawn } = makeSpawn([{ code: 0, stdout: '{"ok":true}' }]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-doctor")!.handler("", ctx);
	assert.equal(notifications.at(-1)?.type, "info");
	assert.match(notifications.at(-1)!.message, /ok/);
	assert.match(notifications.at(-1)!.message, /Coverage:/);
	assert.match(notifications.at(-1)!.message, /bash \+ write \+ edit \+ read policy-protected/);
});

test("/orca-doctor handles Orca missing", async () => {
	const { pi, commands } = makePi();
	const { spawn } = makeSpawn([{ error: new Error("ENOENT") }]);
	installOrcaExtension(pi, { spawn, orcaBin: "missing-orca" });
	const { ctx, notifications } = makeCtx();

	await commands.get("orca-doctor")!.handler("", ctx);
	assert.equal(notifications.at(-1)?.type, "error");
	assert.match(notifications.at(-1)!.message, /not found/);
	assert.match(notifications.at(-1)!.message, /Coverage:/);
});

test("/orca-stop disables Pi bash protection until /orca-start re-enables it", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-"));
	mkdirSync(resolve(cwd, ".orca"));
	writeFileSync(resolve(cwd, ".orca/policy.yaml"), "version: 1\n");
	const { pi, commands, handlers } = makePi();
	const { spawn, calls } = makeSpawn([
		{ code: 0, stdout: "healthy" },
		{ code: 0, stdout: allowJson() },
	]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("/orca-start re-enables without invoking the CLI start command", async () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-"));
	mkdirSync(resolve(cwd, ".orca"));
	writeFileSync(resolve(cwd, ".orca/policy.yaml"), "version: 1\n");
	const present = makePi();
	const presentSpawn = makeSpawn([{ code: 0, stdout: "healthy" }]);
	installOrcaExtension(present.pi, {
		spawn: presentSpawn.spawn,
		orcaBin: "orca",
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
	installOrcaExtension(missing.pi, {
		spawn: missingSpawn.spawn,
		orcaBin: "missing-orca",
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

test("/orca-mode changes mode", async () => {
	const { pi, commands } = makePi();
	installOrcaExtension(pi, { spawn: makeSpawn().spawn, orcaBin: "orca" });
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

test("no shell interpolation is used when invoking Orca", async () => {
	const { spawn, calls } = makeSpawn([{ code: 0, stdout: allowJson() }]);
	await runOrcaEvaluate(
		buildEvaluateRequest("echo safe", { cwd: process.cwd(), mode: "print" }),
		{
			spawn,
			orcaBin: "orca",
			timeoutMs: 1_000,
		},
	);

	assert.equal(calls[0].file, "orca");
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
			orcaBin: "orca",
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

test("oversized Orca output follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const huge = "x".repeat(1024 * 1024 + 1);
	const plan = { code: 0 as number, stdout: huge };
	const { spawn } = makeSpawn([plan, plan]);
	installOrcaExtension(pi, { spawn, orcaBin: "orca" });
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

test("Orca timeout follows unavailable policy", async () => {
	const { pi, handlers } = makePi();
	const spawn = (): FakeChild => {
		const child = new FakeChild();
		setTimeout(() => child.close(143), 5);
		return child;
	};
	installOrcaExtension(pi, { spawn, orcaBin: "orca", timeoutMs: 1 });
	const { ctx } = makeCtx({ hasUI: false, mode: "print" });

	const result = await fireToolCall(handlers.get("tool_call")![0], ctx);
	assert.equal(result.block, true);
	assert.match(result.reason, /timed out/);
});
