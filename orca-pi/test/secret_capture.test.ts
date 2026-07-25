import assert from "node:assert/strict";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	renameSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import {
	detectSecrets,
	handleSecretCaptureInput,
	inferEnvName,
	isInteractiveCaptureSession,
	isSecretCaptureDisabled,
	scrubContextMessages,
	scrubSecrets,
	_storeSecretToEnvFileWithHooksForTest,
	storeSecretToEnvFile,
} from "../extensions/secret_capture.ts";
import { installOrcaExtension } from "../extensions/orca.ts";

const SYNTH_OPENAI = "sk-fakeSyntheticOpenAIKey1234567890";
const SYNTH_GITHUB = "ghp_fakeSyntheticTokenValue1234567890";
const SYNTH_ANTHROPIC = "sk-ant-fakeSyntheticAnthropicKey1234567890";

test("detectSecrets returns empty for benign text", () => {
	assert.deepEqual(detectSecrets("hello"), []);
	assert.deepEqual(detectSecrets("run git status please"), []);
	assert.deepEqual(detectSecrets(""), []);
});

test("detectSecrets finds synthetic OpenAI key", () => {
	const matches = detectSecrets(
		`call openai with ${SYNTH_OPENAI}`,
	);
	assert.equal(matches.length, 1);
	assert.equal(matches[0].kind, "openai");
	assert.equal(matches[0].value, SYNTH_OPENAI);
});

test("detectSecrets finds GitHub and Anthropic tokens", () => {
	const gh = detectSecrets(`token ${SYNTH_GITHUB}`);
	assert.equal(gh.length, 1);
	assert.equal(gh[0].kind, "github");

	const ant = detectSecrets(`key ${SYNTH_ANTHROPIC}`);
	assert.equal(ant.length, 1);
	assert.equal(ant[0].kind, "anthropic");
});

test("detectSecrets finds secret-like NAME=value assignments", () => {
	const matches = detectSecrets(
		`export OPENAI_API_KEY=${SYNTH_OPENAI} and continue`,
	);
	assert.ok(matches.length >= 1);
	const assignment = matches.find((m) => m.kind === "assignment");
	assert.ok(assignment);
	assert.equal(assignment?.envNameHint, "OPENAI_API_KEY");
	assert.equal(assignment?.value, SYNTH_OPENAI);
});

test("inferEnvName maps known patterns", () => {
	assert.equal(
		inferEnvName({
			kind: "openai",
			value: SYNTH_OPENAI,
			start: 0,
			end: SYNTH_OPENAI.length,
		}),
		"OPENAI_API_KEY",
	);
	assert.equal(
		inferEnvName({
			kind: "github",
			value: SYNTH_GITHUB,
			start: 0,
			end: SYNTH_GITHUB.length,
		}),
		"GITHUB_TOKEN",
	);
	assert.equal(
		inferEnvName({
			kind: "anthropic",
			value: SYNTH_ANTHROPIC,
			start: 0,
			end: SYNTH_ANTHROPIC.length,
		}),
		"ANTHROPIC_API_KEY",
	);
	assert.equal(
		inferEnvName({
			kind: "assignment",
			value: "fake_secret_value",
			start: 0,
			end: 17,
			envNameHint: "MY_CUSTOM_TOKEN",
		}),
		"MY_CUSTOM_TOKEN",
	);
});

test("scrubSecrets removes key and keeps surrounding intent", () => {
	const text = `call openai with ${SYNTH_OPENAI} please`;
	const matches = detectSecrets(text);
	const scrubbed = scrubSecrets(text, matches, "OPENAI_API_KEY");
	assert.equal(scrubbed.includes(SYNTH_OPENAI), false);
	assert.match(scrubbed, /call openai with \$OPENAI_API_KEY please/);
	assert.match(scrubbed, /OPENAI_API_KEY environment variable/);
	assert.match(scrubbed, /Do not print or request the raw secret/);
});

