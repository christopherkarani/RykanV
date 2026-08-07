# Zig `shell_engine` ↔ Rust pack parity backlog

Living checklist of shell destructive-command protection that existed in
`orca-rs` (deleted on the Zig MVP cutover) and must be re-implemented in
`src/shell_engine/` for **100% decision parity**.

| Field | Value |
|-------|-------|
| Status | Parity complete (2026-07-22) |
| Baseline | `origin/main` tree `orca-rs/src/packs/**` + `orca-rs/tests/corpus/**` |
| Temporary oracle repo | `/Users/chriskarani/CodingProjects/ryk-rs-parity-ref` (tag `baseline-eec9446f702d`) |
| Agent goal prompt | [`GOAL-parity-prompt.md`](GOAL-parity-prompt.md) |
| Zig engine | `src/shell_engine/` (85 oracle packs embedded; full corpus gate) |
| Inventory date | 2026-07-22 |
| Source commit (packs) | `eec9446f702d514cd33d7f9c92ffbfc90bc97004` — also `git show origin/main:orca-rs/...` |

## Parity definition

**100% parity** means, for every enabled Rust pack and every case in the Rust
canonical + edge corpora:

1. Same **decision** (`allow` / `deny`) for the same command string (after
   documented normalization).
2. Same **pack_id** and stable **pattern family** (exact `pattern_name` preferred;
   aliases allowed only when listed in a migration table).
3. Same **severity** class (`critical` / `high` / `medium` / `low`) driving the
   Zig mode×severity matrix.
4. Same **bypass resistance** for wrappers, compounds, quoting, heredoc / `-c`
   embeds covered by the Rust corpus.

Parity is **not** “line-for-line regex port.” Structured argv / AST matching in
Zig is fine if decisions and rule IDs match.

### Intentional product differences (not pack gaps)

| Topic | Rust daemon | Zig product target | Notes |
|-------|-------------|--------------------|-------|
| Hook transport / evaluate failure | Often fail-**open** in hook mode | Fail-**closed** deny | Keep Zig fail-closed; do not “parity” this away |
| Unmatched command | Pack miss → allow (after safe/destructive scan) | Same (full 85 packs loaded) | Miss after full pack scan is allow — not a pack gap |
| Graduated response / suggestions | Rich daemon fields | Optional later | Decision parity first; UX second |
| `RYK_SHELL_EVAL=rust` | Live daemon | Gone after cutover | Remove env once Zig parity gate is green |

## Snapshot: parity status

| Surface | Rust baseline | Zig product | Gap |
|---------|---------------|-------------|-----|
| Pack IDs | **85** | **85** done | **0** |
| `destructive_pattern!` rules | **792** | **792** embedded | **0** |
| `safe_pattern!` rules | **830** | **830** embedded | **0** |
| Corpus cases | **351** ported (+ oracle TOML) | **351** @ 100% match | **0** |
| Pack categories | **25** | **25** (all tiers done) | **0** |

## P0 — Engine / parser prerequisites

Do these **before** claiming pack parity. Missing engine behavior makes every
ported pack bypassable.

| ID | Gap | Rust reference | Acceptance |
|----|-----|----------------|------------|
| E1 | Evaluate **destructive before** (or without) naive safe-prefix allow | Safe packs + ordering invariants | `git status; rm -rf /` → deny |
| E2 | Multi-segment commands: `;`, `&&`, `\|\|`, `\|` | `tests/corpus/edge_cases/multi_segment.toml` | All multi-segment corpus cases |
| E3 | Command substitution / backticks: `$(…)`, `` `…` `` | bypass + edge corpora | Substitution bodies evaluated or fail-closed |
| E4 | Wrapper prefixes: `sudo`, `doas`, `env`, `command`, `nice`, … | `bypass_attempts/wrappers.toml` | Wrapper strip then re-evaluate |
| E5 | Quoting / escapes | `edge_cases/quoting.toml` | Quoting corpus green |
| E6 | Heredoc / here-string / `bash -c` / `python -c` embeds | ADR-001, `bypass_attempts/heredoc_inline.toml` | Heredoc corpus green |
| E7 | Obfuscation / unicode / boundary cases | `obfuscation.toml`, `unicode.toml`, `boundaries.toml` | Those corpora green |
| E8 | Allowlist semantics: entry bypasses **matched rule only**, not all packs | canonical invariants | Unit tests for scoped allowlist |
| E9 | Wire corpus into CI gates (`test-shell-engine` + `zig build test`) | — | Full suite cannot skip shell corpus |
| E10 | Port Rust corpus → Zig JSONL/TOML under `tests/fixtures/` or `src/shell_engine/` | `orca-rs/tests/corpus/**` | ≥355 cases runnable |

