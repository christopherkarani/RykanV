import assert from "node:assert/strict";
import {
	chmodSync,
	copyFileSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

test("clean HOME bundled extension loads and invokes the injected ryk binary", async () => {
	const home = mkdtempSync(resolve(tmpdir(), "ryk-pi-clean-home-"));
	const extensionDir = resolve(home, ".pi/agent/extensions/ryk");
	const invocationLog = resolve(home, "invocations.log");
	const rykBinary = resolve(home, "installed ryk");
	const sourceDir = resolve(dirname(new URL(import.meta.url).pathname), "../extensions");

	try {
		mkdirSync(extensionDir, { recursive: true });
		copyFileSync(resolve(sourceDir, "orca.ts"), resolve(extensionDir, "runtime.ts"));
		copyFileSync(
			resolve(sourceDir, "secret_capture.ts"),
			resolve(extensionDir, "secret_capture.ts"),
		);
		copyFileSync(
			resolve(sourceDir, "parent_ask.ts"),
			resolve(extensionDir, "parent_ask.ts"),
		);
		writeFileSync(
			resolve(extensionDir, "index.ts"),
			[
				'import { installOrcaExtension } from "./runtime.ts";',
				"export default function rykPiExtension(",
				"  pi: Parameters<typeof installOrcaExtension>[0],",
				"): void {",
				`  installOrcaExtension(pi, { orcaBin: ${JSON.stringify(rykBinary)} });`,
				"}",
				"",
			].join("\n"),
		);
		writeFileSync(
			rykBinary,
			`#!/bin/sh\nprintf '%s\\n' \"$0\" >> ${JSON.stringify(invocationLog)}\ncat >/dev/null\nprintf '%s\\n' '{\"decision\":\"allow\",\"reason\":\"allowed\"}'\n`,
		);
		chmodSync(rykBinary, 0o700);

		const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
		const pi = {
			on(name: string, handler: (event: any, ctx: any) => any) {
				const entries = handlers.get(name) ?? [];
				entries.push(handler);
				handlers.set(name, entries);
			},
			registerCommand() {},
		};

		const extension = await import(
			`${pathToFileURL(resolve(extensionDir, "index.ts")).href}?clean=${Date.now()}`
		);
		extension.default(pi);
		const result = await handlers.get("tool_call")![0](
			{ toolName: "bash", input: { command: "git status" } },
			{
				cwd: home,
				mode: "noninteractive",
				hasUI: false,
				sessionManager: { getSessionId: () => "clean-home" },
			},
		);
		assert.equal(result, undefined);
		assert.equal(readFileSync(invocationLog, "utf8").trim(), rykBinary);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
});
