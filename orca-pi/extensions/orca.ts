import { spawn as nodeSpawn } from "node:child_process";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, resolve } from "node:path";
import {
	handleSecretCaptureInput,
	isSecretCaptureDisabled,
	scrubContextMessages,
} from "./secret_capture.ts";

type UnavailableMode =
	| "auto"
	| "ask"
	| "noninteractive-block"
	| "strict"
	| "allow-with-warning";
type EffectiveUnavailableMode =
	| "ask"
	| "noninteractive-block"
	| "strict"
	| "allow-with-warning";

type ToolCallBlock = { block: true; reason?: string };
type ToolCallResult = ToolCallBlock | undefined;

type PiToolCallEvent = {
	toolName: string;
	input?: Record<string, unknown>;
};

type PiUI = {
	select?: (
		title: string,
		options: string[],
		opts?: { timeout?: number; signal?: AbortSignal },
	) => Promise<string | undefined>;
	confirm?: (
		title: string,
		message: string,
		opts?: { timeout?: number; signal?: AbortSignal },
	) => Promise<boolean | undefined>;
	notify?: (message: string, type?: "info" | "warning" | "error") => void;
	setStatus?: (key: string, text: string | undefined) => void;
	setWidget?: (
		key: string,
		value: undefined | string[],
		opts?: { placement?: "aboveEditor" | "belowEditor" },
	) => void;
};

type PiContext = {
	ui?: PiUI;
	cwd?: string;
	mode?: string;
	hasUI?: boolean;
	signal?: AbortSignal;
	sessionManager?: {
		getSessionId?: () => string;
	};
};

type PiAPI = {
	on: (
		event: string,
		handler: (event: any, ctx: PiContext) => Promise<any> | any,
	) => void;
	registerCommand: (
		name: string,
		options: {
			description?: string;
			handler: (
				args: string | undefined,
				ctx: PiContext,
			) => Promise<void> | void;
		},
	) => void;
	sendMessage?: (
		message: {
			customType: string;
			content: string;
			display: boolean;
			details?: unknown;
		},
		options?: {
			triggerTurn?: boolean;
			deliverAs?: "steer" | "followUp" | "nextTurn";
		},
	) => void;
};

type SpawnOptions = {
	stdio: ["pipe" | "ignore", "pipe" | "ignore", "pipe" | "ignore"];
	shell: false;
	signal?: AbortSignal;
	env?: NodeJS.ProcessEnv;
	cwd?: string;
};

type SpawnSyncLike = (
	file: string,
	args: string[],
	options: {
		encoding: "utf8";
		env: NodeJS.ProcessEnv;
		shell: false;
		timeout: number;
	},
) => { error?: Error; status: number | null; stdout?: string };

type ChildLike = {
	stdin?: { write: (data: string) => void; end: () => void };
	stdout?: {
		on: (event: "data", handler: (chunk: Buffer | string) => void) => void;
	};
	stderr?: {
		on: (event: "data", handler: (chunk: Buffer | string) => void) => void;
	};
	on: (
		event: "error" | "close",
		handler: ((error: Error) => void) | ((code: number | null) => void),
	) => void;
};

type SpawnLike = (
	file: string,
	args: string[],
	options: SpawnOptions,
) => ChildLike;

/**
 * Built-in Pi tools with specialized evaluators (evaluate / decide file).
 * All other tool names are still intercepted via name-gated `orca decide tool`.
 */
export const PROTECTED_PI_TOOLS = [
	"bash",
	"write",
	"edit",
	"read",
	"grep",
	"find",
	"ls",
] as const;
export type ProtectedPiTool = (typeof PROTECTED_PI_TOOLS)[number];

/** File tools that use Zig `orca decide file` with operation write. */
const FILE_WRITE_TOOLS = new Set<string>(["write", "edit"]);
/** File tools that use Zig `orca decide file` with operation read. */
const FILE_READ_TOOLS = new Set<string>(["read", "grep", "find", "ls"]);
/** Discovery tools can traverse/read descendants that a root-only preflight cannot prove safe. */
const BROAD_DISCOVERY_TOOLS = new Set<string>(["grep", "find", "ls"]);

export function isProtectedPiTool(toolName: string): toolName is ProtectedPiTool {
	return (PROTECTED_PI_TOOLS as readonly string[]).includes(toolName);
}

/** Honest coverage string for doctor/status surfaces. */
export function piCoverageLabel(): string {
	return "bash + write + edit + read policy-protected; grep + find + ls approval-gated (descendants not individually evaluated); custom tool names gated via decide tool (not full MCP protocol mediation)";
}

/**
 * Path target for decide-file preflight.
 * - read/write/edit: require non-empty `path`
 * - grep/find/ls: optional `path` (Pi defaults to cwd / "."); use that default when omitted
 */
export function extractDecideFilePath(
	toolName: string,
	input: Record<string, unknown> | undefined,
): { path: string; required: boolean } | null {
	const raw = typeof input?.path === "string" ? input.path.trim() : "";
	if (toolName === "read" || FILE_WRITE_TOOLS.has(toolName)) {
		return { path: raw, required: true };
	}
	if (FILE_READ_TOOLS.has(toolName)) {
		// Pi grep/find/ls default search/list root is cwd when path is omitted.
		return { path: raw || ".", required: false };
	}
	return null;
}

export type OrcaEvaluateRequest = {
	schema_version: 1;
	request_id: string;
	kind: "shell_command";
	command: string;
	cwd: string;
	source: {
		host: "pi";
		tool_name: string;
		mode?: string;
		session_id?: string;
	};
};

export type OrcaDecideFileRequest = {
	path: string;
	operation: "read" | "write";
};

/** Custom / MCP-shaped tool names → Zig `orca decide tool` (name only). */
export type OrcaDecideToolRequest = {
	name: string;
};

export type OrcaDecision =
	| { kind: "allow"; response: unknown }
	| { kind: "deny"; reason: string; response: unknown }
	| { kind: "ask"; reason: string; response: unknown }
	| { kind: "warn"; reason: string; response: unknown }
	| { kind: "error"; reason: string; response?: unknown; error?: Error };

type OrcaEvaluateResponse = {
	decision?: string;
	reason?: string;
	message?: string;
	severity?: string;
	rule_id?: string;
	ruleId?: string;
	pack_id?: string;
	packId?: string;
	pattern_name?: string;
	patternName?: string;
	remediation?: Array<{ description?: string }>;
	error?: { message?: string };
};

type OrcaDecisionCard = {
	variant: "block" | "ask";
	title: string;
	summary: string;
	rule?: string;
	pack?: string;
	severity?: string;
	nextStep?: string;
};

type RunProcessResult = {
	code: number | null;
	stdout: string;
	stderr: string;
	error?: Error;
	timedOut?: boolean;
};

type SetupResult = {
	status: "ready" | "missing" | "degraded";
	message: string;
};
type SessionState = {
	bypass: boolean;
	status: SetupResult["status"];
	bootstrap?: Promise<SetupResult>;
};