**Engine (E1–E10):** multi-segment split, wrapper strip, per-pack safe/destructive
ordering, sanitize/heredoc, and PCRE2 pack registry are in place. Compound
`git status; rm -rf /` denies.

## P0 — Core/system packs (complete)

All six P0 pack IDs are loaded from the embedded oracle pattern set (full destructive + safe coverage).

### `core.filesystem` (Rust 23 destructive / 62 safe) — **done**

| Pattern | Zig status |
|---------|------------|
| `rm-rf-root-home` | done |
| `rm-rf-general` | done (covers some separate-flag forms) |
| `rm-r-f-separate-root-home` | done |
| `rm-r-f-separate` | done |
| `rm-recursive-force-root-home` | done |
| `rm-recursive-force-long` | done |
| `find-delete-root-home` | done |
| `find-delete-general` | done |
| `unlink-root-home` | done |
| `unlink-general` | done |
| `truncate-zero-general` | done |
| `truncate-zero-root-home` | done |
| `shred-general` | done |
| `shred-root-home` | done |
| `tar-remove-files-general` | done |
| `tar-remove-files-root-home` | done |
| `dd-overwrite-general` | done |
| `dd-overwrite-root-home` | done |
| `mv-sensitive-source-root-home` | done |
| `cp-sensitive-then-delete` | done |
| `ln-symlink-sensitive-then-delete` | done |
| `rsync-sensitive-then-delete` | done |
| `redirect-truncate-root-home` | done |
| Safe patterns (temp `rm`, etc.) | done |

### `core.git` (Rust 12 destructive / 6 safe) — **done**

| Pattern | Zig status |
|---------|------------|
| `reset-hard` | done |
| `clean-force` | done |
| `push-force-long` | done |
| `push-force-short` | done |
| `stash-drop` | done |
| `stash-clear` | done |
| `branch-force-delete` | done |
| `checkout-discard` | done |
| `checkout-ref-discard` | done |
| `restore-worktree` | done (Zig labels under `strict_git`) |
| `restore-worktree-explicit` | done |
| `reset-merge` | done |
| Safe git patterns | done |

### `strict_git` (Rust 14 destructive) — **done**

| Pattern | Zig status |
|---------|------------|
| `restore-worktree` | done (also overlaps core.git) |
| `rebase-interactive` | done |
| `push-force-any` | done |
| `rebase` | done |
| `commit-amend` | done |
| `cherry-pick` | done |
| `filter-branch` | done |
| `filter-repo` | done |
| `reflog-expire` | done |
| `gc-aggressive` | done |
| `worktree-remove` | done |
| `submodule-deinit` | done |
| `add-all-dot` | done |
| `add-all-flag` | done |
| `push-master` | done |
| `push-main` | done |

### `system.disk` (Rust 39 destructive) — **done**

Full oracle pattern set is embedded in `oracle_packs.json` and matched via PCRE2
(destructive + safe). Default pack enablement includes `system.disk` (Rust
`Config::default()`).

### `system.permissions` (Rust 7 destructive) — **done**

| Pattern | Zig status |
|---------|------------|
| `chmod-777` | done (as `chmod-world-writable`) — **rename/alias for parity** |
| `chown-recursive-root` | done |
| `chmod-recursive-root` | done |
| `chmod-setuid` | done |
| `chmod-setgid` | done |
| `chown-to-root` | done |
| `setfacl-all` | done |
| `privilege-escalation` (Zig-only coarse `sudo`/`doas`) | keep or map to wrappers (E4) |

### `system.services` (Rust 8 destructive) — **done**

| Pattern | Zig status |
|---------|------------|
| `systemctl-stop` / critical variants | done |
| `service-stop` / critical | done |
| `systemctl-isolate` | done |
| `systemctl-power` | done |
| `shutdown` | done |
| `reboot` | done |
| `init-level` | done |

## P1 — High-value categories (complete)

Port entire pack IDs (destructive + safe). Counts are `destructive_pattern!` /
`safe_pattern!` from `origin/main`.

