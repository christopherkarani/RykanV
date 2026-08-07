# ryk Core C ABI

Status: experimental. This ABI is not stable and is not a supported integration surface yet.

The current skeleton reserves functions for:

- `core_version`
- `core_redact`
- `core_evaluate_policy`
- `core_append_audit_event`

Only `version` and `redact` have useful behavior today. Policy evaluation and audit append return an unsupported result until the serialization, ownership, and compatibility contracts are complete.

## Ownership

Callers own input and output buffers. ryk Core does not allocate memory for the caller or free caller-owned memory. Inputs use pointer-plus-length byte slices, and outputs report the number of bytes written through an output parameter.

## Return codes

- `0`: success
- `-1`: invalid arguments
- `-2`: output buffer too small
- `-3`: input exceeds current limits
- `-9`: reserved function with unsupported behavior
