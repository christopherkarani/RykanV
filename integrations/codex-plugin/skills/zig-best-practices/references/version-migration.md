# Version And Migration

## Baseline

Always establish the active toolchain before applying advice:

```bash
zig version
zig env
sed -n '1,120p' build.zig.zon
rg -n "zig|minimum_zig_version|0\\.15|0\\.16|0\\.17" .github build.zig build.zig.zon README.md docs scripts
```

As of 2026-05-13:

- Latest tagged Zig release: `0.16.0` from 2026-04-13.
- Current development downloads: `0.17.0-dev.*`.
- ryk is pinned in `build.zig.zon` to `minimum_zig_version = "0.15.2"`.

Project pins win. Do not update code to 0.16 APIs unless the user asked for migration or the repo already targets 0.16.

## 0.15.x Habits To Preserve In Pinned Repos

- Use the exact `std` API available to the pinned compiler.
- Keep existing `build.zig` idioms unless the compiler rejects them.
- Update `build.zig.zon.fingerprint` only from Zig's compiler-provided suggested value.
- When `zig build run -- ...` wraps exit codes, run `./zig-out/bin/<tool>` directly for exact CLI behavior.
- Remember that local ryk history uses `zig build`, `zig build test`, and often `zig build test --summary all` where available.

## 0.16 Changes To Check Before Migrating

Read the 0.16.0 release notes and current language reference before editing these areas:

- I/O as an Interface.
- Async/await/suspend/resume have been removed from the language; do not recommend async syntax in new code.
- `std.process.Init`, process args/env becoming non-global, and "Juicy Main" entrypoint patterns.
- Current directory APIs renamed to current path APIs.
- `std.mem` index naming moving toward find/cut vocabulary.
- Migration to unmanaged containers.
- `@cImport` moving to build-system-owned integration.
- Build-system local package overrides, project-local fetch directories, unit-test timeouts, multiline/error-style flags.
- Thread pool removal and I/O-driven concurrency changes.
- Arena allocator thread-safety and thread-safe allocator removal.
- Packed/extern contexts got stricter: pointers in packed containers, implicit backing types in extern contexts, and unused bits in packed unions need renewed scrutiny.
- Vector/array in-memory coercion and runtime vector indexing changed; review SIMD or binary-data code carefully.

## 0.16 Migration Batches

Keep commits small and reversible:

1. Toolchain metadata: update `minimum_zig_version`, CI, docs, and install scripts together.
2. Build graph: fix `build.zig` API changes, package overrides, local package fetch behavior, and test timeouts.
3. Language churn: switch/type syntax, `@Type` replacement, packed/extern restrictions, vector/indexing changes.
4. Stdlib churn: I/O interface, process args/env, current path APIs, mem find/cut renames, unmanaged containers.
5. Interop churn: move C translation/import details into build-system-owned configuration.
6. Verification: focused tests, full build/test, target compiles, package archive/hash checks, and direct binary smokes.

## Migration Rules

- Make migrations explicit and mechanical; do not mix behavior changes with API churn.
- Keep one compatibility layer when a public API must support both 0.15 and 0.16.
- Add tests on both sides of the migrated boundary when possible.
- Prefer source-compatible patterns if they are simple and do not hide errors.
- Document the new minimum Zig version in `build.zig.zon`, CI, release notes, and user-facing setup docs together.
- If local `zig` is unavailable, do not claim compatibility. Record the intended migration plan and the exact verification that remains blocked.

## Drift Audit Commands

```bash
rg -n "std\\.io|fixedBufferStream|readToEndAlloc|readFileAlloc|std\\.process|Child|args|env|cwd\\(|@cImport|ArrayList\\(|HashMap\\(" src packages tests build.zig
rg -n "packed|extern|@ptrCast|@alignCast|@bitCast|@enumFromInt|@intCast|@truncate|@setRuntimeSafety" src packages tests
```

Use the results as prompts for focused fixes, not as proof that every occurrence is wrong.

## Source Links

- Zig downloads: https://ziglang.org/download/
- 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html
- 0.16.0 language reference: https://ziglang.org/documentation/0.16.0/
- Master language reference: https://ziglang.org/documentation/master/
- Build-system guide: https://ziglang.org/learn/build-system/