export type OrcaExtensionOptions = {
	orcaBin?: string;
	resolveBin?: () => ResolvedOrcaBin;
	spawn?: SpawnLike;
	timeoutMs?: number;
};

export type ResolvedOrcaBin = {
	orcaBin: string;
	daemonBin?: string;
	source: "explicit" | "bundled" | "path" | "missing";
};

type ResolveOrcaBinOptions = {
	env?: NodeJS.ProcessEnv;
	bundledPackageRoot?: string;
	isExecutable?: (path: string) => boolean;
	isCompatiblePathOrca?: () => boolean;
	spawnSync?: SpawnSyncLike;
};

const STATUS_KEY = "orca";
const BLOCK_WIDGET_KEY = "orca-block";
const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_CHILD_OUTPUT_BYTES = 1024 * 1024;
const REQUIRED_ORCA_VERSION = (() => {
	const deps = (
		createRequire(import.meta.url)("../package.json") as {
			dependencies: Record<string, string>;
		}
	).dependencies;
	// Prefer @orca-sec/ryk when present; keep @orca-sec/orca during dual-name window.
	return deps["@orca-sec/ryk"] ?? deps["@orca-sec/orca"];
})();
const ASK_OPTIONS = [
	"Block",
	"Run once anyway",
	"Disable Orca for this Pi session",
	"Show repair instructions / run doctor",
] as const;
const POLICY_ASK_OPTIONS = [
	"Block",
	"Run once anyway",
	"Disable Orca for this Pi session",
	"Show policy reason",
] as const;
const ONCE_OPTION = "Run once anyway";

/**
 * Whether interactive prompts may offer "Run once anyway".
 * - `ORCA_PI_ALLOW_ONCE=false|0|no` disables always
 * - `ORCA_PI_MODE=strict` disables by default (production hardening)
 * - `ORCA_PI_ALLOW_ONCE=true` re-enables even under strict
 */
export function allowOnceBypassEnabled(
	env: NodeJS.ProcessEnv = process.env,
	unavailableMode?: UnavailableMode,
): boolean {
	const raw = env.ORCA_PI_ALLOW_ONCE?.trim().toLowerCase();
	if (raw === "false" || raw === "0" || raw === "no") return false;
	if (raw === "true" || raw === "1" || raw === "yes") return true;
	if (unavailableMode === "strict") return false;
	return true;
}

export function askOptionsFor(
	kind: "policy" | "unavailable",
	allowOnce: boolean,
): string[] {
	const base =
		kind === "policy" ? [...POLICY_ASK_OPTIONS] : [...ASK_OPTIONS];
	if (allowOnce) return base;
	return base.filter((option) => option !== ONCE_OPTION);
}

const DECIDE_EXIT_CODE = {
	allow: 0,
	context_only: 0,
	block: 3,
	ask: 7,
	warn: 8,
	error: 1,
} as const;

export function resolveOrcaBin(
	options: ResolveOrcaBinOptions = {},
): ResolvedOrcaBin {
	const env = options.env ?? process.env;
	const isExecutable = options.isExecutable ?? isExecutableFile;
	// Phase 5a: prefer RYK_BIN, fall back ORCA_BIN.
	const explicit = (env.RYK_BIN ?? env.ORCA_BIN)?.trim();
	if (explicit && isExecutable(explicit))
		return { orcaBin: explicit, source: "explicit" };

	const packageRoot = options.bundledPackageRoot ?? resolveBundledPackageRoot();
	if (packageRoot) {
		const executableSuffix = process.platform === "win32" ? ".exe" : "";
		const rykBin = resolve(packageRoot, "vendor", `ryk${executableSuffix}`);
		const orcaBin = resolve(packageRoot, "vendor", `orca${executableSuffix}`);
		const daemonBin = resolve(
			packageRoot,
			"vendor",
			`orca-daemon${executableSuffix}`,
		);
		// Prefer ryk vendor binary when present; daemon optional (shell_engine in-process).
		if (isExecutable(rykBin)) {
			return {
				orcaBin: rykBin,
				daemonBin: isExecutable(daemonBin) ? daemonBin : undefined,
				source: "bundled",
			};
		}
		if (isExecutable(orcaBin) && isExecutable(daemonBin)) {
			return { orcaBin, daemonBin, source: "bundled" };
		}
		if (isExecutable(orcaBin)) {
			return { orcaBin, source: "bundled" };
		}
	}

	const allowPath =
		env.RYK_PI_USE_PATH === "true" || env.ORCA_PI_USE_PATH === "true";
	if (allowPath) {
		if (options.isCompatiblePathOrca) {
			if (options.isCompatiblePathOrca()) {
				// Injected compat checks historically meant "orca on PATH"; prefer ryk name when unknown.
				return { orcaBin: "ryk", source: "path" };
			}
		} else {
			const pathBin = resolveCompatiblePathCli(
				env,
				options.spawnSync ?? spawnSync,
			);
			if (pathBin) return { orcaBin: pathBin, source: "path" };
		}
	}

	return { orcaBin: "__orca_bundled_runtime_missing__", source: "missing" };
}

export function buildEvaluateRequest(
	command: string,
	ctx: PiContext,
	toolName = "bash",
): OrcaEvaluateRequest {
	return {
		schema_version: 1,
		request_id: `pi-${randomUUID()}`,
		kind: "shell_command",
		command,
		cwd: resolveCwd(ctx.cwd),
		source: {
			host: "pi",
			tool_name: toolName,
			mode: ctx.mode,
			session_id: sessionKey(ctx),
		},
	};
}

export function buildDecideFilePayload(
	path: string,
	operation: "read" | "write" = "write",
): OrcaDecideFileRequest {
	return { path, operation };
}

/** Payload for `orca decide tool --json` (tool name only; no arg extraction). */
export function buildDecideToolPayload(input: {
	name: string;
}): OrcaDecideToolRequest {
	return { name: input.name.trim() };
}

export function resolveToolPath(pathInput: string, ctx: PiContext): string {
	const trimmed = pathInput.trim();
	if (!trimmed) return trimmed;
	if (isAbsolute(trimmed)) return resolve(trimmed);
	return resolve(resolveCwd(ctx.cwd), trimmed);
}

