//! Test/module root for sandbox-only gates (module path = src/).
//! Keeps relative imports like sandbox → env_util working without the full ryk facade.
//! Run: ./scripts/zig build test-sandbox

pub const sandbox = @import("sandbox/mod.zig");

test {
    _ = sandbox;
}