| Pack ID | Dest | Safe | Status |
|---------|-----:|-----:|--------|
| `containers.docker` | 9 | 10 | done |
| `containers.podman` | 8 | 8 | done |
| `containers.compose` | 4 | 7 | done |
| `kubernetes.kubectl` | 13 | 10 | done |
| `kubernetes.helm` | 4 | 12 | done |
| `kubernetes.kustomize` | 3 | 4 | done |
| `cloud.aws` | 41 | 11 | done |
| `cloud.gcp` | 23 | 7 | done |
| `cloud.azure` | 21 | 9 | done |
| `secrets.vault` | 9 | 11 | done |
| `secrets.aws_secrets` | 7 | 9 | done |
| `secrets.onepassword` | 6 | 10 | done |
| `secrets.doppler` | 4 | 8 | done |
| `storage.s3` | 6 | 10 | done |
| `storage.gcs` | 6 | 15 | done |
| `storage.minio` | 6 | 14 | done |
| `storage.azure_blob` | 6 | 19 | done |
| `remote.rsync` | 2 | 3 | done |
| `remote.ssh` | 6 | 9 | done |
| `remote.scp` | 7 | 5 | done |
| `infrastructure.terraform` | 8 | 11 | done |
| `infrastructure.pulumi` | 6 | 9 | done |
| `infrastructure.ansible` | 4 | 7 | done |
| `package_managers` | 18 | 18 | done |
| `database.postgresql` | 7 | 2 | done |
| `database.mysql` | 10 | 5 | done |
| `database.mongodb` | 5 | 5 | done |
| `database.redis` | 13 | 6 | done |
| `database.sqlite` | 4 | 4 | done |
| `database.supabase` | 18 | 35 | done |
| `cicd.github_actions` | 6 | 7 | done |
| `cicd.gitlab_ci` | 4 | 7 | done |
| `cicd.jenkins` | 6 | 9 | done |
| `cicd.circleci` | 6 | 10 | done |

**P1 subtotal:** 34 packs, **~338** destructive rules.

## P2 — Platform / messaging / search / backup / DNS / LB / monitoring / payment

| Pack ID | Dest | Safe | Status |
|---------|-----:|-----:|--------|
| `platform.github` | 16 | 10 | done |
| `platform.gitlab` | 11 | 11 | done |
| `platform.railway` | 23 | 10 | done |
| `platform.modal` | 12 | 14 | done |
| `messaging.kafka` | 7 | 9 | done |
| `messaging.rabbitmq` | 7 | 6 | done |
| `messaging.nats` | 6 | 10 | done |
| `messaging.sqs_sns` | 8 | 6 | done |
| `search.elasticsearch` | 10 | 6 | done |
| `search.opensearch` | 12 | 8 | done |
| `search.meilisearch` | 10 | 8 | done |
| `search.algolia` | 7 | 4 | done |
| `backup.restic` | 5 | 8 | done |
| `backup.borg` | 5 | 7 | done |
| `backup.rclone` | 7 | 8 | done |
| `backup.velero` | 6 | 7 | done |
| `dns.cloudflare` | 4 | 3 | done |
| `dns.route53` | 6 | 4 | done |
| `dns.generic` | 3 | 3 | done |
| `loadbalancer.nginx` | 5 | 7 | done |
| `loadbalancer.haproxy` | 9 | 5 | done |
| `loadbalancer.traefik` | 9 | 6 | done |
| `loadbalancer.elb` | 7 | 4 | done |
| `monitoring.datadog` | 4 | 3 | done |
| `monitoring.pagerduty` | 7 | 4 | done |
| `monitoring.prometheus` | 7 | 4 | done |
| `monitoring.newrelic` | 6 | 4 | done |
| `monitoring.splunk` | 4 | 3 | done |
| `payment.stripe` | 7 | 6 | done |
| `payment.braintree` | 6 | 3 | done |
| `payment.square` | 7 | 3 | done |

**P2 subtotal:** 31 packs, **~247** destructive rules.

## P3 — Remaining categories