export async function runOrcaEvaluate(
	request: OrcaEvaluateRequest,
	options: Required<
		Pick<OrcaExtensionOptions, "orcaBin" | "spawn" | "timeoutMs">
	> & { env?: NodeJS.ProcessEnv },
): Promise<OrcaDecision> {
	const result = await runProcess(
		options.orcaBin,
		["evaluate", "--json", "--stdin"],
		JSON.stringify(request),
		options.spawn,
		options.timeoutMs,
		options.env,
		request.cwd,
	);

	if (result.timedOut) {
		return { kind: "error", reason: "Orca evaluation timed out." };
	}

	if (result.error) {
		const reason =
			result.error.message === "Orca output exceeded maximum size"
				? "Orca output exceeded maximum size."
				: "Orca is unavailable.";
		return { kind: "error", reason, error: result.error };
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(result.stdout);
	} catch {
		return { kind: "error", reason: "Orca returned malformed JSON." };
	}

	const decision = getStringField(parsed, "decision");
	if (decision === "allow" && result.code === 0) {
		return { kind: "allow", response: parsed };
	}
	// evaluate ask uses exit 0 with decision "ask" (allow/deny exit contract preserved).
	if (decision === "ask" && (result.code === 0 || result.code === null)) {
		return {
			kind: "ask",
			reason: sanitizeVisibleText(getDecisionReason(parsed)),
			response: parsed,
		};
	}
	if (decision === "deny") {
		return { kind: "deny", reason: safeOrcaReason(parsed), response: parsed };
	}
	if (decision === "error") {
		return {
			kind: "error",
			reason: sanitizeVisibleText(getDecisionReason(parsed)),
			response: parsed,
		};
	}

	return {
		kind: "error",
		reason: `Orca returned an unexpected evaluation result (exit ${result.code ?? "unknown"}).`,
		response: parsed,
	};
}

type DecideRuntimeOptions = Required<
	Pick<OrcaExtensionOptions, "orcaBin" | "spawn" | "timeoutMs">
> & { env?: NodeJS.ProcessEnv; cwd?: string };

/**
 * Shared `orca decide <kind> --json` runner. Fail-closed on timeout, spawn
 * error, malformed JSON, and decision/exit-code mismatch.
 */
async function runOrcaDecide(
	kind: "file" | "tool",
	payload: object,
	options: DecideRuntimeOptions,
	map: {
		defaultReason: string;
		/** File write only: context_only must not allow side effects. */
		denyContextOnly?: boolean;
	},
): Promise<OrcaDecision> {
	const result = await runProcess(
		options.orcaBin,
		["decide", kind, "--json", JSON.stringify(payload)],
		undefined,
		options.spawn,
		options.timeoutMs,
		options.env,
		options.cwd,
	);

	if (result.timedOut) {
		return { kind: "error", reason: "Orca decide timed out." };
	}
	if (result.error) {
		const reason =
			result.error.message === "Orca output exceeded maximum size"
				? "Orca output exceeded maximum size."
				: "Orca is unavailable.";
		return { kind: "error", reason, error: result.error };
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(result.stdout);
	} catch {
		return { kind: "error", reason: "Orca decide returned malformed JSON." };
	}

	const decision = getStringField(parsed, "decision");
	const reason = sanitizeVisibleText(
		getStringFieldAny(parsed, ["reason", "message"]) ?? map.defaultReason,
	);
	// Trust a machine decision only when process status matches the frozen
	// `orca decide` exit-code contract. Mismatches fail closed.
	if (
		!decision ||
		!(decision in DECIDE_EXIT_CODE) ||
		result.code !== DECIDE_EXIT_CODE[decision as keyof typeof DECIDE_EXIT_CODE]
	) {
		return {
			kind: "error",
			reason: `Orca decide returned an inconsistent result (decision ${decision ?? "missing"}, exit ${result.code ?? "signal"}).`,
			response: parsed,
		};
	}

	// decide uses allow | block | ask | warn | context_only | error.
	if (decision === "context_only" && map.denyContextOnly) {
		const response = {
			...(parsed as Record<string, unknown>),
			decision: "deny",
			reason: "Orca allowed context only; write side effects are not permitted.",
		};
		return { kind: "deny", reason: safeOrcaReason(response), response };
	}
	if (decision === "allow" || decision === "context_only") {
		return { kind: "allow", response: parsed };
	}
	if (decision === "block") {
		const normalized = normalizeDecideToEvaluateShape(parsed);
		return {
			kind: "deny",
			reason: safeOrcaReason(normalized),
			response: normalized,
		};
	}
	if (decision === "ask") {
		return { kind: "ask", reason, response: parsed };
	}
	if (decision === "warn") {
		return { kind: "warn", reason, response: parsed };
	}
	if (decision === "error") {
		return { kind: "error", reason, response: parsed };
	}

	return {
		kind: "error",
		reason: `Orca decide returned an unexpected result (exit ${result.code ?? "unknown"}).`,
		response: parsed,
	};
}

/** Non-shell file tools → Zig `orca decide file` (path only; not daemon Evaluate). */
export async function runOrcaDecideFile(
	payload: OrcaDecideFileRequest,
	options: DecideRuntimeOptions,
): Promise<OrcaDecision> {
	return runOrcaDecide("file", payload, options, {
		defaultReason: "Orca blocked this file action.",
		denyContextOnly: payload.operation === "write",
	});
}

/**
 * Custom / MCP-shaped tools → Zig `orca decide tool` (name only).
 * Does not extract paths or args from custom tool inputs.
 */
export async function runOrcaDecideTool(
	payload: OrcaDecideToolRequest,
	options: DecideRuntimeOptions,
): Promise<OrcaDecision> {
	return runOrcaDecide("tool", payload, options, {
		defaultReason: "Orca blocked this tool action.",
	});
}

function normalizeDecideToEvaluateShape(response: unknown): unknown {
	if (!response || typeof response !== "object") return response;
	const obj = response as Record<string, unknown>;
	return {
		...obj,
		decision: obj.decision === "block" ? "deny" : obj.decision,
		rule_id: typeof obj.rule === "string" ? obj.rule : obj.rule_id,
	};
}

function blockMalformedToolCall(
	pi: PiAPI,
	ctx: PiContext,
	toolLabel: string,
	summary: string,
): ToolCallResult {
	const details = {
		variant: "block" as const,
		title: "ORCA BLOCKED",
		summary,
	};
	showOrcaDecision(pi, ctx, details);
	return block(formatOrcaDecisionSummary(details, toolLabel));
}

export async function runOrcaCommand(
	args: string[],
	options: Required<
		Pick<OrcaExtensionOptions, "orcaBin" | "spawn" | "timeoutMs">
	> & { env?: NodeJS.ProcessEnv },
	cwd?: string,
): Promise<RunProcessResult> {
	return runProcess(
		options.orcaBin,
		args,
		undefined,
		options.spawn,
		options.timeoutMs,
		options.env,
		cwd,
	);
}

export function resolveUnavailableMode(
	configured: UnavailableMode,
	ctx: PiContext,
): EffectiveUnavailableMode {
	if (configured === "auto")
		return isNoninteractiveSession(ctx) ? "noninteractive-block" : "ask";
	if (configured === "ask" && isNoninteractiveSession(ctx))
		return "noninteractive-block";
	return configured;
}

function isNoninteractiveSession(ctx: PiContext): boolean {
	return ctx.hasUI !== true || isNoninteractiveMode(ctx.mode);
}

function isNoninteractiveMode(mode: string | undefined): boolean {
	return mode === "print" || mode === "json" || mode === "noninteractive";
}

export function safeOrcaReason(response: unknown): string {
	return formatOrcaDecisionSummary(buildOrcaDecisionCard(response, "block"));
}

