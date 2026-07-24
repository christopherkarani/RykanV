const std = @import("std");

/// Run a test binary in terminal mode (avoiding Zig 0.16 server-mode IPC
/// which hangs with this project's test suite).
/// Link Zig-built static PCRE2 + C shim for shell_engine pack regex matching.
/// Built from source so host/cross targets (linux/darwin amd64+arm64) do not need
/// system libpcre2-dev; Windows native CI can keep using the same path later.
fn addPcre2Shim(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    mod.link_libc = true;
    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");
    mod.linkLibrary(pcre2_lib);
    mod.addIncludePath(b.path("src/shell_engine"));
    // Static PCRE2 requires PCRE2_STATIC for the public header macros on all targets.
    mod.addCSourceFile(.{
        .file = b.path("src/shell_engine/pcre2_shim.c"),
        .flags = &.{ "-std=c99", "-DPCRE2_STATIC" },
    });
}

fn addRunTestTerminal(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const step_name = if (exe.kind == .@"test" and std.mem.eql(u8, exe.name, "test"))
        b.fmt("run {s}", .{@tagName(exe.kind)})
    else
        b.fmt("run {s} {s}", .{ @tagName(exe.kind), exe.name });

    const run_step = std.Build.Step.Run.create(b, step_name);
    run_step.producer = exe;
    if (exe.exec_cmd_args) |exec_cmd_args| {
        for (exec_cmd_args) |cmd_arg| {
            if (cmd_arg) |arg| {
                run_step.addArg(arg);
            } else {
                run_step.addArtifactArg(exe);
            }
        }
    } else {
        run_step.addArtifactArg(exe);
    }
    run_step.stdio = .inherit;
    run_step.setEnvironmentVariable("ORCA_DISABLE_GLOBAL_DASHBOARD_FEED", "1");
    if (b.args) |args| {
        run_step.addArgs(args);
    }
    return run_step;
}

