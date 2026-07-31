/**
 * Pi-only credential capture from prompt text.
 *
 * Pi host notes (extensions.md):
 * - `input` receives raw text; return { action: "transform", text } to rewrite
 *   before skill/template expansion and the agent turn, or { action: "handled" }
 *   to skip the LLM entirely. Skip when event.source === "extension".
 * - `context` can scrub messages[] before each LLM call (defense in depth).
 * - Session transcript may still retain pre-transform history already on disk;
 *   this module does not rewrite prior turns on disk.
 * - Capture requires interactive UI (ctx.hasUI + not print/json/noninteractive).
 * - Even with session bash bypass (/ryk-stop), secrets are still scrubbed/blocked.
 *
 * Storage: append/update NAME=value under workspace `.ryk/dev-secrets.env`
 * (matches the legacy env-file-dev broker path contract: under .ryk, contains "dev", ends with .env).
 */

import {
	closeSync,
	constants,
	existsSync,
	fchmodSync,
	fsyncSync,
	lstatSync,
	mkdirSync,
	openSync,
	readFileSync,
	realpathSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import {
	dirname,
	relative as pathRelative,
	resolve,
	sep,
} from "node:path";

export type SecretKind =
	| "openai"
	| "anthropic"
	| "github"
	| "assignment"
	| "generic";

export type SecretMatch = {
	kind: SecretKind;
	value: string;
	start: number;
	end: number;
	/** When kind is assignment, the left-hand name if secret-like. */
	envNameHint?: string;
};

export type SecretCaptureInputEvent = {
	text: string;
	source?: string;
	images?: unknown;
};

export type SecretCaptureContext = {
	ui?: {
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
	};
	cwd?: string;
	mode?: string;
	hasUI?: boolean;
	signal?: AbortSignal;
};

export type InputActionResult =
	| { action: "continue" }
	| { action: "transform"; text: string }
	| { action: "handled" };

export type StoreSecretFn = (
	cwd: string,
	name: string,
	value: string,
) => void | Promise<void>;

export type SecretCaptureOptions = {
	/** When true, skip capture entirely (RYK_PI_SECRET_CAPTURE=false). */
	disabled?: boolean;
	storeSecret?: StoreSecretFn;
	envFileRelativePath?: string;
};

const DEFAULT_ENV_FILE = ".ryk/dev-secrets.env";
const CAPTURE_TIMEOUT_MS = 60_000;

const SECRET_NAME_RE =
	/(TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE|API[_-]?KEY|ACCESS[_-]?KEY)/i;

/**
 * Detect secret-like spans in free text. Pure, side-effect free.
 * Only synthetic-safe patterns; conservative on high-entropy to limit FPs.
 */
export function detectSecrets(text: string): SecretMatch[] {
	if (!text) return [];

	const found: SecretMatch[] = [];

	// More specific patterns first; overlaps are resolved later.
	collectRegex(
		text,
		/\bsk-ant-[A-Za-z0-9_-]{20,}\b/g,
		"anthropic",
		found,
	);
	collectRegex(
		text,
		/\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b/g,
		"openai",
		found,
	);
	collectRegex(
		text,
		/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g,
		"github",
		found,
	);

	const assignmentRe =
		/\b([A-Za-z_][A-Za-z0-9_]{1,127})\s*=\s*(["']?)([^\s"'=]{8,})\2/g;
	let m: RegExpExecArray | null;
	while ((m = assignmentRe.exec(text)) !== null) {
		const name = m[1];
		const value = m[3];
		if (!isSecretLikeEnvName(name) && !looksLikeKnownSecretToken(value)) {
			continue;
		}
		// Prefer covering the whole NAME=value span when name is secret-like.
		const fullStart = m.index;
		const fullEnd = m.index + m[0].length;
		const valueStart = text.indexOf(value, fullStart);
		if (isSecretLikeEnvName(name)) {
			found.push({
				kind: "assignment",
				value,
				start: fullStart,
				end: fullEnd,
				envNameHint: name.toUpperCase(),
			});
		} else if (valueStart >= 0) {
			// Value is a known token pattern inside a non-secret-named assignment;
			// token regex above usually catches it; skip if already covered.
			if (!rangeCovered(found, valueStart, valueStart + value.length)) {
				found.push({
					kind: classifyTokenKind(value),
					value,
					start: valueStart,
					end: valueStart + value.length,
				});
			}
		}
	}

	return dedupeOverlaps(found);
}

/**
 * Replace secret spans with $ENV_NAME references and append short guidance.
 * Processes matches from the end so indices stay valid.
 */
export function scrubSecrets(
	text: string,
	matches: SecretMatch[],
	replacementGuide?: string | Record<string, string> | Map<string, string>,
): string {
	if (!matches.length) return text;

	const nameFor = (match: SecretMatch, index: number): string => {
		if (typeof replacementGuide === "string") {
			// Single global guide string used as shared env name when one match.
			if (matches.length === 1) return replacementGuide;
		} else if (replacementGuide instanceof Map) {
			const byValue = replacementGuide.get(match.value);
			if (byValue) return byValue;
		} else if (replacementGuide && typeof replacementGuide === "object") {
			const byValue = replacementGuide[match.value];
			if (byValue) return byValue;
		}
		return inferEnvName(match, index);
	};

	const ordered = [...matches].sort((a, b) => b.start - a.start);
	const usedNames: string[] = [];
	let result = text;

	for (let i = 0; i < ordered.length; i++) {
		const match = ordered[i];
		// Map descending order back to stable name assignment by original index.
		const originalIndex = matches.indexOf(match);
		const name = nameFor(match, originalIndex >= 0 ? originalIndex : i);
		usedNames.push(name);
		const replacement =
			match.kind === "assignment"
				? `${name}=$${name}`
				: `$${name}`;
		result =
			result.slice(0, match.start) + replacement + result.slice(match.end);
	}

	const uniqueNames = [...new Set(usedNames.reverse())];
	const guide = buildReplacementGuide(uniqueNames);
	if (!result.includes("[ryk]")) {
		result = `${result.trimEnd()}\n\n${guide}`;
	}
	return result;
}

export function inferEnvName(match: SecretMatch, index = 0): string {
	if (match.envNameHint && isValidEnvName(match.envNameHint)) {
		return match.envNameHint;
	}
	const base = baseNameForKind(match.kind, match.value);
	if (index === 0) return base;
	return `${base}_${index + 1}`;
}

export function isSecretCaptureDisabled(
	env: NodeJS.ProcessEnv = process.env,
): boolean {
	const raw = (env.RYK_PI_SECRET_CAPTURE ?? env.RYK_PI_SECRET_CAPTURE)
		?.trim()
		.toLowerCase();
	return raw === "false" || raw === "0" || raw === "off" || raw === "no";
}

export function isInteractiveCaptureSession(ctx: {
	hasUI?: boolean;
	mode?: string;
}): boolean {
	if (ctx.hasUI !== true) return false;
	const mode = ctx.mode;
	return mode !== "print" && mode !== "json" && mode !== "noninteractive";
}

/**
 * Persist a secret into workspace `.ryk/dev-secrets.env` (or override path).
 * Never logs the value. Sets process.env[name] for the current Node process only.
 */
export function storeSecretToEnvFile(
	cwd: string,
	name: string,
	value: string,
	envFileRelativePath: string = DEFAULT_ENV_FILE,
): void {
	storeSecretToEnvFileImpl(cwd, name, value, envFileRelativePath);
}

type StoreSecretTestHooks = {
	beforeTempOpen?: () => void;
	beforeRename?: () => void;
};

/** Deterministic filesystem-race injection for adversarial tests only. */
export function _storeSecretToEnvFileWithHooksForTest(
	cwd: string,
	name: string,
	value: string,
	envFileRelativePath: string,
	hooks: StoreSecretTestHooks,
): void {
	storeSecretToEnvFileImpl(cwd, name, value, envFileRelativePath, hooks);
}

function storeSecretToEnvFileImpl(
	cwd: string,
	name: string,
	value: string,
	envFileRelativePath: string,
	hooks: StoreSecretTestHooks = {},
): void {
	if (!isValidEnvName(name)) {
		throw new Error("Invalid credential environment variable name.");
	}
	if (!value || value.includes("\n") || value.includes("\r")) {
		throw new Error("Invalid credential value.");
	}

	const relativePath = envFileRelativePath.replace(/\\/g, "/");
	if (
		!relativePath.startsWith(".ryk/") ||
		!relativePath.includes("dev") ||
		!relativePath.endsWith(".env") ||
		relativePath.includes("..")
	) {
		throw new Error("Unsafe credential env file path.");
	}

	const root = resolve(cwd);
	const filePath = resolve(root, relativePath);
	const escaped = pathRelative(root, filePath);
	if (
		escaped === "" ||
		escaped.startsWith("..") ||
		escaped.includes("..")
	) {
		throw new Error("Credential path escaped workspace.");
	}

	const dir = dirname(filePath);
	ensureSafeDirectoryChain(root, dir);
	const directoryIdentity = captureDirectoryIdentity(root, dir);

	let existing = "";
	if (existsSync(filePath)) {
		rejectSymlinkOrNonFile(filePath);
		existing = readFileSync(filePath, "utf8");
	}

	const line = `${name}=${value}`;
	const lines = existing.length ? existing.split(/\r?\n/) : [];
	let replaced = false;
	const nextLines = lines.map((entry) => {
		if (!entry || entry.trimStart().startsWith("#")) return entry;
		const eq = entry.indexOf("=");
		if (eq <= 0) return entry;
		const key = entry.slice(0, eq).trim();
		if (key === name) {
			replaced = true;
			return line;
		}
		return entry;
	});
	if (!replaced) {
		if (nextLines.length && nextLines[nextLines.length - 1] === "") {
			nextLines[nextLines.length - 1] = line;
			nextLines.push("");
		} else {
			nextLines.push(line);
		}
	}

	const body = nextLines.join("\n");
	const ended = body.endsWith("\n") ? body : `${body}\n`;
	// Write beside the destination and atomically rename only after fsync. This
	// prevents truncated credential files on interruption and never follows a
	// destination symlink.
	const tempPath = resolve(dir, `.ryk-secrets-${process.pid}-${randomUUID()}.tmp`);
	let fd: number | undefined;
	try {
		hooks.beforeTempOpen?.();
		validateDirectoryIdentity(directoryIdentity);
		fd = openSync(
			tempPath,
			constants.O_WRONLY |
				constants.O_CREAT |
				constants.O_EXCL |
				constants.O_NOFOLLOW,
			0o600,
		);
		fchmodSync(fd, 0o600);
		writeFileSync(fd, ended, { encoding: "utf8" });
		fsyncSync(fd);
		closeSync(fd);
		fd = undefined;
		hooks.beforeRename?.();
		validateDirectoryIdentity(directoryIdentity);
		if (existsSync(filePath)) rejectSymlinkOrNonFile(filePath);
		renameSync(tempPath, filePath);
	} catch (error) {
		if (fd !== undefined) {
			try {
				closeSync(fd);
			} catch {
				// Preserve the original storage error.
			}
		}
		// Delete by pathname only while it still resolves to the directory that
		// created the temp file. On a detected swap, fail closed and avoid
		// deleting an attacker-selected path.
		try {
			validateDirectoryIdentity(directoryIdentity);
			rmSync(tempPath, { force: true });
		} catch {
			// Preserve the original storage error and never cross a swapped path.
		}
		throw error;
	}

	// Current extension process only — Pi tool child envs are not automatically updated.
	process.env[name] = value;
}

type DirectoryIdentity = {
	root: string;
	target: string;
	rootReal: string;
	targetReal: string;
	rootDevice: number;
	rootInode: number;
	targetDevice: number;
	targetInode: number;
};

function captureDirectoryIdentity(root: string, target: string): DirectoryIdentity {
	const rootStat = lstatSync(root);
	const targetStat = lstatSync(target);
	return {
		root,
		target,
		rootReal: realpathSync.native(root),
		targetReal: realpathSync.native(target),
		rootDevice: rootStat.dev,
		rootInode: rootStat.ino,
		targetDevice: targetStat.dev,
		targetInode: targetStat.ino,
	};
}

function validateDirectoryIdentity(identity: DirectoryIdentity): void {
	try {
		ensureSafeDirectoryChain(identity.root, identity.target);
		const rootStat = lstatSync(identity.root);
		const targetStat = lstatSync(identity.target);
		if (
			realpathSync.native(identity.root) !== identity.rootReal ||
			realpathSync.native(identity.target) !== identity.targetReal ||
			rootStat.dev !== identity.rootDevice ||
			rootStat.ino !== identity.rootInode ||
			targetStat.dev !== identity.targetDevice ||
			targetStat.ino !== identity.targetInode
		) {
			throw new Error("identity mismatch");
		}
	} catch {
		throw new Error("Credential directory changed during write.");
	}
}

function ensureSafeDirectoryChain(root: string, target: string): void {
	const relative = pathRelative(root, target);
	if (relative.startsWith("..") || resolve(root, relative) !== target) {
		throw new Error("Credential path escaped workspace.");
	}

	rejectSymlinkOrNonDirectory(root);
	let current = root;
	for (const component of relative.split(sep).filter(Boolean)) {
		current = resolve(current, component);
		if (!existsSync(current)) {
			mkdirSync(current, { mode: 0o700 });
		}
		rejectSymlinkOrNonDirectory(current);
	}
}

function rejectSymlinkOrNonDirectory(path: string): void {
	const stat = lstatSync(path);
	if (stat.isSymbolicLink()) {
		throw new Error("Symlinked credential path is not allowed.");
	}
	if (!stat.isDirectory()) {
		throw new Error("Credential directory path is not a directory.");
	}
}

function rejectSymlinkOrNonFile(path: string): void {
	const stat = lstatSync(path);
	if (stat.isSymbolicLink()) {
		throw new Error("Symlinked credential path is not allowed.");
	}
	if (!stat.isFile()) {
		throw new Error("Credential env path is not a regular file.");
	}
}

/**
 * Interactive consent + transform/handled for the Pi `input` event.
 */
export async function handleSecretCaptureInput(
	event: SecretCaptureInputEvent,
	ctx: SecretCaptureContext,
	options: SecretCaptureOptions = {},
): Promise<InputActionResult> {
	if (options.disabled || isSecretCaptureDisabled()) {
		return { action: "continue" };
	}
	if (event.source === "extension") {
		return { action: "continue" };
	}

	const text = event.text ?? "";
	const matches = detectSecrets(text);
	if (!matches.length) {
		return { action: "continue" };
	}

	const nameMap = assignEnvNames(matches);
	const names = [...new Set([...nameMap.values()])];
	const namesLabel = names.join(", ");

	if (!isInteractiveCaptureSession(ctx)) {
		const message =
			`ryk detected secret-like input but cannot capture credentials in noninteractive Pi mode. ` +
			`Re-run interactively to store as ${namesLabel}, or remove the secret from the prompt.`;
		// Never include raw secret values in notifications.
		ctx.ui?.notify?.(message, "error");
		return { action: "handled" };
	}

	const storeLabel =
		names.length === 1
			? `Store as ${names[0]} and remove from this message`
			: `Store as ${namesLabel} and remove from this message`;
	const optionsList = [
		storeLabel,
		"Remove secret from message without storing",
		"Block this message",
	];

	const choice = await ctx.ui?.select?.(
		"ryk credential capture",
		optionsList,
		{ timeout: CAPTURE_TIMEOUT_MS, signal: ctx.signal },
	);

	if (choice === optionsList[2] || choice === undefined) {
		ctx.ui?.notify?.(
			"Blocked message containing secret-like input. Nothing was stored.",
			"warning",
		);
		return { action: "handled" };
	}

	const shouldStore = choice === optionsList[0];
	if (shouldStore) {
		const cwd = resolve(ctx.cwd ?? process.cwd());
		const envPath = options.envFileRelativePath ?? DEFAULT_ENV_FILE;
		const store: StoreSecretFn =
			options.storeSecret ??
			((root, name, value) => storeSecretToEnvFile(root, name, value, envPath));
		try {
			// Store unique values; last write wins for duplicate names.
			const seen = new Set<string>();
			for (const match of matches) {
				const name = nameMap.get(match.value) ?? inferEnvName(match);
				const key = `${name}\0${match.value}`;
				if (seen.has(key)) continue;
				seen.add(key);
				await store(cwd, name, match.value);
			}
			ctx.ui?.notify?.(
				`Stored credential(s) as ${namesLabel} in .ryk/dev-secrets.env. Raw value removed from this message.`,
				"info",
			);
		} catch {
			ctx.ui?.notify?.(
				"Failed to store credential safely. Message blocked so the model does not receive the raw secret.",
				"error",
			);
			return { action: "handled" };
		}
	} else {
		ctx.ui?.notify?.(
			`Removed secret-like value(s) from this message. Nothing stored. Use $${names.join(" / $")} if already configured.`,
			"warning",
		);
	}

	const guide: Record<string, string> = {};
	for (const match of matches) {
		guide[match.value] = nameMap.get(match.value) ?? inferEnvName(match);
	}
	const transformed = scrubSecrets(text, matches, guide);
	// Fail closed: if scrub somehow left a raw match value, block.
	for (const match of matches) {
		if (transformed.includes(match.value)) {
			ctx.ui?.notify?.(
				"Could not safely remove secret from message. Turn blocked.",
				"error",
			);
			return { action: "handled" };
		}
	}
	return { action: "transform", text: transformed };
}

/**
 * Defense-in-depth: scrub secret patterns from message text content before LLM.
 * Does not prompt for storage (history scrub only).
 */
export function scrubContextMessages(
	messages: Array<Record<string, unknown>>,
): Array<Record<string, unknown>> {
	return messages.map((message) => scrubOneMessage(message));
}

function scrubOneMessage(
	message: Record<string, unknown>,
): Record<string, unknown> {
	if (message.role !== "user") return message;

	const content = message.content;
	if (typeof content === "string") {
		const matches = detectSecrets(content);
		if (!matches.length) return message;
		const guide = Object.fromEntries(
			matches.map((m, i) => [m.value, inferEnvName(m, i)]),
		);
		return { ...message, content: scrubSecrets(content, matches, guide) };
	}

	if (!Array.isArray(content)) return message;

	let changed = false;
	const next = content.map((part) => {
		if (!part || typeof part !== "object") return part;
		const record = part as Record<string, unknown>;
		if (record.type === "text" && typeof record.text === "string") {
			const matches = detectSecrets(record.text);
			if (!matches.length) return part;
			changed = true;
			const guide = Object.fromEntries(
				matches.map((m, i) => [m.value, inferEnvName(m, i)]),
			);
			return { ...record, text: scrubSecrets(record.text, matches, guide) };
		}
		return part;
	});
	return changed ? { ...message, content: next } : message;
}

function assignEnvNames(matches: SecretMatch[]): Map<string, string> {
	const map = new Map<string, string>();
	const used = new Set<string>();
	let index = 0;
	for (const match of matches) {
		if (map.has(match.value)) continue;
		let name = inferEnvName(match, index);
		if (used.has(name) && map.get(match.value) !== name) {
			// Distinct secrets mapping to same base name.
			let n = 2;
			while (used.has(`${name}_${n}`)) n += 1;
			name = `${name}_${n}`;
		}
		used.add(name);
		map.set(match.value, name);
		index += 1;
	}
	return map;
}

function buildReplacementGuide(names: string[]): string {
	if (names.length === 1) {
		return (
			`[ryk] Use the ${names[0]} environment variable. ` +
			`Do not print or request the raw secret.`
		);
	}
	return (
		`[ryk] Use environment variable(s) ${names.join(", ")}. ` +
		`Do not print or request the raw secret.`
	);
}

function baseNameForKind(kind: SecretKind, value: string): string {
	if (kind === "anthropic" || value.startsWith("sk-ant-")) {
		return "ANTHROPIC_API_KEY";
	}
	if (kind === "openai" || /^sk-(?!ant-)/.test(value)) {
		return "OPENAI_API_KEY";
	}
	if (
		kind === "github" ||
		/^(?:gh[pousr]_|github_pat_)/.test(value)
	) {
		return "GITHUB_TOKEN";
	}
	return "API_KEY";
}

function classifyTokenKind(value: string): SecretKind {
	if (value.startsWith("sk-ant-")) return "anthropic";
	if (value.startsWith("sk-")) return "openai";
	if (/^(?:gh[pousr]_|github_pat_)/.test(value)) return "github";
	return "generic";
}

function looksLikeKnownSecretToken(value: string): boolean {
	return (
		/^sk-ant-[A-Za-z0-9_-]{20,}$/.test(value) ||
		/^sk-(?!ant-)[A-Za-z0-9_-]{20,}$/.test(value) ||
		/^(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})$/.test(
			value,
		)
	);
}

function isSecretLikeEnvName(name: string): boolean {
	return SECRET_NAME_RE.test(name) || isKnownSecretEnvName(name);
}

function isKnownSecretEnvName(name: string): boolean {
	const upper = name.toUpperCase();
	return (
		upper === "OPENAI_API_KEY" ||
		upper === "ANTHROPIC_API_KEY" ||
		upper === "GITHUB_TOKEN" ||
		upper === "GH_TOKEN" ||
		upper === "NPM_TOKEN" ||
		upper === "AWS_SECRET_ACCESS_KEY" ||
		upper === "AWS_ACCESS_KEY_ID"
	);
}

function isValidEnvName(name: string): boolean {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && name.length <= 128;
}

function collectRegex(
	text: string,
	re: RegExp,
	kind: SecretKind,
	out: SecretMatch[],
): void {
	re.lastIndex = 0;
	let m: RegExpExecArray | null;
	while ((m = re.exec(text)) !== null) {
		out.push({
			kind,
			value: m[0],
			start: m.index,
			end: m.index + m[0].length,
		});
	}
}

function rangeCovered(
	matches: SecretMatch[],
	start: number,
	end: number,
): boolean {
	return matches.some((m) => m.start <= start && m.end >= end);
}

/**
 * Prefer longer/earlier spans when ranges overlap.
 */
function dedupeOverlaps(matches: SecretMatch[]): SecretMatch[] {
	const sorted = [...matches].sort((a, b) => {
		if (a.start !== b.start) return a.start - b.start;
		return b.end - a.end;
	});
	const kept: SecretMatch[] = [];
	for (const match of sorted) {
		const overlaps = kept.some(
			(k) => match.start < k.end && match.end > k.start,
		);
		if (overlaps) continue;
		kept.push(match);
	}
	return kept;
}