export function installOrcaExtension(
	pi: PiAPI,
	extensionOptions: OrcaExtensionOptions = {},
): void {
	const resolvedBin = extensionOptions.orcaBin
		? { orcaBin: extensionOptions.orcaBin, source: "explicit" as const }
		: (extensionOptions.resolveBin ?? resolveOrcaBin)();
	const runtime = {
		orcaBin: resolvedBin.orcaBin,
		spawn: extensionOptions.spawn ?? (nodeSpawn as unknown as SpawnLike),
		timeoutMs:
			extensionOptions.timeoutMs ??
			Number(process.env.ORCA_PI_TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS),
		env: resolvedBin.daemonBin
			? { ...process.env, ORCA_DAEMON: resolvedBin.daemonBin }
			: process.env,
	};

	let unavailableMode: UnavailableMode =
		parseMode(process.env.ORCA_PI_MODE) ?? "auto";
	const sessionState = new Map<string, SessionState>();

	const stateFor = (ctx: PiContext): SessionState => {
		const key = sessionKey(ctx);
		const current = sessionState.get(key);
		if (current) return current;
		const next = { bypass: false, status: "degraded" as const };
		sessionState.set(key, next);
		return next;
	};

	const updateStatus = (ctx: PiContext): void => {
		if (stateFor(ctx).bypass) {
			ctx.ui?.setStatus?.(STATUS_KEY, "orca bypass");
			return;
		}
		ctx.ui?.setStatus?.(STATUS_KEY, `orca ${stateFor(ctx).status}`);
	};

	pi.on("session_start", (_event, ctx) => {
		const state = stateFor(ctx);
		state.bypass = false;
		state.status = "degraded";
		updateStatus(ctx);
		if (process.env.ORCA_PI_AUTO_SETUP === "false") {
			state.status = "ready";
			updateStatus(ctx);
			return;
		}
		state.bootstrap = setupOrca(ctx, runtime);
		void state.bootstrap.then((result) => {
			state.status = result.status;
			updateStatus(ctx);
		});
	});

	pi.on("session_shutdown", (_event, ctx) => {
		stateFor(ctx).bypass = false;
		ctx.ui?.setStatus?.(STATUS_KEY, undefined);
		clearOrcaWidget(ctx);
	});

	// Credential capture from prompt (Pi only). Still runs when bash bypass is on
	// so secrets are not forwarded to the model by default.
	pi.on("input", async (event, ctx: PiContext) => {
		if (isSecretCaptureDisabled()) return { action: "continue" as const };
		return handleSecretCaptureInput(
			{
				text: typeof event?.text === "string" ? event.text : "",
				source: typeof event?.source === "string" ? event.source : undefined,
				images: event?.images,
			},
			ctx,
		);
	});

	// Defense in depth: scrub any secret-like spans still present in user messages
	// before the LLM call (no consent/store prompts on history).
	pi.on("context", async (event) => {
		if (isSecretCaptureDisabled()) return undefined;
		const messages = event?.messages;
		if (!Array.isArray(messages)) return undefined;
		const scrubbed = scrubContextMessages(
			messages as Array<Record<string, unknown>>,
		);
		return { messages: scrubbed };
	});

	pi.on(
		"tool_call",
		async (event: PiToolCallEvent, ctx: PiContext): Promise<ToolCallResult> => {
			await stateFor(ctx).bootstrap;

			if (stateFor(ctx).bypass) {
				clearOrcaWidget(ctx);
				ctx.ui?.notify?.(
					`Orca protection is disabled for this Pi session; ${event.toolName} allowed without Orca evaluation.`,
					"warning",
				);
				updateStatus(ctx);
				return undefined;
			}

			const toolLabel = event.toolName;
			const disableSession = () => {
				stateFor(ctx).bypass = true;
				updateStatus(ctx);
			};

			if (event.toolName === "bash") {
				if (
					typeof event.input?.command !== "string" ||
					event.input.command.trim().length === 0
				) {
					return blockMalformedToolCall(
						pi,
						ctx,
						toolLabel,
						"malformed Pi bash tool call; missing non-empty command.",
					);
				}
				const decision = await runOrcaEvaluate(
					buildEvaluateRequest(event.input.command, ctx, "bash"),
					runtime,
				);
				return applyToolDecision(
					decision,
					pi,
					ctx,
					toolLabel,
					unavailableMode,
					disableSession,
					runtime.env,
				);
			}

			// write/edit → decide file write; read/grep/find/ls → decide file read
			if (isProtectedPiTool(event.toolName)) {
				const pathTarget = extractDecideFilePath(event.toolName, event.input);
				if (!pathTarget) return undefined;
				if (pathTarget.required && !pathTarget.path) {
					return blockMalformedToolCall(
						pi,
						ctx,
						toolLabel,
						`malformed Pi ${toolLabel} tool call; missing non-empty path.`,
					);
				}
				const absPath = resolveToolPath(pathTarget.path, ctx);
				const operation: "read" | "write" = FILE_WRITE_TOOLS.has(
					event.toolName,
				)
					? "write"
					: "read";
				const decision = await runOrcaDecideFile(
					buildDecideFilePayload(absPath, operation),
					{ ...runtime, cwd: resolveCwd(ctx.cwd) },
				);
				if (
					decision.kind === "allow" &&
					BROAD_DISCOVERY_TOOLS.has(event.toolName)
				) {
					return handlePolicyAsk(
						`Orca allowed the ${toolLabel} root, but this broad discovery action may traverse descendant files that were not individually evaluated. Explicit approval is required.`,
						pi,
						ctx,
						toolLabel,
						{ disableSession },
						allowOnceBypassEnabled(runtime.env, unavailableMode),
					);
				}
				return applyToolDecision(
					decision,
					pi,
					ctx,
					toolLabel,
					unavailableMode,
					disableSession,
					runtime.env,
				);
			}

			// Custom / MCP-shaped tools → name-gated decide tool (not full MCP proxy).
			const name = (event.toolName ?? "").trim();
			if (!name) {
				return blockMalformedToolCall(
					pi,
					ctx,
					"tool",
					"malformed Pi tool call; missing non-empty tool name.",
				);
			}
			const decision = await runOrcaDecideTool(
				buildDecideToolPayload({ name }),
				{ ...runtime, cwd: resolveCwd(ctx.cwd) },
			);
			return applyToolDecision(
				decision,
				pi,
				ctx,
				toolLabel,
				unavailableMode,
				disableSession,
				runtime.env,
			);
		},
	);

	const setupHandler = async (
		_args: string | undefined,
		ctx: PiContext,
	): Promise<void> => {
		const result = await setupOrca(ctx, runtime);
		stateFor(ctx).status = result.status;
		updateStatus(ctx);
		notify(
			ctx,
			result.message,
			result.status === "ready"
				? "info"
				: result.status === "missing"
					? "error"
					: "warning",
		);
	};

	const startHandler = async (_args: string | undefined, ctx: PiContext) => {
		stateFor(ctx).bypass = false;
		const result = await setupOrca(ctx, runtime);
		stateFor(ctx).status = result.status;
		updateStatus(ctx);
		const suffix =
			result.status === "ready"
				? "ryk protection is enabled for this Pi session."
				: result.message;
		const type =
			result.status === "ready"
				? "info"
				: result.status === "missing"
					? "error"
					: "warning";
		notify(ctx, suffix, type);
	};

	const stopHandler = (_args: string | undefined, ctx: PiContext) => {
		stateFor(ctx).bypass = true;
		updateStatus(ctx);
		notify(
			ctx,
			`ryk disabled for this Pi session only. Protected tools (${piCoverageLabel()}) run without ryk until /ryk-start (or /orca-start).`,
			"warning",
		);
	};

	const doctorHandler = async (_args: string | undefined, ctx: PiContext) => {
		const result = await runOrcaCommand(["doctor"], runtime);
		if (result.error) {
			notify(
				ctx,
				`${orcaInstallMessage()}\n\nCoverage: ${piCoverageLabel()}`,
				"error",
			);
			return;
		}
		const body =
			summarizeCommandOutput(result) ||
			`ryk doctor exited with ${result.code ?? "unknown"}`;
		notify(
			ctx,
			`${body}\n\nCoverage: ${piCoverageLabel()}`,
			result.code === 0 ? "info" : "warning",
		);
	};

	// Primary slash names are /ryk-*; /orca-* kept as aliases for one major.
	for (const name of ["ryk-setup", "orca-setup"] as const) {
		pi.registerCommand(name, {
			description:
				"Ensure the workspace policy exists and probe ryk CLI health.",
			handler: setupHandler,
		});
	}
	for (const name of ["ryk-start", "orca-start"] as const) {
		pi.registerCommand(name, {
			description:
				"Re-enable ryk protection for this Pi session and verify setup.",
			handler: startHandler,
		});
	}
	for (const name of ["ryk-stop", "orca-stop"] as const) {
		pi.registerCommand(name, {
			description:
				"Disable ryk protection for this Pi session until /ryk-start.",
			handler: stopHandler,
		});
	}
	for (const name of ["ryk-doctor", "orca-doctor"] as const) {
		pi.registerCommand(name, {
			description: "Run ryk doctor and show setup or health diagnostics.",
			handler: doctorHandler,
		});
	}

	const modeHandler = async (args: string | undefined, ctx: PiContext) => {
		const requested = args?.trim().toLowerCase();
		if (!requested) {
			notify(ctx, modeSummary(unavailableMode, stateFor(ctx).bypass), "info");
			return;
		}

		if (requested === "bypass on") {
			stateFor(ctx).bypass = true;
			updateStatus(ctx);
			notify(ctx, "ryk bypass enabled for this Pi session only.", "warning");
			return;
		}
		if (requested === "bypass off") {
			stateFor(ctx).bypass = false;
			updateStatus(ctx);
			notify(
				ctx,
				`ryk bypass disabled. Protected tools (${piCoverageLabel()}) will be evaluated by ryk.`,
				"info",
			);
			return;
		}

		const nextMode = parseMode(requested);
		if (!nextMode) {
			notify(
				ctx,
				"Usage: /ryk-mode (or /orca-mode) [auto|ask|noninteractive-block|strict|allow-with-warning|bypass on|bypass off]",
				"warning",
			);
			return;
		}
		unavailableMode = nextMode;
		updateStatus(ctx);
		notify(ctx, modeSummary(unavailableMode, stateFor(ctx).bypass), "info");
	};

	for (const name of ["ryk-mode", "orca-mode"] as const) {
		pi.registerCommand(name, {
			description: "View or change ryk Pi unavailable-mode and session bypass.",
			handler: modeHandler,
		});
	}
}

