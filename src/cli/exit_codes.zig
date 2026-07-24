pub const success: u8 = 0;
pub const general: u8 = 1;
pub const usage: u8 = 2;
pub const denial: u8 = 3;
pub const unsupported: u8 = 4;
pub const child_failure: u8 = 5;
pub const redteam_failure: u8 = 6;
/// `ryk decide` ask outcome (non-interactive hosts should read JSON on stdout).
pub const ask: u8 = 7;
/// `ryk decide` warn / redact outcome.
pub const warn: u8 = 8;
