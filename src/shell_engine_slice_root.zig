//! Test/module root for shell_engine-only gates.
//! Run: ./scripts/zig build test-shell-engine

pub const shell_engine = @import("shell_engine/mod.zig");

test {
    _ = shell_engine;
    _ = shell_engine.allowlist;
    _ = shell_engine.registry;
    _ = shell_engine.trace;
    _ = @import("shell_engine/corpus_test.zig");
}