async function applyToolDecision(
	decision: OrcaDecision,
	pi: PiAPI,
	ctx: PiContext,
	toolLabel: string,
	unavailableMode: UnavailableMode,
	disableSession: () => void,
	env: NodeJS.ProcessEnv = process.env,
): Promise<ToolCallResult> {
	if (decision.kind === "allow") {
		clearOrcaWidget(ctx);
		return undefined;
	}
	if (decision.kind === "deny") {
		const card = buildOrcaDecisionCard(decision.response, "block");
		showOrcaDecision(pi, ctx, card);
		return block(formatOrcaDecisionSummary(card, toolLabel));
	}
	if (decision.kind === "warn") {
		clearOrcaWidget(ctx);
		notify(
			ctx,
			`Orca flagged this ${toolLabel} action: ${decision.reason}. Proceeding with warning.`,
			"warning",
		);
		return undefined;
	}
	if (decision.kind === "ask") {
		return handlePolicyAsk(
			decision.reason,
			pi,
			ctx,
			toolLabel,
			{ disableSession },
			allowOnceBypassEnabled(env, unavailableMode),
		);
	}
	return handleUnavailable(
		decision.reason,
		pi,
		ctx,
		resolveUnavailableMode(unavailableMode, ctx),
		{ disableSession },
		toolLabel,
		allowOnceBypassEnabled(env, unavailableMode),
	);
}

function recordOnceBypass(
	pi: PiAPI,
	ctx: PiContext,
	toolLabel: string,
	source: "policy" | "unavailable",
): boolean {
	if (!pi.sendMessage) {
		notify(ctx, "Orca blocked the once-bypass because transcript auditing is unavailable.", "error");
		return false;
	}
	const details = {
		event: "orca_once_bypass",
		tool: truncate(sanitizeVisibleText(toolLabel), 128),
		source,
	};
	try {
		pi.sendMessage(
			{
				customType: "orca.audit",
				content: `orca once-bypass: ${details.tool} (${source})`,
				display: false,
				details,
			},
			{ triggerTurn: false },
		);
	} catch {
		notify(ctx, "Orca blocked the once-bypass because transcript auditing failed.", "error");
		return false;
	}
	notify(ctx, `Orca audit: once-bypass used for ${details.tool} (${source}).`, "warning");
	return true;
}

