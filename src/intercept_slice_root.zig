//! Test/module root for intercept-only gates (module path = src/).
//! Run: ./scripts/zig build test-intercept

pub const intercept = @import("intercept/mod.zig");

test {
    // Pull domain modules (mod.zig itself has no nested test {} re-export).
    _ = intercept;
    _ = intercept.env;
    _ = intercept.env_schema;
    _ = intercept.credentials;
    _ = intercept.session_secrets;
    _ = intercept.files;
    _ = intercept.commands;
    _ = intercept.network;
    _ = intercept.proxy;
    _ = intercept.provider_gateway;
    _ = intercept.approvals;
}
