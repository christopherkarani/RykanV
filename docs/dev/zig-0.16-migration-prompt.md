# Zig 0.16 migration prompt — Orca / Aegis

Copy this entire file into a new agent session, or run: `pbcopy < docs/dev/zig-0.16-migration-prompt.md`

**Recommended:** reasoning effort **high** · branch **`feat/zig-0.16`**

---

You are a senior Zig systems engineer porting the **Orca** repository (`christopherkarani/rykan`) from **Zig 0.15.2 → Zig 0.16.0**.

This is an **explicit, approved** 0.16 migration. Override any prior repo guidance that says “stay on 0.15.2 only” for this task.

## Repository facts (do not guess)

- **Current pin (pre-migration):** `.zigversion` = `0.15.2`, `build.zig.zon` → `minimum_zig_version = "0.15.2"`
- **CI:** `.github/workflows/{ci,test,build,release}.yml` use `mlugg/setup-zig@v2` with `version: 0.15.2`
- **Toolchain scripts:** `scripts/ensure-zig-toolchain.sh`, `scripts/zig`, `.envrc`, `scripts/test-fast.sh`, `build.zig` step `test-fast`
- **Layout:** `src/` (orca CLI + lib), `packages/core/`, `packages/cli/`, `tests/phase*.zig`, `build.zig`
- **Build API:** already uses `root_module`, `b.addModule`, `b.createModule` — validate against 0.16 release notes
- **High-risk I/O surfaces (grep first):**
  - `src/mcp/proxy.zig` — heavy `std.Io.Reader` / `std.Io.Writer`
  - `src/policy/load.zig`, `src/intercept/files.zig`, `src/audit/*`, `src/cli/hook.zig`, `src/cli/decide.zig`, `src/cli/run.zig`
  - `build.zig` — `VERSION` file read (may need `b.graph.io` in 0.16)
- **Compatibility shim:** `src/cli/interactive.zig` → `flushIfSupported` (`@hasDecl(T, "flush")`)
- **Ignore:** `dist/**`, repo-root `test_*` junk, `.orchestrator/` scratch
- **Do not commit:** `tasks/`, `reports/`, `go_to_market/`, `customer_pilot/`, `dist/`, `node_modules/` (see `AGENTS.md`)

## Goal

Single focused PR on **`feat/zig-0.16`** that:

1. Builds cleanly with **Zig 0.16.0** (macOS + Linux CI).
2. Passes `zig build`, `zig build test-fast`, `zig build test`, `./scripts/quick-install-dx-verify.sh`.
3. Updates all version pins and docs (no more “never migrate to 0.16”).
4. Preserves behavior — no generic-agent policy rebalance unless compile forces it.

## Out of scope

- Policy preset content changes (unless compile-only)
- Unrelated refactors, release packaging, Node plugin migrations

## Migration strategy

### Phase 0 — Branch & toolchain

1. Work on branch **`feat/zig-0.16`** from latest **`main`**.
2. Install Zig **0.16.0**; update `.zigversion`.
3. Update `scripts/ensure-zig-toolchain.sh` for 0.16.0 archives.
4. `zig build` → fix compile errors in waves.

### Phase 1 — Pin bump

| File | Change |
|------|--------|
| `.zigversion` | `0.16.0` |
| `build.zig.zon` | `minimum_zig_version = "0.16.0"` |
| `.github/workflows/*.yml` | `version: 0.16.0` |
| `AGENTS.md`, `CONTRIBUTING.md`, `docs/quickstart.md`, `docs/troubleshooting.md`, `docs/install.md`, `README.md` | toolchain text |

### Phase 2 — `std.Io` port

Thread `io: std.Io` from entry points (`main`, CLI, tests) through blocking I/O. Priority: `src/mcp/`, `policy/load.zig`, `intercept/files.zig`, `audit/`, CLI hooks.

Do not use: `usingnamespace`, `async`/`await`, `@Type`, bare `@cImport`.

### Phase 3 — Build system

Fix `build.zig` for 0.16 I/O/allocation APIs. Keep `test-fast` step.

### Phase 4 — Mechanical sweep

`ArrayList` init, `@typeInfo` enum fields, writer `flush`, `std.fs` → `std.Io.Dir` per compiler.

### Phase 5 — Verification

```sh
zig version    # 0.16.0
zig build
zig build test-fast
zig build test
./scripts/quick-install-dx-verify.sh
```

Do not pipe full `build test` through `tail` or `rg | head`.

### Phase 6 — PR

Title: `build: migrate toolchain and std.Io usage to Zig 0.16.0`

## Constraints

- Surgical diffs only.
- `./scripts/zig` must invoke 0.16.0 after `ensure-zig-toolchain.sh` update.

## Success criteria

- [ ] CI/docs pin 0.16.0
- [ ] `zig build test` green
- [ ] quick-install verify green (policy unchanged)
- [ ] AGENTS.md allows 0.16

Begin Phase 0–1, then compile-fix loop. Report after each phase.