async function handlePolicyAsk(
	reason: string,
	pi: PiAPI,
	ctx: PiContext,
	toolLabel: string,
	actions: { disableSession: () => void },
	allowOnce: boolean,
): Promise<ToolCallResult> {
	const summary = sanitizeVisibleText(reason);
	const card = buildOrcaAskCard(summary);
	showOrcaWidget(ctx, card);
	const choice = await ctx.ui?.select?.(
		"ORCA needs your decision",
		askOptionsFor("policy", allowOnce),
		{ timeout: 60_000, signal: ctx.signal },
	);
	switch (choice) {
		case "Run once anyway":
			if (!allowOnce) {
				clearOrcaWidget(ctx);
				return block(
					formatOrcaDecisionSummary(
						{
							variant: "block",
							title: "ORCA BLOCKED",
							summary,
						},
						toolLabel,
					),
				);
			}
			clearOrcaWidget(ctx);
			if (!recordOnceBypass(pi, ctx, toolLabel, "policy")) {
				return block("Orca blocked this once-bypass because a required transcript audit event could not be recorded.");
			}
			notify(
				ctx,
				`Allowed this ${toolLabel} action once without Orca evaluation.`,
				"warning",
			);
			return undefined;
		case "Disable Orca for this Pi session":
			clearOrcaWidget(ctx);
			actions.disableSession();
			notify(
				ctx,
				"Orca disabled for this Pi session only. Use /orca-start to re-enable.",
				"warning",
			);
			return undefined;
		case "Show policy reason":
			clearOrcaWidget(ctx);
			notify(ctx, summary, "error");
			return block(
				formatOrcaDecisionSummary(
					{
						variant: "block",
						title: "ORCA BLOCKED",
						summary,
					},
					toolLabel,
				),
			);
		case "Block":
		default:
			clearOrcaWidget(ctx);
			return block(
				formatOrcaDecisionSummary(
					{
						variant: "block",
						title: "ORCA BLOCKED",
						summary,
					},
					toolLabel,
				),
			);
	}
}

async function handleUnavailable(
	reason: string,
	pi: PiAPI,
	ctx: PiContext,
	mode: EffectiveUnavailableMode,
	actions: { disableSession: () => void },
	toolLabel = "bash",
	allowOnce = true,
): Promise<ToolCallResult> {
	const repair = repairMessage(reason, toolLabel);
	if (mode === "allow-with-warning") {
		clearOrcaWidget(ctx);
		notify(
			ctx,
			`Orca unavailable; allowing ${toolLabel} with warning.\n\n${repair}`,
			"warning",
		);
		return undefined;
	}
	if (mode === "strict" || mode === "noninteractive-block") {
		const card = {
			variant: "block" as const,
			title: "ORCA BLOCKED",
			summary: repair,
		};
		showOrcaDecision(pi, ctx, card);
		return block(formatOrcaDecisionSummary(card, toolLabel));
	}

	const card = buildOrcaAskCard(repair);
	// Pi queues transcript messages during an active tool turn, so the temporary
	// widget keeps ask context readable until the blocking select() resolves.
	showOrcaWidget(ctx, card);
	const choice = await ctx.ui?.select?.(
		"ORCA needs your decision",
		askOptionsFor("unavailable", allowOnce),
		{ timeout: 60_000, signal: ctx.signal },
	);
	switch (choice) {
		case "Run once anyway":
			if (!allowOnce) {
				clearOrcaWidget(ctx);
				return block(
					formatOrcaDecisionSummary(
						{
							variant: "block",
							title: "ORCA BLOCKED",
							summary: repair,
						},
						toolLabel,
					),
				);
			}
			clearOrcaWidget(ctx);
			if (!recordOnceBypass(pi, ctx, toolLabel, "unavailable")) {
				return block("Orca blocked this once-bypass because a required transcript audit event could not be recorded.");
			}
			notify(
				ctx,
				`Allowed this ${toolLabel} action once without Orca evaluation.`,
				"warning",
			);
			return undefined;
		case "Disable Orca for this Pi session":
			clearOrcaWidget(ctx);
			actions.disableSession();
			notify(
				ctx,
				"Orca disabled for this Pi session only. Use /orca-start to re-enable.",
				"warning",
			);
			return undefined;
		case "Show repair instructions / run doctor":
			clearOrcaWidget(ctx);
			notify(ctx, repair, "error");
			return block(
				formatOrcaDecisionSummary(
					{
						variant: "block",
						title: "ORCA BLOCKED",
						summary: repair,
					},
					toolLabel,
				),
			);
		case "Block":
		default:
			clearOrcaWidget(ctx);
			return block(
				formatOrcaDecisionSummary(
					{
						variant: "block",
						title: "ORCA BLOCKED",
						summary: repair,
					},
					toolLabel,
				),
			);
	}
}

async function setupOrca(
	ctx: PiContext,
	runtime: Required<
		Pick<OrcaExtensionOptions, "orcaBin" | "spawn" | "timeoutMs">
	> & { env?: NodeJS.ProcessEnv },
): Promise<SetupResult> {
	const cwd = resolveCwd(ctx.cwd);
	const policyPath = resolve(cwd, ".orca", "policy.yaml");
	if (!existsSync(policyPath)) {
		const init = await runOrcaCommand(
			["init", "--preset", "generic-agent"],
			runtime,
			cwd,
		);
		if (init.error) return { status: "missing", message: orcaInstallMessage() };
		if (init.code !== 0 || !existsSync(policyPath)) {
			return {
				status: "degraded",
				message: `Orca policy setup failed (exit ${init.code ?? "unknown"}). ${summarizeCommandOutput(init)}`,
			};
		}
	}

	const doctor = await runOrcaCommand(["doctor"], runtime, cwd);
	if (doctor.error) return { status: "missing", message: orcaInstallMessage() };
	if (doctor.code !== 0) {
		return {
			status: "degraded",
			message: `Orca policy is ready, but the health probe exited with ${doctor.code ?? "unknown"}. ${summarizeCommandOutput(doctor)}`,
		};
	}
	return {
		status: "ready",
		message: "Orca policy is ready and daemon health checks passed.",
	};
}

function runProcess(
	file: string,
	args: string[],
	stdin: string | undefined,
	spawn: SpawnLike,
	timeoutMs: number,
	env?: NodeJS.ProcessEnv,
	cwd?: string,
): Promise<RunProcessResult> {
	return new Promise((resolvePromise) => {
		const controller = new AbortController();
		let stdout = "";
		let stderr = "";
		let settled = false;
		let timedOut = false;
		let outputExceeded = false;
		const timer = setTimeout(() => {
			timedOut = true;
			controller.abort();
		}, timeoutMs);

		const settle = (result: RunProcessResult): void => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolvePromise({ ...result, stdout, stderr, timedOut });
		};

		let child: ChildLike;
		try {
			child = spawn(file, args, {
				stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"],
				shell: false,
				signal: controller.signal,
				env,
				cwd,
			});
		} catch (error) {
			settle({ code: null, stdout, stderr, error: asError(error), timedOut });
			return;
		}

		child.stdout?.on("data", (chunk) => {
			const appended = appendBounded(
				stdout,
				String(chunk),
				MAX_CHILD_OUTPUT_BYTES,
			);
			stdout = appended.text;
			if (appended.exceeded && !outputExceeded) {
				outputExceeded = true;
				settle({
					code: null,
					stdout,
					stderr,
					error: new Error("Orca output exceeded maximum size"),
					timedOut,
				});
				controller.abort();
			}
		});
		child.stderr?.on("data", (chunk) => {
			const appended = appendBounded(
				stderr,
				String(chunk),
				MAX_CHILD_OUTPUT_BYTES,
			);
			stderr = appended.text;
			if (appended.exceeded && !outputExceeded) {
				outputExceeded = true;
				settle({
					code: null,
					stdout,
					stderr,
					error: new Error("Orca output exceeded maximum size"),
					timedOut,
				});
				controller.abort();
			}
		});
		child.on("error", (errorOrCode: Error | number | null) => {
			settle({
				code: null,
				stdout,
				stderr,
				error: asError(errorOrCode),
				timedOut,
			});
		});
		child.on("close", (codeOrError: Error | number | null) => {
			settle({
				code: typeof codeOrError === "number" ? codeOrError : null,
				stdout,
				stderr,
				timedOut,
			});
		});

		if (stdin !== undefined) {
			child.stdin?.write(stdin);
			child.stdin?.end();
		}
	});
}

