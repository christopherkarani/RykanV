pub const RykError = error{
    PolicyParseFailed,
    PolicyValidationFailed,
    PolicyNotFound,
    AuditLogUnavailable,
    SandboxUnavailable,
    PermissionDenied,
    UserDenied,
    UnsupportedPlatformFeature,
    InputTooLarge,
    InvalidUtf8,
    InvalidPath,
    InvalidCommand,
    InvalidMCPMessage,
    MCPMessageTooLarge,
    SecretRedactionFailed,
    SessionCreateFailed,
};

test "core error set imports security errors" {
    const err: RykError = error.PermissionDenied;
    try @import("std").testing.expectEqual(error.PermissionDenied, err);
}