| Pack ID | Dest | Safe | Status |
|---------|-----:|-----:|--------|
| `cdn.cloudflare_workers` | 8 | 12 | done |
| `cdn.cloudfront` | 7 | 12 | done |
| `cdn.fastly` | 11 | 14 | done |
| `apigateway.aws` | 18 | 27 | done |
| `apigateway.kong` | 11 | 14 | done |
| `apigateway.apigee` | 14 | 24 | done |
| `featureflags.launchdarkly` | 11 | 18 | done |
| `featureflags.split` | 10 | 17 | done |
| `featureflags.flipt` | 8 | 18 | done |
| `featureflags.unleash` | 9 | 16 | done |
| `email.ses` | 10 | 25 | done |
| `email.sendgrid` | 8 | 0 | done |
| `email.mailgun` | 8 | 0 | done |
| `email.postmark` | 7 | 0 | done |

**P3 subtotal:** 14 packs, **~140** destructive rules.

## Full pack ID checklist (85)

Copy/status board. Update the Status column as packs land (`missing` → `partial` → `done`).

| # | Pack ID | Dest | Safe | Tier | Status |
|--:|---------|-----:|-----:|------|--------|
| 1 | `core.filesystem` | 23 | 62 | P0 | done |
| 2 | `core.git` | 12 | 6 | P0 | done |
| 3 | `strict_git` | 14 | 0 | P0 | done |
| 4 | `system.disk` | 39 | 32 | P0 | done |
| 5 | `system.permissions` | 7 | 5 | P0 | done |
| 6 | `system.services` | 8 | 8 | P0 | done |
| 7 | `containers.docker` | 9 | 10 | P1 | done |
| 8 | `containers.podman` | 8 | 8 | P1 | done |
| 9 | `containers.compose` | 4 | 7 | P1 | done |
| 10 | `kubernetes.kubectl` | 13 | 10 | P1 | done |
| 11 | `kubernetes.helm` | 4 | 12 | P1 | done |
| 12 | `kubernetes.kustomize` | 3 | 4 | P1 | done |
| 13 | `cloud.aws` | 41 | 11 | P1 | done |
| 14 | `cloud.gcp` | 23 | 7 | P1 | done |
| 15 | `cloud.azure` | 21 | 9 | P1 | done |
| 16 | `secrets.vault` | 9 | 11 | P1 | done |
| 17 | `secrets.aws_secrets` | 7 | 9 | P1 | done |
| 18 | `secrets.onepassword` | 6 | 10 | P1 | done |
| 19 | `secrets.doppler` | 4 | 8 | P1 | done |
| 20 | `storage.s3` | 6 | 10 | P1 | done |
| 21 | `storage.gcs` | 6 | 15 | P1 | done |
| 22 | `storage.minio` | 6 | 14 | P1 | done |
| 23 | `storage.azure_blob` | 6 | 19 | P1 | done |
| 24 | `remote.rsync` | 2 | 3 | P1 | done |
| 25 | `remote.ssh` | 6 | 9 | P1 | done |
| 26 | `remote.scp` | 7 | 5 | P1 | done |
| 27 | `infrastructure.terraform` | 8 | 11 | P1 | done |
| 28 | `infrastructure.pulumi` | 6 | 9 | P1 | done |
| 29 | `infrastructure.ansible` | 4 | 7 | P1 | done |
| 30 | `package_managers` | 18 | 18 | P1 | done |
| 31 | `database.postgresql` | 7 | 2 | P1 | done |
| 32 | `database.mysql` | 10 | 5 | P1 | done |
| 33 | `database.mongodb` | 5 | 5 | P1 | done |
| 34 | `database.redis` | 13 | 6 | P1 | done |
| 35 | `database.sqlite` | 4 | 4 | P1 | done |
| 36 | `database.supabase` | 18 | 35 | P1 | done |
| 37 | `cicd.github_actions` | 6 | 7 | P1 | done |
| 38 | `cicd.gitlab_ci` | 4 | 7 | P1 | done |
| 39 | `cicd.jenkins` | 6 | 9 | P1 | done |
| 40 | `cicd.circleci` | 6 | 10 | P1 | done |
| 41 | `platform.github` | 16 | 10 | P2 | done |
| 42 | `platform.gitlab` | 11 | 11 | P2 | done |
| 43 | `platform.railway` | 23 | 10 | P2 | done |
| 44 | `platform.modal` | 12 | 14 | P2 | done |
| 45 | `messaging.kafka` | 7 | 9 | P2 | done |
| 46 | `messaging.rabbitmq` | 7 | 6 | P2 | done |
| 47 | `messaging.nats` | 6 | 10 | P2 | done |
| 48 | `messaging.sqs_sns` | 8 | 6 | P2 | done |
| 49 | `search.elasticsearch` | 10 | 6 | P2 | done |
| 50 | `search.opensearch` | 12 | 8 | P2 | done |
| 51 | `search.meilisearch` | 10 | 8 | P2 | done |
| 52 | `search.algolia` | 7 | 4 | P2 | done |
| 53 | `backup.restic` | 5 | 8 | P2 | done |
| 54 | `backup.borg` | 5 | 7 | P2 | done |
| 55 | `backup.rclone` | 7 | 8 | P2 | done |
| 56 | `backup.velero` | 6 | 7 | P2 | done |
| 57 | `dns.cloudflare` | 4 | 3 | P2 | done |
| 58 | `dns.route53` | 6 | 4 | P2 | done |
| 59 | `dns.generic` | 3 | 3 | P2 | done |
| 60 | `loadbalancer.nginx` | 5 | 7 | P2 | done |
| 61 | `loadbalancer.haproxy` | 9 | 5 | P2 | done |
| 62 | `loadbalancer.traefik` | 9 | 6 | P2 | done |
| 63 | `loadbalancer.elb` | 7 | 4 | P2 | done |
| 64 | `monitoring.datadog` | 4 | 3 | P2 | done |
| 65 | `monitoring.pagerduty` | 7 | 4 | P2 | done |
| 66 | `monitoring.prometheus` | 7 | 4 | P2 | done |
| 67 | `monitoring.newrelic` | 6 | 4 | P2 | done |
| 68 | `monitoring.splunk` | 4 | 3 | P2 | done |
| 69 | `payment.stripe` | 7 | 6 | P2 | done |
| 70 | `payment.braintree` | 6 | 3 | P2 | done |
| 71 | `payment.square` | 7 | 3 | P2 | done |
| 72 | `cdn.cloudflare_workers` | 8 | 12 | P3 | done |
| 73 | `cdn.cloudfront` | 7 | 12 | P3 | done |
| 74 | `cdn.fastly` | 11 | 14 | P3 | done |
| 75 | `apigateway.aws` | 18 | 27 | P3 | done |
| 76 | `apigateway.kong` | 11 | 14 | P3 | done |
| 77 | `apigateway.apigee` | 14 | 24 | P3 | done |
| 78 | `featureflags.launchdarkly` | 11 | 18 | P3 | done |
| 79 | `featureflags.split` | 10 | 17 | P3 | done |
| 80 | `featureflags.flipt` | 8 | 18 | P3 | done |
| 81 | `featureflags.unleash` | 9 | 16 | P3 | done |
| 82 | `email.ses` | 10 | 25 | P3 | done |
| 83 | `email.sendgrid` | 8 | 0 | P3 | done |
| 84 | `email.mailgun` | 8 | 0 | P3 | done |
| 85 | `email.postmark` | 7 | 0 | P3 | done |