function sessionKey(ctx: PiContext): string {
	try {
		const id = ctx.sessionManager?.getSessionId?.();
		if (id) return id;
	} catch {
		// Fall through to the local test fallback.
	}
	return "__default_session__";
}

function resolveBundledPackageRoot(): string | undefined {
	try {
		const require = createRequire(import.meta.url);
		return dirname(require.resolve("@orca-sec/orca/package.json"));
	} catch {
		return undefined;
	}
}

function isExecutableFile(path: string): boolean {
	try {
		accessSync(
			path,
			process.platform === "win32" ? constants.F_OK : constants.X_OK,
		);
		return true;
	} catch {
		return false;
	}
}

/** Prefer ryk on PATH, fall back to orca; version line may say either product name. */
function resolveCompatiblePathCli(
	env: NodeJS.ProcessEnv,
	runner: SpawnSyncLike,
): string | null {
	const versionRe = new RegExp(
		`\\b(?:ryk|orca)\\s+${REQUIRED_ORCA_VERSION.replaceAll(".", "\\.")}\\b`,
	);
	for (const name of ["ryk", "orca"] as const) {
		const result = runner(name, ["--version"], {
			encoding: "utf8",
			env,
			shell: false,
			timeout: 2_000,
		});
		if (result.error || result.status !== 0) continue;
		if (versionRe.test(result.stdout ?? "")) return name;
	}
	return null;
}

function isCompatiblePathOrca(
	env: NodeJS.ProcessEnv,
	runner: SpawnSyncLike,
): boolean {
	return resolveCompatiblePathCli(env, runner) !== null;
}

function appendBounded(
	current: string,
	chunk: string,
	maxBytes: number,
): { text: string; exceeded: boolean } {
	const currentBytes = Buffer.byteLength(current);
	const chunkBytes = Buffer.byteLength(chunk);
	if (currentBytes + chunkBytes <= maxBytes)
		return { text: current + chunk, exceeded: false };
	const remaining = Math.max(0, maxBytes - currentBytes);
	return { text: current + chunk.slice(0, remaining), exceeded: true };
}

function resolveCwd(cwd: string | undefined): string {
	const candidate = cwd ? resolve(cwd) : process.cwd();
	return existsSync(candidate) ? candidate : process.cwd();
}

function block(reason: string): ToolCallBlock {
	return { block: true, reason: sanitizeVisibleText(reason) };
}

function clearOrcaWidget(ctx: PiContext): void {
	ctx.ui?.setWidget?.(BLOCK_WIDGET_KEY, undefined);
}

function showOrcaWidget(ctx: PiContext, card: OrcaDecisionCard): void {
	if (!ctx.ui?.setWidget) return;
	ctx.ui.setWidget(BLOCK_WIDGET_KEY, buildOrcaWidget(card), {
		placement: "aboveEditor",
	});
}

function showOrcaDecision(
	pi: PiAPI,
	ctx: PiContext,
	card: OrcaDecisionCard,
): void {
	clearOrcaWidget(ctx);
	if (pi.sendMessage) {
		pi.sendMessage(
			{
				customType: "orca-decision",
				content: buildOrcaWidget(card).join("\n"),
				display: true,
				details: card,
			},
			{ triggerTurn: false },
		);
		return;
	}

	// Older Pi hosts cannot append transcript messages. Keep their docked fallback
	// isolated here; supported hosts always use the conversation surface above.
	showOrcaWidget(ctx, card);
}

function buildOrcaWidget(card: OrcaDecisionCard): string[] {
	const contentWidth = 54;
	const isBlock = card.variant === "block";
	const frame = isBlock
		? { topLeft: "┏", topRight: "┓", side: "┃", teeLeft: "┣", teeRight: "┫", bottomLeft: "┗", bottomRight: "┛", rule: "━" }
		: { topLeft: "┌", topRight: "┐", side: "│", teeLeft: "├", teeRight: "┤", bottomLeft: "└", bottomRight: "┘", rule: "─" };
	const masthead = isBlock ? " ORCA // BLOCKED " : " ORCA // YOUR CALL ";
	const stateLine = isBlock
		? "COMMAND STOPPED BEFORE EXECUTION"
		: "ORCA PAUSED THIS COMMAND";
	const lines = [
		buildLabeledBorder(frame.topLeft, frame.topRight, frame.rule, masthead, contentWidth),
		`${frame.side} ${stateLine.padEnd(contentWidth - 2)} ${frame.side}`,
		`${frame.teeLeft}${frame.rule.repeat(contentWidth)}${frame.teeRight}`,
	];
	lines.push(...formatWidgetRow("Why", card.summary, contentWidth, frame.side));
	lines.push(`${frame.teeLeft}${frame.rule.repeat(contentWidth)}${frame.teeRight}`);
	lines.push(...formatWidgetRow("Rule", card.rule, contentWidth, frame.side));
	if (card.pack)
		lines.push(...formatWidgetRow("Pack", card.pack, contentWidth, frame.side));
	if (card.severity)
		lines.push(
			...formatWidgetRow(
				"Severity",
				capitalize(card.severity),
				contentWidth,
				frame.side,
			),
		);
	if (card.nextStep)
		lines.push(
			...formatWidgetRow("Next", card.nextStep, contentWidth, frame.side),
		);
	if (!isBlock)
		lines.push(
			...formatWidgetRow(
				"Choose",
				"Run once, repair Orca, or keep it blocked.",
				contentWidth,
				frame.side,
			),
		);
	lines.push(
		`${frame.bottomLeft}${frame.rule.repeat(contentWidth)}${frame.bottomRight}`,
	);
	return lines;
}

function buildLabeledBorder(
	left: string,
	right: string,
	rule: string,
	label: string,
	width: number,
): string {
	const remaining = Math.max(0, width - label.length);
	const before = Math.min(3, remaining);
	return `${left}${rule.repeat(before)}${label}${rule.repeat(remaining - before)}${right}`;
}

function buildOrcaDecisionCard(
	response: unknown,
	variant: OrcaDecisionCard["variant"],
): OrcaDecisionCard {
	const reason = getDecisionReason(response);
	const rule = getRuleId(response);
	const pack = getStringFieldAny(response, ["pack_id", "packId"]);
	const severity = getStringFieldAny(response, ["severity"]);
	const nextStep = getNextStep(response);
	return {
		variant,
		title: variant === "ask" ? "ORCA NEEDS YOUR DECISION" : "ORCA BLOCKED",
		summary: sanitizeVisibleText(reason),
		rule,
		pack,
		severity,
		nextStep,
	};
}