test("storeSecretToEnvFile writes under .orca/dev-secrets.env", () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "orca-pi-secret-"));
	try {
		storeSecretToEnvFile(cwd, "OPENAI_API_KEY", SYNTH_OPENAI);
		const path = resolve(cwd, ".orca/dev-secrets.env");
		assert.ok(existsSync(path));
		const body = readFileSync(path, "utf8");
		assert.match(body, /^OPENAI_API_KEY=sk-fakeSyntheticOpenAIKey1234567890$/m);
		// Update replaces rather than duplicates.
		storeSecretToEnvFile(cwd, "OPENAI_API_KEY", "sk-fakeSyntheticOpenAIKeyUPDATED0001");
		const updated = readFileSync(path, "utf8");
		assert.equal(
			(updated.match(/^OPENAI_API_KEY=/gm) ?? []).length,
			1,
		);
		assert.match(updated, /sk-fakeSyntheticOpenAIKeyUPDATED0001/);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("storeSecretToEnvFile refuses symlinked credential directories and files", () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-secret-link-"));
	const outside = mkdtempSync(resolve(tmpdir(), "ryk-pi-secret-outside-"));
	try {
		symlinkSync(outside, resolve(cwd, ".orca"), "dir");
		assert.throws(
			() => storeSecretToEnvFile(cwd, "OPENAI_API_KEY", SYNTH_OPENAI),
			/Symlinked credential path/,
		);
		assert.equal(existsSync(resolve(outside, "dev-secrets.env")), false);

		rmSync(resolve(cwd, ".orca"));
		mkdirSync(resolve(cwd, ".orca"));
		const outsideFile = resolve(outside, "secret.env");
		writeFileSync(outsideFile, "UNCHANGED=true\n");
		symlinkSync(outsideFile, resolve(cwd, ".orca/dev-secrets.env"), "file");
		assert.throws(
			() => storeSecretToEnvFile(cwd, "OPENAI_API_KEY", SYNTH_OPENAI),
			/Symlinked credential path/,
		);
		assert.equal(readFileSync(outsideFile, "utf8"), "UNCHANGED=true\n");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
		rmSync(outside, { recursive: true, force: true });
	}
});

test("storeSecretToEnvFile fails closed if the credential directory is swapped before rename", () => {
	const cwd = mkdtempSync(resolve(tmpdir(), "ryk-pi-secret-swap-"));
	const outside = mkdtempSync(resolve(tmpdir(), "ryk-pi-secret-swap-outside-"));
	const moved = resolve(cwd, ".orca-moved");
	try {
		mkdirSync(resolve(cwd, ".orca"));
		assert.throws(
			() =>
				_storeSecretToEnvFileWithHooksForTest(
					cwd,
					"OPENAI_API_KEY",
					SYNTH_OPENAI,
					".orca/dev-secrets.env",
					{
						beforeRename() {
							renameSync(resolve(cwd, ".orca"), moved);
							symlinkSync(outside, resolve(cwd, ".orca"), "dir");
						},
					},
				),
			/Credential directory changed during write/,
		);
		assert.equal(existsSync(resolve(outside, "dev-secrets.env")), false);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
		rmSync(outside, { recursive: true, force: true });
	}
});

test("interactive accept stores and transforms without raw key", async () => {
	const stores: Array<{ name: string; value: string }> = [];
	const notifications: Array<{ message: string; type?: string }> = [];
	const result = await handleSecretCaptureInput(
		{
			text: `call openai with ${SYNTH_OPENAI}`,
			source: "interactive",
		},
		{
			hasUI: true,
			mode: "tui",
			cwd: process.cwd(),
			ui: {
				select: async () =>
					"Store as OPENAI_API_KEY and remove from this message",
				notify: (message, type) => notifications.push({ message, type }),
			},
		},
		{
			storeSecret: (_cwd, name, value) => {
				stores.push({ name, value });
			},
		},
	);

	assert.equal(result.action, "transform");
	if (result.action === "transform") {
		assert.equal(result.text.includes(SYNTH_OPENAI), false);
		assert.match(result.text, /\$OPENAI_API_KEY/);
	}
	assert.deepEqual(stores, [{ name: "OPENAI_API_KEY", value: SYNTH_OPENAI }]);
	assert.ok(
		notifications.every((n) => !n.message.includes(SYNTH_OPENAI)),
		"notifications must not contain raw secret",
	);
});

