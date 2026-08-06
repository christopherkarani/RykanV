# Zig 0.16 maintenance prompt — Rykan V / ryk

Copy this entire file into a new agent session, or run: `pbcopy < docs/dev/zig-0.16-migration-prompt.md`

**Recommended:** reasoning effort **high** · use a focused maintenance branch

---

You are a senior Zig systems engineer maintaining the **ryk** repository (`christopherkarani/rykan`) on **Zig 0.16.0**.

The 0.15-to-0.16 migration is complete. Do not re-open it as a migration task; use this prompt to verify current behavior and make narrowly scoped 0.16-compatible changes.

## Repository facts (do not guess)

- **Current pin:** `.zigversion` = `0.16.0`, `build.zig.zon` → `minimum_zig_version = "0.16.0"`
- **CI:** `.github/workflows/{ci,test,build,release}.yml` use `mlugg/setup-zig@v2` with `version: 0.16.0`
- **Toolchain scripts:** `scripts/ensure-zig-toolchain.sh`, `scripts/zig`, `.envrc`, `scripts/test-fast.sh`, `build.zig` step `test-fast`
- **Layout:** `src/` (ryk CLI + lib), `packages/core/`, `packages/cli/`, `tests/phase*.zig`, `build.zig`
- **Build API:** uses `root_module`, `b.addModule`, and `b.createModule`; preserve the 0.16 API surface
- **High-risk I/O surfaces (grep first):**
  - `src/mcp/proxy.zig` — heavy `std.Io.Reader` / `std.Io.Writer`
  - `src/policy/load.zig`, `src/intercept/files.zig`, `src/audit/*`, `src/cli/hook.zig`, `src/cli/decide.zig`, `src/cli/run.zig`
  - `build.zig` — `VERSION` file read (may need `b.graph.io` in 0.16)
- **Compatibility shim:** `src/cli/interactive.zig` → `flushIfSupported` (`@hasDecl(T, "flush")`)
- **Ignore:** `dist/**`, repo-root `test_*` junk, `.orchestrator/` scratch
- **Do not commit:** `tasks/`, `reports/`, `go_to_market/`, `customer_pilot/`, `dist/`, `node_modules/` (see `AGENTS.md`)

## Goal

Make a focused maintenance change that:

1. Builds cleanly with **Zig 0.16.0** (macOS + Linux CI).
2. Passes `zig build`, `zig build test-fast`, `zig build test`, `./scripts/quick-install-dx-verify.sh`.
3. Keeps version pins and docs synchronized with 0.16.0.
4. Preserves behavior — no generic-agent policy rebalance unless compile forces it.

## Out of scope

- Policy preset content changes (unless compile-only)
- Unrelated refactors, release packaging, and Node plugin migrations

## Maintenance loop

1. Verify the pinned toolchain and inspect the nearest domain code before editing.
2. Keep `std.Io` ownership and allocator lifetimes explicit across blocking I/O.
3. Preserve the in-process Zig shell authority and fail-closed behavior.
4. Add a focused regression test for every behavior or compatibility fix.
5. Run the narrowest gate first, then the full relevant gate.

Do not use `usingnamespace`, `async`/`await`, bare `@Type`, or bare `@cImport`.

## Verification

```sh
zig version    # 0.16.0
zig build
zig build test-fast
zig build test
./scripts/quick-install-dx-verify.sh
```

Do not pipe full `build test` through `tail` or `rg | head`.

## Constraints

- Surgical diffs only.
- `./scripts/zig` must invoke 0.16.0.

## Success criteria

- [ ] CI/docs pin 0.16.0
- [ ] `zig build test` green, or the exact platform blocker is recorded
- [ ] quick-install verify green (policy unchanged)
- [ ] No stale 0.15.2 migration instructions remain in the active maintenance docs

Report the changed files, focused proof, full-gate result, and any platform-specific limitation.
