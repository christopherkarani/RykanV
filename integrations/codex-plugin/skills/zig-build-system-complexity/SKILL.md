---
name: zig-build-system-complexity
description: Zig build-system and package-management workflow for coding agents. Use when creating, reviewing, debugging, or migrating build.zig, build.zig.zon, package dependencies, build steps, check/test/fuzz/bench steps, generated files, install artifacts, release archives, cross-target builds, CI build matrices, local package overrides, Zig package fingerprints, or Zig 0.15/0.16 build API drift.
---

# Zig Build System Complexity

## Operating Mode

Use this skill when the build graph is part of the product contract. First prove the active toolchain, pinned version, and visible build surface:

```bash
zig version
zig env
zig build --help
test -f build.zig.zon && sed -n '1,180p' build.zig.zon
```

As of 2026-05-13, Zig `0.16.0` is the latest tagged release. ryk-style repos may still be pinned to `0.15.2`; do not silently rewrite build APIs for a newer Zig unless the task is an upgrade.

## Build Graph Rules

- Treat `build.zig` as a DAG, not as an imperative shell script. Model compile, run, install, check, test, fuzz, bench, package, and generated-file steps explicitly.
- Keep host tools, target artifacts, generated sources, and installed artifacts separate. A host tool may run during the build; a target binary may only run when it matches the host.
- Prefer named steps with clear descriptions: `check`, `test`, `bench`, `release`, `docs`, `package`, `smoke`.
- Use `check` steps that compile without installing artifacts so editors and CI can report errors quickly.
- Run `zig build --help` after build changes; it is the user-facing contract for options and steps.

## Package Surface

- Treat `build.zig.zon` as the source of package truth: `name`, `version`, `minimum_zig_version`, `dependencies`, `paths`, and fingerprints/hashes.
- Keep `paths` strict. Include source, docs, examples, schemas, generated assets, and package scripts that consumers need; exclude caches, local state, dry-run output, and editor artifacts.
- After changing package contents, verify with Zig's package hash/fetch tooling and a clean archive listing when relevant.
- Do not edit fetched dependency cache directories. Use `zig build --fork=/path/to/local/clone` in Zig `0.16.x` when testing local dependency overrides.
- Keep project-local `zig-pkg/` or dependency-fetch output out of git unless vendoring is intentional and documented.
- Never guess dependency fingerprints or hashes. Use the value suggested by the active Zig toolchain or regenerate through Zig's package workflow.

## Dependency Review

- Pin exact URLs and hashes/fingerprints. Review provenance for every dependency update.
- Check whether dependency APIs match the repo's pinned Zig version before assuming latest examples compile.
- Capture transitive dependency changes in the review summary when they alter package hash, generated artifacts, or build-time tools.
- Do not use unofficial package indexes as canonical source of truth; verify upstream repo, tag, checksum, and license directly.

## Cross-Target Workflow

1. Identify the claim: compile support, link support, package support, runtime support, or hardware/OS integration.
2. Add build steps that make unsupported targets explicit instead of silently succeeding with no work.
3. Compile important targets with `-Dtarget=...` or repo options.
4. Run host-compatible binaries directly for smoke tests.
5. For non-host targets, inspect artifacts and run platform-specific CI before claiming runtime support.

Cross-compilation is not proof of runtime behavior, filesystem semantics, sandbox behavior, or OS integration.

## Generated Files

- Generate files through build steps when the generated output is required for compile or package correctness.
- Keep source mutation explicit. In Zig `0.16.0`, build-system temporary-file APIs changed; refresh docs before porting older `makeTempPath` or remove-dir patterns.
- For generated Zig code, add compile tests that import the generated module.
- For generated schemas/docs/assets, add file-existence or content checks if release packaging depends on them.

## Verification

Use the narrowest failing proof first, then the full lane:

```bash
zig build check --summary all
zig build test --summary all
zig build --summary all
```

When release/package behavior changes, also verify package contents, checksums, install paths, and clean-checkout visibility:

```bash
git diff --name-only
git ls-files --others --exclude-standard
git diff --check
```

## 0.15 to 0.16 Hotspots

- `@cImport` moved toward build-system-driven C translation.
- Package dependencies now fetch into project-local `zig-pkg/` before canonical global cache storage.
- `zig build --fork` can override packages locally.
- Missing package fingerprints and string-style package names are stricter failure points in `0.16.0+`.
- Unit-test timeouts, multiline error formatting, temporary-file APIs, and build-system flags changed.
- Standard-library churn can break build helper code just like application code; compile `build.zig` under the target Zig before diagnosing source files.

## Failure Playbook

- Fingerprint mismatch: do not hand-edit values; rerun the active Zig package command and use the suggested fingerprint/hash.
- Green cross-target build but no coverage: inspect `build.zig` for early returns or steps that skip non-native targets.
- Stale local binary after cross-build: rebuild native artifacts before running host smoke tests.
- Path dependency confusion: verify paths are relative to the build root and are not mixed with `url` for the same dependency.
- Package missing files: audit `build.zig.zon.paths`, `git ls-files`, and archive contents instead of trusting local tests.

## Source Refresh

Refresh primary sources before version-sensitive claims:

- `https://ziglang.org/learn/build-system/`
- `https://ziglang.org/download/`
- `https://ziglang.org/download/0.16.0/release-notes.html`
- `https://ziglang.org/documentation/0.16.0/`
