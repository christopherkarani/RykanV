//! Canonical user-facing daemon error strings.

const std = @import("std");
const onboarding = @import("onboarding.zig");

pub const ProbeContext = enum {
    general,
    doctor,
    version,
};

pub fn shellUnavailableReason(err: anyerror) []const u8 {
    return switch (err) {
        error.HomeDirectoryNotFound => "daemon unavailable: HOME not set",
        error.DaemonBinaryNotFound => "daemon unavailable: orca-daemon binary not found",
        error.DaemonBinaryNotExecutable => "daemon unavailable: orca-daemon is not executable",
        error.DaemonBinaryUntrusted => "daemon unavailable: ORCA_DAEMON points at an untrusted path (group/world-writable, wrong owner, or unstatable)",
        error.DaemonSpawnFailed => "daemon unavailable: failed to spawn orca-daemon",
        error.DaemonStartTimeout => "daemon unavailable: startup timed out",
        error.DaemonNotReady => "daemon unavailable: daemon not ready",
        error.StaleSocket => "daemon unavailable: stale socket artifact",
        error.SocketConnectFailed => "daemon unavailable: socket connect failed",
        error.SocketWriteFailed => "daemon unavailable: socket write failed",
        error.SocketReadFailed => "daemon unavailable: socket read failed",
        error.InvalidWorkingDirectory => "daemon unavailable: command working directory does not exist",
        error.RequestSerializationFailed => "daemon unavailable: request serialization failed",
        error.ResponseParseFailed => "daemon unavailable: malformed daemon response",
        error.DaemonProtocolError => "daemon unavailable: protocol error",
        error.MissingHandshake => "daemon unavailable: missing protocol handshake",
        error.HandshakeMalformed => "daemon unavailable: malformed protocol handshake",
        error.ProtocolMismatch => "daemon unavailable: incompatible daemon protocol",
        error.RustShellEvalRemoved => "ORCA_SHELL_EVAL=rust is no longer supported; Zig shell_engine is the sole Evaluate authority",
        error.OutOfMemory => "daemon unavailable: out of memory",
        else => "daemon unavailable: unexpected error",
    };
}

pub fn doctorProbeDetail(err: anyerror) []const u8 {
    return detail(err, .doctor, .doctor);
}

pub fn onboardingDetail(err: anyerror) []const u8 {
    return detail(err, .onboarding, .general);
}

pub fn versionProbeDetail(err: anyerror) []const u8 {
    return detail(err, .version, .version);
}

pub fn proxyCategoryLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.HomeDirectoryNotFound,
        error.DaemonBinaryNotFound,
        error.DaemonBinaryNotExecutable,
        error.DaemonBinaryUntrusted,
        error.DaemonSpawnFailed,
        error.DaemonStartTimeout,
        error.DaemonNotReady,
        error.StaleSocket,
        error.SocketConnectFailed,
        => "daemon unavailable",
        error.SocketReadFailed,
        error.SocketWriteFailed,
        => "daemon communication failed",
        error.RequestSerializationFailed,
        error.ResponseParseFailed,
        error.DaemonProtocolError,
        error.MissingHandshake,
        error.HandshakeMalformed,
        error.ProtocolMismatch,
        => "daemon protocol error",
        error.OutOfMemory => "out of memory",
        else => "daemon proxy failed",
    };
}

pub fn doctorHealthStatus(err: anyerror) onboarding.DaemonHealthStatus {
    return if (err == error.ProtocolMismatch)
        .incompatible
    else if (err == error.MissingHandshake or err == error.HandshakeMalformed or err == error.DaemonProtocolError or err == error.ResponseParseFailed)
        .degraded
    else
        .unavailable;
}