test("interactive decline does not store and scrubs raw key", async () => {
	const stores: Array<{ name: string; value: string }> = [];
	const result = await handleSecretCaptureInput(
		{
			text: `use ${SYNTH_GITHUB} for gh`,
			source: "interactive",
		},
		{
			hasUI: true,
			mode: "tui",
			ui: {
				select: async () =>
					"Remove secret from message without storing",
				notify: () => {},
			},
		},
		{
			storeSecret: (_cwd, name, value) => {
				stores.push({ name, value });
			},
		},
	);

	assert.equal(stores.length, 0);
	assert.equal(result.action, "transform");
	if (result.action === "transform") {
		assert.equal(result.text.includes(SYNTH_GITHUB), false);
		assert.match(result.text, /\$GITHUB_TOKEN/);
	}
});

test("interactive block returns handled and does not store", async () => {
	const stores: Array<{ name: string; value: string }> = [];
	const result = await handleSecretCaptureInput(
		{ text: `key ${SYNTH_OPENAI}`, source: "interactive" },
		{
			hasUI: true,
			mode: "tui",
			ui: {
				select: async () => "Block this message",
				notify: () => {},
			},
		},
		{
			storeSecret: (_cwd, name, value) => {
				stores.push({ name, value });
			},
		},
	);
	assert.equal(result.action, "handled");
	assert.equal(stores.length, 0);
});

test("noninteractive fails closed without store", async () => {
	const stores: Array<{ name: string; value: string }> = [];
	const result = await handleSecretCaptureInput(
		{ text: `key ${SYNTH_OPENAI}`, source: "rpc" },
		{
			hasUI: false,
			mode: "print",
			ui: {
				notify: () => {},
			},
		},
		{
			storeSecret: (_cwd, name, value) => {
				stores.push({ name, value });
			},
		},
	);
	assert.equal(result.action, "handled");
	assert.equal(stores.length, 0);
});

test("json mode is treated as noninteractive for capture", async () => {
	const result = await handleSecretCaptureInput(
		{ text: `key ${SYNTH_OPENAI}` },
		{ hasUI: true, mode: "json", ui: { select: async () => "should not run" } },
		{ storeSecret: () => {
			throw new Error("must not store");
		} },
	);
	assert.equal(result.action, "handled");
});

test("extension-sourced input continues unchanged", async () => {
	const result = await handleSecretCaptureInput(
		{
			text: `key ${SYNTH_OPENAI}`,
			source: "extension",
		},
		{ hasUI: true, mode: "tui" },
		{
			storeSecret: () => {
				throw new Error("must not store");
			},
		},
	);
	assert.deepEqual(result, { action: "continue" });
});

test("store failure fails closed (handled, no raw forward)", async () => {
	const result = await handleSecretCaptureInput(
		{ text: `key ${SYNTH_OPENAI}`, source: "interactive" },
		{
			hasUI: true,
			mode: "tui",
			ui: {
				select: async () =>
					"Store as OPENAI_API_KEY and remove from this message",
				notify: () => {},
			},
		},
		{
			storeSecret: () => {
				throw new Error("disk full");
			},
		},
	);
	assert.equal(result.action, "handled");
});

test("isInteractiveCaptureSession and disable flag", () => {
	assert.equal(isInteractiveCaptureSession({ hasUI: true, mode: "tui" }), true);
	assert.equal(
		isInteractiveCaptureSession({ hasUI: false, mode: "tui" }),
		false,
	);
	assert.equal(
		isInteractiveCaptureSession({ hasUI: true, mode: "print" }),
		false,
	);
	assert.equal(
		isSecretCaptureDisabled({ ORCA_PI_SECRET_CAPTURE: "false" }),
		true,
	);
	assert.equal(isSecretCaptureDisabled({}), false);
});