pub fn build(b: *std.Build) void {
    if (b.option(bool, "incremental", "Enable incremental compilation (faster rebuilds)")) |inc| {
        b.graph.incremental = inc;
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_override = b.option([]const u8, "version", "Orca version metadata");
    const version = blk: {
        if (version_override) |v| break :blk v;
        const io = b.graph.io;
        const version_file = std.Io.Dir.cwd().readFileAlloc(io, "VERSION", b.allocator, std.Io.Limit.limited(32)) catch break :blk "1.1.0";
        const trimmed = std.mem.trim(u8, version_file, " \n\r\t");
        const result = b.allocator.dupe(u8, trimmed) catch break :blk "1.1.0";
        b.allocator.free(version_file);
        break :blk result;
    };
    const commit = b.option([]const u8, "commit", "Source commit metadata") orelse "unknown";
    const build_date = b.option([]const u8, "build-date", "UTC build date metadata") orelse "unknown";
    // Zig 0.16: filters are compile-time (passed to `zig test` as --test-filter), not runtime
    // argv on the terminal test runner. Use: ./scripts/zig build test-lib -Dtest-filter=Spinner
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose names contain this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
    build_options.addOption([]const u8, "build_date", build_date);
    const build_options_mod = build_options.createModule();

    const core_schema_documents = b.addOptions();
    core_schema_documents.addOption([]const u8, "policy_v1", @embedFile("schemas/policy-v1.json"));
    core_schema_documents.addOption([]const u8, "event_v1", @embedFile("schemas/event-v1.json"));
    core_schema_documents.addOption([]const u8, "mcp_manifest_v1", @embedFile("schemas/mcp-manifest-v1.json"));
    const core_schema_documents_mod = core_schema_documents.createModule();
    _ = &core_schema_documents_mod;

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize, .external_uucode = true });
    const vaxis_mod = vaxis_dep.module("vaxis");
    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{ "east_asian_width", "grapheme_break", "general_category", "is_emoji_presentation" }),
    });
    vaxis_mod.addImport("uucode", uucode_dep.module("uucode"));

    const orca_core_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/core_engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const orca_core_mod = b.addModule("orca_core", .{
        .root_source_file = b.path("packages/core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_engine", .module = orca_core_engine_mod },
        },
    });

    const orca_mod = b.addModule("orca", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "orca_core", .module = orca_core_mod },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });
    orca_mod.addImport("build_options", build_options_mod);
    orca_mod.addImport("orca", orca_mod);

    const orca_cli_mod = b.addModule("orca_cli", .{
        .root_source_file = b.path("packages/cli/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "orca", .module = orca_mod },
            .{ .name = "orca_core", .module = orca_core_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Primary product binary is `ryk`; legacy `orca` is installed as a same-product alias (Phase 5a).
    // Zig module graph keeps the internal name `orca` — do not rename package imports here.
    const exe = b.addExecutable(.{
        .name = "ryk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.addImport("vaxis", vaxis_mod);
    // Attach once on the lib module (imported by the exe). Linking the same C shim on both
    // exe.root_module and orca_mod duplicates _orca_regex_* symbols at link time.
    addPcre2Shim(b, orca_mod, target, optimize);

    // Primary install name follows exe.name ("ryk"). Legacy "orca" is a second install of the
    // same artifact (compat ≥1 major). Prefer dual install over fragile post-install symlinks
    // so Windows and DESTDIR prefixes stay correct. On Windows, dest_sub_path must keep .exe
    // because InstallArtifact uses it literally (does not re-append the target extension).
    const install_ryk = b.addInstallArtifact(exe, .{});
    const orca_alias_name: []const u8 = if (target.result.os.tag == .windows) "orca.exe" else "orca";
    const install_orca_alias = b.addInstallArtifact(exe, .{
        .dest_sub_path = orca_alias_name,
    });
    b.getInstallStep().dependOn(&install_ryk.step);
    b.getInstallStep().dependOn(&install_orca_alias.step);

    const install_ryk_step = b.step("install-ryk", "Install ryk CLI (primary)");
    install_ryk_step.dependOn(&install_ryk.step);
    install_ryk_step.dependOn(&install_orca_alias.step);
    // Legacy step name kept for scripts/docs that still call `zig build install-orca`.
    const install_orca_step = b.step("install-orca", "Install ryk CLI + orca compat alias (legacy step name)");
    install_orca_step.dependOn(&install_ryk.step);
    install_orca_step.dependOn(&install_orca_alias.step);

    const run_step = b.step("run", "Run the ryk CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = orca_mod,
        .filters = test_filters,
    });
    const run_lib_tests = addRunTestTerminal(b, lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });
    const run_exe_tests = addRunTestTerminal(b, exe_tests);

    const core_package_tests = b.addTest(.{
        .root_module = orca_core_mod,
        .filters = test_filters,
    });
    const run_core_package_tests = addRunTestTerminal(b, core_package_tests);
    // Independent run steps for focused test targets (do not inherit lib test dependency).
    const run_core_package_tests_only = addRunTestTerminal(b, core_package_tests);

    const core_contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/core/tests/contract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca_core", .module = orca_core_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_core_contract_tests = addRunTestTerminal(b, core_contract_tests);
    const run_core_contract_tests_only = addRunTestTerminal(b, core_contract_tests);

    // Domain-sliced test roots: root files live under src/ so relative imports
    // (e.g. sandbox → env_util) stay inside the module path. Avoids full orca facade
    // (cli/tui/vaxis/plugin) for focused agent iteration.
    const sandbox_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sandbox_slice_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca_core", .module = orca_core_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_sandbox_tests = addRunTestTerminal(b, sandbox_tests);

    const intercept_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/intercept_slice_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca_core", .module = orca_core_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_intercept_tests = addRunTestTerminal(b, intercept_tests);

    const shell_engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell_engine_slice_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    addPcre2Shim(b, shell_engine_tests.root_module, target, optimize);
    const run_shell_engine_tests = addRunTestTerminal(b, shell_engine_tests);

    const cli_package_tests = b.addTest(.{
        .root_module = orca_cli_mod,
    });
    const run_cli_package_tests = addRunTestTerminal(b, cli_package_tests);

    const cli_contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/cli/tests/contract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca_cli", .module = orca_cli_mod },
            },
        }),
    });
    const run_cli_contract_tests = addRunTestTerminal(b, cli_contract_tests);

    const phase2d_daemon_hook_matrix_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase2d_daemon_hook_matrix.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase2d_daemon_hook_matrix_tests = addRunTestTerminal(b, phase2d_daemon_hook_matrix_tests);

    const phase2e_hook_dispatch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase2e_hook_dispatch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase2e_hook_dispatch_tests = addRunTestTerminal(b, phase2e_hook_dispatch_tests);

    const phase2f_hook_validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase2f_hook_validation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase2f_hook_validation_tests = addRunTestTerminal(b, phase2f_hook_validation_tests);

    const phase2510_gui_audit_feed_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase2510_gui_audit_feed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase2510_gui_audit_feed_tests = addRunTestTerminal(b, phase2510_gui_audit_feed_tests);

    const phase_zh2_presentation_redaction_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase_zh2_presentation_redaction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase_zh2_presentation_redaction_tests = addRunTestTerminal(b, phase_zh2_presentation_redaction_tests);

    const phase25_hardening_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase25_cli_hardening.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase25_hardening_tests = addRunTestTerminal(b, phase25_hardening_tests);

    const daemon_ipc_hardening_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/daemon_ipc_hardening.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    daemon_ipc_hardening_tests.root_module.link_libc = true;
    const run_daemon_ipc_hardening_tests = addRunTestTerminal(b, daemon_ipc_hardening_tests);

    const phase42_customer_acquisition_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase42_drone_customer_acquisition.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase42_customer_acquisition_tests = addRunTestTerminal(b, phase42_customer_acquisition_tests);

    const phase36_codex_plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase36_codex_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase36_codex_plugin_tests = addRunTestTerminal(b, phase36_codex_plugin_tests);

    const phase37_claude_plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase37_claude_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase37_claude_plugin_tests = addRunTestTerminal(b, phase37_claude_plugin_tests);

    const phase38_plugin_security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase38_plugin_security_and_compatibility.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase38_plugin_security_tests = addRunTestTerminal(b, phase38_plugin_security_tests);

    const phase39_openclaw_plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase39_openclaw_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase39_openclaw_plugin_tests = addRunTestTerminal(b, phase39_openclaw_plugin_tests);

    const phase43_hermes_plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase43_hermes_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase43_hermes_plugin_tests = addRunTestTerminal(b, phase43_hermes_plugin_tests);

    const phase44_version_drift_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase44_version_drift.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase44_version_drift_tests = addRunTestTerminal(b, phase44_version_drift_tests);

    const phase44_setup_opencode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase44_setup_opencode_detection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase44_setup_opencode_tests = addRunTestTerminal(b, phase44_setup_opencode_tests);

    const phase44_install_workspace_paths_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase44_install_workspace_paths.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase44_install_workspace_paths_tests = addRunTestTerminal(b, phase44_install_workspace_paths_tests);

    const phase45_start_onboarding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/phase45_start_onboarding.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_phase45_start_onboarding_tests = addRunTestTerminal(b, phase45_start_onboarding_tests);

    const setup_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/setup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
                .{ .name = "orca_core", .module = orca_core_mod },
            },
        }),
    });
    const run_setup_tests = addRunTestTerminal(b, setup_tests);

    const check_fixture_secrets = b.addSystemCommand(&.{ "bash", "scripts/check-fixture-secrets.sh" });
    check_fixture_secrets.setCwd(b.path("."));
    const check_fixture_secrets_step = b.step("check-fixture-secrets", "Scan fixtures/tests for non-synthetic secret patterns");
    check_fixture_secrets_step.dependOn(&check_fixture_secrets.step);

    const check_step = b.step("check", "Compile Orca CLI only (fastest compile gate)");
    check_step.dependOn(&exe.step);

    const compile_test_lib_step = b.step("compile-test-lib", "Compile orca lib unit tests without running");
    compile_test_lib_step.dependOn(&lib_tests.step);

    // Keep membership identical to `test-fast` (lib + orca_core package + core contract).
    // daemon_ipc_hardening is full-suite only (`test` step), not the fast gate.
    const compile_test_fast_step = b.step("compile-test-fast", "Compile test-fast artifacts without running");
    compile_test_fast_step.dependOn(&lib_tests.step);
    compile_test_fast_step.dependOn(&core_package_tests.step);
    compile_test_fast_step.dependOn(&core_contract_tests.step);

    const test_lib_step = b.step("test-lib", "Run orca lib inline tests only");
    test_lib_step.dependOn(&run_lib_tests.step);

    const test_core_step = b.step("test-core", "Run orca_core package tests only");
    test_core_step.dependOn(&run_core_package_tests_only.step);

    const test_core_contract_step = b.step("test-core-contract", "Run packages/core contract tests only");
    test_core_contract_step.dependOn(&run_core_contract_tests_only.step);

    const test_sandbox_step = b.step("test-sandbox", "Run sandbox domain unit tests only (sliced root)");
    test_sandbox_step.dependOn(&run_sandbox_tests.step);

    // Policy domain: deep `src/policy/*` unit tests currently share Zig 0.16 API debt with
    // core helpers when rooted outside the monopath. Map `test-policy` to the stable
    // orca_core package + contract gates (agent-facing "policy/core" slice).
    const test_policy_step = b.step("test-policy", "Run policy/core package gates (test-core + test-core-contract)");
    test_policy_step.dependOn(&run_core_package_tests_only.step);
    test_policy_step.dependOn(&run_core_contract_tests_only.step);

    const test_intercept_step = b.step("test-intercept", "Run intercept domain unit tests only (sliced root)");
    test_intercept_step.dependOn(&run_intercept_tests.step);

    const test_shell_engine_step = b.step("test-shell-engine", "Run Zig shell_engine unit + 100% oracle corpus parity tests");
    test_shell_engine_step.dependOn(&run_shell_engine_tests.step);

    const compile_test_sandbox_step = b.step("compile-test-sandbox", "Compile sandbox domain tests without running");
    compile_test_sandbox_step.dependOn(&sandbox_tests.step);

    const compile_test_intercept_step = b.step("compile-test-intercept", "Compile intercept domain tests without running");
    compile_test_intercept_step.dependOn(&intercept_tests.step);

    const compile_test_shell_engine_step = b.step("compile-test-shell-engine", "Compile shell_engine tests without running");
    compile_test_shell_engine_step.dependOn(&shell_engine_tests.step);

    // Serialize runs so local `zig build test-fast` does not launch three heavy test
    // binaries at once (parallel runs have hung with no output on some hosts).
    run_core_package_tests.step.dependOn(&run_lib_tests.step);
    run_core_contract_tests.step.dependOn(&run_core_package_tests.step);

    const test_fast_step = b.step("test-fast", "Run fast unit tests (orca lib + orca_core)");
    test_fast_step.dependOn(&run_core_contract_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&check_fixture_secrets.step);
    test_step.dependOn(&run_shell_engine_tests.step);
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_package_tests.step);
    test_step.dependOn(&run_core_contract_tests.step);
    test_step.dependOn(&run_cli_package_tests.step);
    test_step.dependOn(&run_cli_contract_tests.step);
    test_step.dependOn(&run_phase25_hardening_tests.step);
    test_step.dependOn(&run_daemon_ipc_hardening_tests.step);
    test_step.dependOn(&run_phase2d_daemon_hook_matrix_tests.step);
    test_step.dependOn(&run_phase2e_hook_dispatch_tests.step);
    test_step.dependOn(&run_phase2f_hook_validation_tests.step);
    test_step.dependOn(&run_phase2510_gui_audit_feed_tests.step);
    test_step.dependOn(&run_phase_zh2_presentation_redaction_tests.step);
    test_step.dependOn(&run_phase42_customer_acquisition_tests.step);
    test_step.dependOn(&run_phase36_codex_plugin_tests.step);
    test_step.dependOn(&run_phase37_claude_plugin_tests.step);
    test_step.dependOn(&run_phase38_plugin_security_tests.step);
    test_step.dependOn(&run_phase39_openclaw_plugin_tests.step);
    test_step.dependOn(&run_phase43_hermes_plugin_tests.step);
    test_step.dependOn(&run_phase44_version_drift_tests.step);
    test_step.dependOn(&run_phase44_setup_opencode_tests.step);
    test_step.dependOn(&run_phase44_install_workspace_paths_tests.step);
    test_step.dependOn(&run_phase45_start_onboarding_tests.step);
    test_step.dependOn(&run_setup_tests.step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/security_mutation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = orca_mod },
            },
        }),
    });
    const run_fuzz_tests = addRunTestTerminal(b, fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run deterministic security mutation tests");
    fuzz_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const windows_mod = b.addModule("orca-windows-check", .{
        .root_source_file = b.path("src/root.zig"),
        .target = windows_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "orca_core", .module = orca_core_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    // Same as host `orca_mod`: attach once so shell_engine regex links pcre2_shim + static
    // pcre2-8 for the Windows cross compile; do not also link on windows_exe.root_module.
    addPcre2Shim(b, windows_mod, windows_target, optimize);
    const windows_exe = b.addExecutable(.{
        .name = "orca-windows-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = windows_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orca", .module = windows_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    windows_exe.root_module.link_libc = true;
    const check_windows_step = b.step("check-windows", "Compile Orca for Windows without running it");
    check_windows_step.dependOn(&windows_exe.step);
}
