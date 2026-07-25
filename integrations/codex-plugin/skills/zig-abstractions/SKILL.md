---
name: zig-abstractions
description: Pragmatic Zig abstraction-design workflow for coding agents. Use when designing, reviewing, simplifying, or refactoring Zig APIs that use comptime generics, type-returning functions, structural duck typing, error unions, optionals, tagged unions, function pointers, vtables, interface-like structs, allocator or IO dependencies, public contracts, test seams, or Zig 0.15/0.16 abstraction and std.Io migration tradeoffs.
---

# Zig Abstractions

## Operating Mode

Use this skill to keep Zig APIs concrete until abstraction earns its cost. First verify the project version:

```bash
zig version
test -f build.zig.zon && sed -n '1,120p' build.zig.zon
```

Default to the repo-pinned Zig version. As of 2026-05-13, upstream stable is Zig `0.16.0`, but ryk-style repos may still target `0.15.2`; mark 0.16-only patterns as migration notes.

## Decision Rule

Prefer concrete structs and functions first. Add an abstraction only when at least one is true:

- There are two or more real call sites with the same stable contract.
- Tests need to substitute behavior at a boundary that cannot be tested cleanly otherwise.
- The abstraction removes meaningful duplication without hiding allocation, errors, ownership, or control flow.
- The public API is more stable with a small explicit contract than with leaking internal implementation types.

If a proposed abstraction mainly creates names like `Manager`, `Context`, `Value`, `Data`, or `utils`, simplify it.

## Comptime Generics

- Use `comptime T: type` for type-parametric algorithms and type factories.
- Keep constraints close to use sites with `@hasDecl`, `@hasField`, `@typeInfo`, and clear `@compileError` messages.
- Prefer a small generic helper over a trait framework when the helper has one job.
- Avoid exporting broad comptime-heavy APIs unless compile-time configuration is the product value.
- Test at least two concrete type instantiations when behavior depends on type shape.

Zig generics are compile-time duck typing: the actual contract is the operations the generic code performs. Document non-obvious expected declarations in comments or tests.

## Errors And Optionals

- Use `?T` for absence and `E!T` for failure.
- Use explicit error sets at public boundaries when callers, function pointers, or stable tests need predictable contracts.
- Use inferred error sets internally when they reduce boilerplate and do not leak into public API.
- Prefer `try`, `if (opt) |value|`, `orelse`, and `catch |err| switch` over sentinel values and unchecked unwraps.
- Keep error names domain-specific enough for callers to act on them.

## Tagged Unions

- Use `union(enum)` for closed variants: commands, policy decisions, parser results, state machines, and protocol messages.
- Require exhaustive `switch` handling when adding variants.
- Store payload ownership explicitly. A union variant carrying an owned slice still needs a clear deinit path.
- Avoid stringly typed variants when schema/API stability matters.

## Interfaces And Vtables

- Prefer comptime generics when implementation can be selected statically and call sites are few.
- Use explicit structs with function pointers only when runtime polymorphism is necessary.
- Keep vtable-like contracts small. Include userdata/lifetime/allocator ownership in the type, not in hidden global state.
- Avoid mixing dynamic dispatch and hidden allocation in the same boundary.
- In Zig `0.16.0`, `std.Io` is the standard-library direction for interface-style I/O. Do not backport `std.Io` examples into `0.15.x` code unless the task is a migration.

## Allocation And Ownership

- Make allocator parameters explicit at the boundary that may allocate.
- Prefer caller-owned buffers for hot paths, parsers, and security-sensitive code.
- Document returned memory as owned or borrowed.
- Keep allocation out of abstractions whose names imply pure formatting, validation, classification, or lookup.
- Make deinit responsibilities testable.

## API Boundary Checklist

- Public types are small, named for the domain, and do not expose avoidable stdlib version churn.
- Generic parameters are minimal and have obvious purpose.
- Allocation, I/O, time, randomness, filesystem, and process dependencies are explicit.
- Error sets are stable where callers need to switch on them.
- Ownership of slices, handles, iterators, and parsed data is visible from function names, docs, or tests.
- The abstraction can be tested without duplicating implementation details.

## Verification

For each new abstraction, add tests for:

- One normal concrete implementation.
- One alternate implementation or type shape if the abstraction claims generality.
- One invalid input, invalid shape, or error-path case.
- One ownership or lifetime boundary when allocation is involved.

Then run the repo lane:

```bash
zig build test --summary all
```

## 0.15 to 0.16 Drift

- `std.Io` introduces official interface-style I/O patterns in `0.16.0`.
- `GenericReader`, `AnyReader`, and `FixedBufferStream` were removed in the 0.16 I/O migration.
- `@Type` was replaced by specific type-creating builtins; broad type-reification abstractions need review.
- Container APIs continue moving toward unmanaged forms; do not hide allocator ownership behind compatibility wrappers without tests.

## Source Refresh

Refresh primary sources before version-sensitive guidance:

- `https://ziglang.org/documentation/0.15.2/`
- `https://ziglang.org/documentation/0.16.0/`
- `https://ziglang.org/download/0.16.0/release-notes.html`
- `https://ziglang.org/learn/overview/`