test("scrubContextMessages scrubs user text without storing", () => {
	const messages = [
		{
			role: "user",
			content: `please use ${SYNTH_OPENAI}`,
		},
		{
			role: "assistant",
			content: "ok",
		},
		{
			role: "user",
			content: [{ type: "text", text: `token ${SYNTH_GITHUB}` }],
		},
	];
	const scrubbed = scrubContextMessages(messages);
	assert.equal(
		JSON.stringify(scrubbed).includes(SYNTH_OPENAI),
		false,
	);
	assert.equal(
		JSON.stringify(scrubbed).includes(SYNTH_GITHUB),
		false,
	);
	assert.equal(scrubbed[1].content, "ok");
});

test("installOrcaExtension wires input capture and keeps bash evaluate", async () => {
	const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
	const pi = {
		on(event: string, handler: (event: any, ctx: any) => any) {
			const list = handlers.get(event) ?? [];
			list.push(handler);
			handlers.set(event, list);
		},
		registerCommand() {},
	};

	const stores: Array<{ name: string; value: string }> = [];
	// Capture is wired inside install; we test via input handler.
	installOrcaExtension(pi as any, {
		orcaBin: "orca",
		spawn: (() => {
			throw new Error("spawn not used in this test path");
		}) as any,
	});

	assert.ok(handlers.get("input")?.length, "expected input handler");
	assert.ok(handlers.get("context")?.length, "expected context handler");
	assert.ok(handlers.get("tool_call")?.length, "expected tool_call handler");

	const inputHandler = handlers.get("input")![0];
	const wireCwd = mkdtempSync(resolve(tmpdir(), "orca-pi-wire-"));
	try {
		const accept = await inputHandler(
			{ text: `call openai with ${SYNTH_OPENAI}`, source: "interactive" },
			{
				hasUI: true,
				mode: "tui",
				cwd: wireCwd,
				ui: {
					select: async (title: string, options: string[]) => {
						assert.match(title, /credential capture/i);
						return options[0];
					},
					notify: () => {},
				},
			},
		);
		assert.equal(accept.action, "transform");
		assert.equal(accept.text.includes(SYNTH_OPENAI), false);
		assert.ok(
			existsSync(resolve(wireCwd, ".orca/dev-secrets.env")),
			"accept should write dev-secrets.env",
		);

		const noninteractive = await inputHandler(
			{ text: `call openai with ${SYNTH_OPENAI}` },
			{ hasUI: false, mode: "print" },
		);
		assert.equal(noninteractive.action, "handled");
	} finally {
		rmSync(wireCwd, { recursive: true, force: true });
	}

	// Silence unused
	void stores;
});

test("bash tool_call path still present after secret capture wiring", async () => {
	// Reuse the same FakeChild pattern lightly: allow when orca returns allow.
	const { EventEmitter } = await import("node:events");
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
		on(event: string, handler: (...args: any[]) => void): void {
			this.emitter.on(event, handler);
		}
		close(code: number): void {
			this.emitter.emit("close", code);
		}
	}

	const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
	const pi = {
		on(event: string, handler: (event: any, ctx: any) => any) {
			const list = handlers.get(event) ?? [];
			list.push(handler);
			handlers.set(event, list);
		},
		registerCommand() {},
	};

	const spawn = () => {
		const child = new FakeChild();
		queueMicrotask(() => {
			child.stdout.emit(
				"data",
				JSON.stringify({
					decision: "allow",
					reason: "Command allowed",
					daemon: { status: "healthy", compatible: true },
				}),
			);
			child.close(0);
		});
		return child;
	};

	installOrcaExtension(pi as any, {
		orcaBin: "orca",
		spawn: spawn as any,
	});

	const result = await handlers.get("tool_call")![0](
		{ toolName: "bash", input: { command: "git status" } },
		{
			cwd: process.cwd(),
			mode: "tui",
			hasUI: true,
			sessionManager: { getSessionId: () => "s1" },
			ui: {
				notify: () => {},
				setStatus: () => {},
				setWidget: () => {},
			},
		},
	);
	assert.equal(result, undefined);
});