function buildOrcaAskCard(reason: string): OrcaDecisionCard {
	return {
		variant: "ask",
		title: "ORCA NEEDS YOUR DECISION",
		summary: sanitizeVisibleText(reason),
	};
}

function formatOrcaDecisionSummary(
	card: OrcaDecisionCard,
	toolLabel = "bash",
): string {
	const parts = [card.summary];
	if (card.rule) parts.push(`rule ${card.rule}`);
	if (card.pack && card.pack !== card.rule?.split(":")[0]) parts.push(`pack ${card.pack}`);
	if (card.severity) parts.push(`severity ${card.severity}`);
	const action =
		toolLabel === "bash" ? "bash command" : `${toolLabel} action`;
	return sanitizeVisibleText(
		`Orca ${card.variant === "ask" ? "needs your decision" : `blocked this ${action}`}: ${parts.join(" • ")}`,
	);
}

function getDecisionReason(response: unknown): string {
	return (
		getStringFieldAny(response, ["reason", "message"]) ??
		getNestedStringField(response, ["error", "message"]) ??
		"Orca blocked this action."
	);
}

function getRuleId(response: unknown): string | undefined {
	// Evaluate uses rule_id; decide file uses `rule`. normalizeDecideToEvaluateShape
	// maps rule → rule_id, but accept both so cards stay robust.
	return getStringFieldAny(response, ["rule_id", "ruleId", "rule"]);
}

function getNextStep(response: unknown): string | undefined {
	const remediation = Array.isArray((response as OrcaEvaluateResponse | null)?.remediation)
		? (response as OrcaEvaluateResponse).remediation
		: undefined;
	const description = remediation?.find((entry) => entry?.description)?.description;
	return description ? sanitizeVisibleText(description) : undefined;
}

function getStringFieldAny(
	value: unknown,
	keys: string[],
): string | undefined {
	for (const key of keys) {
		const field = getStringField(value, key);
		if (field) return field;
	}
	return undefined;
}

function capitalize(value: string): string {
	return value.charAt(0).toUpperCase() + value.slice(1);
}

function wrapText(value: string, width: number): string[] {
	const text = sanitizeVisibleText(value);
	if (!text) return [""];
	const words = text.split(/\s+/);
	const lines: string[] = [];
	let current = "";
	for (const word of words) {
		if (!current) {
			current = word;
			continue;
		}
		if (`${current} ${word}`.length <= width) {
			current = `${current} ${word}`;
			continue;
		}
		lines.push(current);
		current = word;
	}
	if (current) lines.push(current);
	return lines.flatMap((line) => {
		if (line.length <= width) return [line];
		const chunks: string[] = [];
		for (let i = 0; i < line.length; i += width) chunks.push(line.slice(i, i + width));
		return chunks;
	});
}

function formatWidgetRow(
	label: string,
	value: string | undefined,
	width: number,
	side: string,
): string[] {
	if (!value) return [];
	const contentWidth = width - 2;
	const rowLabel = `${label}:`;
	const available = Math.max(1, contentWidth - rowLabel.length - 1);
	const wrapped = wrapText(value, available);
	return wrapped.map((line, index) => {
		const prefix = index === 0 ? rowLabel : "".padEnd(rowLabel.length, " ");
		return `${side} ${prefix} ${line.padEnd(available)} ${side}`;
	});
}

function notify(
	ctx: PiContext,
	message: string,
	type: "info" | "warning" | "error",
): void {
	ctx.ui?.notify?.(truncate(sanitizeVisibleText(message), 2_000), type);
}

function repairMessage(reason: string, toolLabel = "bash"): string {
	return `Orca could not evaluate this ${toolLabel} action: ${sanitizeVisibleText(reason)}\n\nRun /orca-setup, then /orca-doctor. Coverage: ${piCoverageLabel()}. The daemon starts automatically on shell evaluate.`;
}

function modeSummary(mode: UnavailableMode, sessionBypass: boolean): string {
	return [
		`Orca Pi mode: ${mode}`,
		`Session bypass: ${sessionBypass ? "on" : "off"}`,
		`Coverage: ${piCoverageLabel()}`,
		`Once-bypass: ${allowOnceBypassEnabled(process.env, mode) ? "allowed" : "disabled"} (ORCA_PI_ALLOW_ONCE; strict disables by default)`,
		"Default ORCA_PI_MODE=auto (interactive ask; noninteractive block). Production: prefer strict. allow-with-warning is never the default.",
		"Modes: auto, ask, noninteractive-block, strict, allow-with-warning.",
		"Process-level env/network/secretless requires: orca run [--secretless] [--network …] -- pi …",
	].join("\n");
}

function orcaInstallMessage(): string {
	return "ryk CLI was not found. Reinstall npm:@orca-sec/pi-orca (or @orca-sec/ryk), set RYK_BIN/ORCA_BIN to an executable path, then run /ryk-setup (or /orca-setup).";
}

function summarizeCommandOutput(result: RunProcessResult): string {
	const output = result.stdout.trim() || result.stderr.trim();
	return truncate(sanitizeVisibleText(output), 2_000);
}

function parseMode(value: string | undefined): UnavailableMode | undefined {
	if (
		value === "auto" ||
		value === "ask" ||
		value === "noninteractive-block" ||
		value === "strict" ||
		value === "allow-with-warning"
	) {
		return value;
	}
	return undefined;
}

function sanitizeVisibleText(value: string): string {
	return value
		.replace(/\bsk-ant-[A-Za-z0-9_-]{20,}\b/g, "[redacted-token]")
		.replace(/\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b/g, "[redacted-token]")
		.replace(
			/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g,
			"[redacted-token]",
		)
		.replace(/[A-Za-z0-9_]*gh[pousr]_[A-Za-z0-9_]+/g, "[redacted-token]")
		.replace(/(password|token|secret|api[_-]?key)=\S+/gi, "$1=[redacted]")
		.replace(/\s+/g, " ")
		.trim();
}

function truncate(value: string, max: number): string {
	if (value.length <= max) return value;
	return `${value.slice(0, max - 3)}...`;
}

function getStringField(value: unknown, key: string): string | undefined {
	if (!value || typeof value !== "object") return undefined;
	const field = (value as Record<string, unknown>)[key];
	return typeof field === "string" ? field : undefined;
}

function getNestedStringField(
	value: unknown,
	path: string[],
): string | undefined {
	let current = value;
	for (const segment of path) {
		if (!current || typeof current !== "object") return undefined;
		current = (current as Record<string, unknown>)[segment];
	}
	return typeof current === "string" ? current : undefined;
}

function asError(value: unknown): Error {
	return value instanceof Error ? value : new Error(String(value));
}

export default function orcaPiExtension(pi: PiAPI): void {
	installOrcaExtension(pi);
}