fn detail(err: anyerror, audience: Audience, probe: ProbeContext) []const u8 {
    return switch (err) {
        error.HomeDirectoryNotFound => switch (audience) {
            .doctor => "HOME is not set; daemon runtime path is unavailable.",
            .onboarding => "HOME is not set.",
            .version => "HOME is not set; daemon runtime path is unavailable.",
        },
        error.DaemonBinaryNotFound => switch (audience) {
            .doctor => "orca-daemon binary not found; build or install the companion daemon.",
            .onboarding => "orca-daemon binary was not found.",
            .version => "orca-daemon binary not found beside orca or via ORCA_DAEMON.",
        },
        error.DaemonBinaryNotExecutable => switch (audience) {
            .doctor => "orca-daemon exists but is not executable; restore execute permission or reinstall the matching release.",
            .onboarding => "orca-daemon is not executable.",
            .version => "orca-daemon was found but is not executable.",
        },
        error.DaemonBinaryUntrusted => switch (audience) {
            .doctor => "ORCA_DAEMON points at an untrusted path (group/world-writable binary or ancestor, owner not euid/root, or unstatable); unset it or choose a trusted orca-daemon binary. Safe symlinks (e.g. Homebrew) are allowed when the target is trusted.",
            .onboarding => "ORCA_DAEMON points at an untrusted path.",
            .version => "ORCA_DAEMON points at an untrusted path.",
        },
        error.DaemonSpawnFailed => switch (audience) {
            .doctor => "orca-daemon failed to start; inspect local build/install state.",
            .onboarding => "Failed to start orca-daemon.",
            .version => "orca-daemon failed to start; verify the installed daemon matches this OS/architecture.",
        },
        error.DaemonStartTimeout => switch (audience) {
            .doctor => "orca-daemon startup timed out; verify socket cleanup and local process health.",
            .onboarding => "Timed out waiting for orca-daemon.",
            .version => "orca-daemon startup timed out while waiting for the socket handshake.",
        },
        error.DaemonNotReady => switch (audience) {
            .doctor => "daemon runtime exists but is not ready to answer requests.",
            .onboarding => "orca-daemon is not ready.",
            .version => "daemon runtime exists but is not ready to answer requests.",
        },
        error.StaleSocket => switch (audience) {
            .doctor => "daemon runtime contains stale socket artifacts.",
            .onboarding => "Stale daemon socket artifact detected.",
            .version => "daemon runtime contains stale socket artifacts.",
        },
        error.SocketConnectFailed => switch (audience) {
            .doctor => "no running daemon answered on the expected socket.",
            .onboarding => "Could not connect to orca-daemon socket.",
            .version => "no running daemon answered on the expected socket.",
        },
        error.SocketWriteFailed => switch (audience) {
            .doctor => "daemon socket accepted a connection but did not accept the request cleanly.",
            .onboarding => "Could not verify orca-daemon health.",
            .version => "daemon socket accepted a connection but did not accept the request cleanly.",
        },
        error.SocketReadFailed => switch (audience) {
            .doctor => "daemon socket accepted a connection but did not return a response in time.",
            .onboarding => "Could not verify orca-daemon health.",
            .version => "daemon socket accepted a connection but did not return a response in time.",
        },
        error.RequestSerializationFailed => switch (probe) {
            .doctor => "failed to serialize the daemon health probe request.",
            .version => "failed to serialize the daemon version request.",
            .general => "request serialization failed",
        },
        error.ResponseParseFailed => switch (probe) {
            .doctor => "daemon returned malformed JSON for the health probe.",
            .version => "daemon returned malformed JSON for the version request.",
            .general => "malformed daemon response",
        },
        error.DaemonProtocolError => switch (probe) {
            .doctor => "daemon answered, but the health probe payload was not a valid Pong handshake.",
            .version => "daemon answered, but the version request payload was not valid.",
            .general => "protocol error",
        },
        error.MissingHandshake => switch (audience) {
            .doctor => "daemon answered Ping without the required protocol handshake fields.",
            .onboarding => "Daemon did not return a protocol handshake.",
            .version => "daemon answered Ping without the required protocol handshake fields.",
        },
        error.HandshakeMalformed => switch (audience) {
            .doctor => "daemon handshake fields were present but malformed.",
            .onboarding => "Daemon handshake was malformed.",
            .version => "daemon handshake fields were present but malformed.",
        },
        error.ProtocolMismatch => switch (audience) {
            .doctor => "daemon protocol version or capability set does not match this ryk CLI.",
            .onboarding => "Protocol version mismatch between orca and orca-daemon.",
            .version => "daemon protocol version or capability set does not match this ryk CLI.",
        },
        error.OutOfMemory => switch (audience) {
            .doctor => "out of memory while probing daemon compatibility.",
            .onboarding => "Could not verify orca-daemon health.",
            .version => "out of memory while probing daemon version.",
        },
        else => switch (audience) {
            .doctor => "unexpected daemon health error",
            .onboarding => "Could not verify orca-daemon health.",
            .version => "unexpected daemon version error",
        },
    };
}

const Audience = enum {
    doctor,
    onboarding,
    version,
};