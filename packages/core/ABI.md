# ryk Core C ABI

Status: experimental. This ABI is not stable v1.

Phase 24 reserves a small C ABI skeleton for future bindings:

- `core_version`
- `core_redact`
- `core_evaluate_policy`
- `core_append_audit_event`

Only `version` and `redact` provide useful skeleton behavior in Phase 24. Policy evaluation and audit append return an unsupported skeleton code until a later phase defines tested serialization and ownership contracts for those calls.

## Ownership

Callers own all input and output buffers. ryk Core does not allocate memory for the caller and never frees caller memory.

Inputs are pointer-plus-length byte slices. Outputs are written into caller-provided buffers and report the number of bytes written through an output parameter.

## Limits

String inputs must be UTF-8 where the underlying Core API requires UTF-8. Event-field-sized inputs must not exceed ryk Core runtime limits.

## Return Codes

- `0`: success
- `-1`: invalid arguments, including required null pointers
- `-2`: output buffer too small
- `-3`: input exceeds current Core limits
- `-9`: function name reserved, but behavior unsupported in this experimental skeleton

## Scope

This ABI does not implement mobile bindings, embedded bindings, MAVLink, PX4, ArduPilot, real drone hardware access, or real-flight command enforcement.