## Suggested Zig layout (when implementing)

Keep the MVP module shape; grow by pack files rather than one mega-`packs.zig`:

```text
src/shell_engine/
  mod.zig                 # evaluateCommand orchestration (E1–E8)
  tokenize.zig / parse.zig
  allowlist.zig
  packs/
    core_filesystem.zig
    core_git.zig
    strict_git.zig
    system_*.zig
    containers_docker.zig
    ...
  corpus/                 # ported goldens
```

Recover pattern bodies from git while porting:

```bash
git show origin/main:orca-rs/src/packs/containers/docker.rs
git show origin/main:orca-rs/tests/corpus/true_positives/rm_destructive.toml
```

## Acceptance gate for “100% parity”

All must be true:

1. Every row in the 85-pack table is `done`.
2. Engine items E1–E10 are `done`.
3. Ported Rust corpus (≥355 cases) matches decisions at **100%** (not MVP ≥95%).
4. `zig build test-shell-engine` is a dependency of `zig build test` and CI fast + full jobs.
5. Docs (`threat-model.md`, `AGENTS.md`, help text) no longer describe a Rust daemon as the shell authority.
6. Optional: differential fuzzer / replay of historical deny feeds against Zig.

## Progress tracking

| Milestone | Target | Exit criteria |
|-----------|--------|---------------|
| M0 | Engine harden | **done** |
| M1 | Core/system complete | **done** |
| M2 | Agent devops P1 | **done** |
| M3 | P2 categories | **done** |
| M4 | P3 + 100% | **done** (351 cases @ 100%) |

Update this file when a pack merges: change Status, note PR, and tick pattern
tables under P0.