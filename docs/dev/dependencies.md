# Dependency Notes

## Phase 02

New dependency: none.

At Phase 02, ryk used only the Zig standard library. New dependencies must document:

- name and version/source;
- license;
- why Zig stdlib or local code is insufficient;
- whether the dependency parses untrusted input;
- whether it is used in security-critical code;
- how it is tested.

## Phase 24

New dependency: none.

ryk Core facade, schema registry, and experimental ABI skeleton use only the Zig standard library and existing in-repo modules. No new parser, security-critical dependency, external network dependency, or hardware dependency was added.

## CLI TUI

Dependency: `libvaxis` 0.6.0, pinned to commit
`ca781b3c01f44a92e5331652823b5a9ce445be96` and Zig package
hash `vaxis-0.6.0-BWNV_Gz5CQBTx7g34RYMPTL-bJhsFCU3ECHQ-CZlBVsn` in
`build.zig.zon`.

- License: MIT.
- Purpose: portable terminal capability detection, raw input, and interactive
  widgets for ryk's guided CLI flows. The standard library does not provide a
  terminal UI/event abstraction.
- Security boundary: libvaxis renders terminal UI and parses terminal input. It
  does not evaluate policy, authorize commands, or parse ryk machine APIs.
  Linear and machine output remain implemented in ryk and do not depend on it.
- Pin verification: Zig verifies the package hash before use. Generated package
  contents live in ignored `zig-pkg/`; no dependency source is vendored.
- Transitive audit: libvaxis pins `zigimg` at
  `d695acd97c02e57bb151e8f659d1280f5cd6ca70` and lazy `uucode` at
  `2826a37a4562284fdacd8fa029d49509cc9bffcd`. Neither is used in ryk policy or
  daemon trust decisions. `uucode` is also declared in ryk's root manifest and
  wired as libvaxis's external Unicode module because Zig does not fetch the
  upstream lazy dependency reliably from a clean local package cache. Updates
  require reviewing the upstream manifests,
  licenses, and Zig package hashes, then running the CLI test and release gates.
- Release dry-run size accounting: `scripts/release-dry-run.sh` now extracts the
  built host archive and reports `ryk` plus `ryk-daemon` byte sizes. The first
  Phase 8 dry-run on darwin-arm64 established `ryk` at 2,828,488 bytes and
  `ryk-daemon` at 19,752,816 bytes; no hard threshold is enforced.

## Dashboard UI (`ryk-dashboard-ui`)

Local operator UI exported as static assets under `ryk-dashboard-ui/dist` and
served by the Zig `ryk dashboard` command. These Node packages are **build-time
only** for the UI export; they are not linked into `ryk` or `ryk-daemon`.

| Package | Role | Notes |
|---|---|---|
| `next` ^15.1 | Static export / React app framework | Builds machine-wide + workspace dashboard |
| `react` / `react-dom` ^19 | UI runtime | Used only in the exported static bundle |
| `tailwindcss` ^3.4 + `postcss` / `autoprefixer` | Styling | Build-time CSS pipeline |
| `typescript` ^5.7 | Typecheck | Dev/build only |
| `lucide-react` ^0.460 | Icons | Presentation only |
| `shiki` ^1.24 / `ansi-to-html` ^0.7 | Code/ANSI rendering | Presentation of command output |
| `clsx` / `tailwind-merge` / `class-variance-authority` | Class composition | Presentation only |
| `geist` ^1.3 | Font package | Presentation only |

- License: primarily MIT (Next/React ecosystem). Review upstream licenses on
  upgrade.
- Security boundary: the dashboard UI talks to the local Zig dashboard HTTP
  server (CSRF-gated actions, localhost-only by default). It does not evaluate
  policy or replace the daemon. Secrets must still be redacted before any
  host-visible text is written.
- Why not Zig-only assets: the machine-wide operator UI needs a component model
  and static export pipeline; the existing Zig dashboard server continues to own
  API, authz, and feed aggregation.
- Testing: `npm test` in `ryk-dashboard-ui` (contract tests) and
  `scripts/install-layout-smoke-test.sh` markers for the shipped export.

## fm-steward Wax few-shot (2026-07-22)

New dependency: **Wax** (Swift Package Manager).

- Name: Wax  
- Source: GitHub [`christopherkarani/Wax`](https://github.com/christopherkarani/Wax) pin **exact 0.1.25**  
  (`exact: "0.1.25"` in `macos/fm-steward/Package.swift`; matches `Package.resolved`)  
- License: Apache-2.0  
- Why: on-device few-shot retrieval for residual Foundation Model classify; not available in Zig std / Foundation alone as a single-file hybrid memory  
- Untrusted input: searches agent command strings already present on the host; store is a **curated seed** (`Fixtures/ambig-fewshot/seed.json`), not untrusted web or live agent traffic  
- Security role: **assist only** for residual FM — never a security authority; runs only after `RulesPrePass` returns nil; never unlocks hard deny; fail-open (empty few-shots) on open/search errors  
- Platforms: macOS 14+ upstream; fm-steward targets macOS 26+  
- Search mode: product/CLI default **text** for determinism (`traits: []` disables default MiniLM); hybrid optional when MiniLM trait enabled  
- Note: **0.1.24** SPM checkout failed on a broken `homebrew-wax` submodule pin; pin **exact 0.1.25** (not a `from:` range)  

- Concurrency: open store via `Memory(at:config:)` with a value `Config` (not a non-Sendable configure closure)  
- Tests: protocol + `StaticFewShotRetriever` / `NullFewShotRetriever`; temp-dir Wax text-mode integration test

## Full Zig shell engine (2026-07-21, parity 2026-07-22)

New dependency: **PCRE2** (Zig package `pcre2`, statically linked as `pcre2-8`).

In-process Zig `shell_engine` is the product shell Evaluate authority. Pack
patterns from the frozen orca-rs oracle (85 packs, ~792 destructive / ~830 safe
rules) are embedded as JSON and matched with PCRE2 via a thin C shim
(`src/shell_engine/pcre2_shim.c`). Structured helpers cover multi-segment split,
wrapper stripping, false-positive sanitize, and heredoc/inline embeds.

- Source: `build.zig.zon` dependency on [PCRE2Project/pcre2](https://github.com/PCRE2Project/pcre2)
  (Zig `build.zig` upstream); compiled per `-Dtarget` so release cross-builds do
  not need host `libpcre2-dev` / Homebrew `pcre2`.
- Link: `build.zig` `addPcre2Shim` on the `ryk` module and shell_engine tests
  (static `pcre2-8` + shim; no system library search paths).
- The former Rust `orca-rs` daemon/evaluator crate is removed from the product tree.
