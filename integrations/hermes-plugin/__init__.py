"""Hermes Agent plugin bridge for ryk runtime guardrails."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _load_mapping() -> Any:
    """Load pure mapping helpers as package submodule or sibling file."""
    try:
        from . import mapping as mapping_mod  # type: ignore[attr-defined]

        return mapping_mod
    except ImportError:
        import importlib.util

        path = Path(__file__).resolve().with_name("mapping.py")
        spec = importlib.util.spec_from_file_location("orca_hermes_mapping", path)
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod


_mapping = _load_mapping()


SECRET_KEYS = (
    "password",
    "token",
    "secret",
    "api_key",
    "apikey",
    "api_secret",
    "auth",
    "authorization",
    "bearer",
    "private_key",
    "access_token",
    "refresh_token",
    "credential",
    "passwd",
    "pwd",
)

POLICY_EVENTS = {"pre_tool_call", "pre_llm_call"}
EVENTS = (
    "on_session_start",
    "pre_tool_call",
    "post_tool_call",
    "pre_llm_call",
    "post_llm_call",
    "on_session_end",
    "on_session_finalize",
    "on_session_reset",
    "subagent_stop",
)

_HERMES_HOST_MISMATCH_MARKERS = (
    "unknown host 'hermes'",
    "Expected codex or claude.",
)
_PRE_TOOL_CALL_DEGRADED_MARKERS = _HERMES_HOST_MISMATCH_MARKERS + (
    "too old for Hermes hooks",
    "does not support Hermes hooks",
    "not found or too old for Hermes hooks",
)
_HERMES_SMOKE_PAYLOAD = json.dumps(
    {
        "version": 1,
        "host": "hermes",
        "event": "pre_tool_call",
        "payload": {"command": "git status"},
        "timestamp": "1970-01-01T00:00:00Z",
    },
    separators=(",", ":"),
)

_orca_cache_env: str | None = None
_orca_cache_path: str | None = None


_FAIL_STANCE_FILENAMES = (".orca_fail_stance", "ORCA_FAIL_STANCE")
_FAIL_CLOSED_TOKENS = frozenset({"0", "false", "no", "off", "fail-closed", "closed"})
_FAIL_OPEN_TOKENS = frozenset({"1", "true", "yes", "on", "fail-open", "open"})


def _parse_fail_open_token(raw: str) -> bool | None:
    token = raw.strip().lower()
    if not token:
        return None
    if token in _FAIL_CLOSED_TOKENS:
        return False
    if token in _FAIL_OPEN_TOKENS:
        return True
    return None


def _stance_file_fail_open() -> bool | None:
    """Read install-time stance next to this plugin (written for *new* ryk plugin install hermes)."""
    base = Path(__file__).resolve().parent
    for name in _FAIL_STANCE_FILENAMES:
        path = base / name
        try:
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parsed = _parse_fail_open_token(stripped)
            if parsed is not None:
                return parsed
    return None


def _fail_open_enabled() -> bool:
    """Allow Hermes to proceed without ryk when degraded.

    Precedence: RYK_HERMES_FAIL_OPEN then ORCA_HERMES_FAIL_OPEN env (when set) →
    install stance file → product default fail-open.
    New installs via `ryk plugin install hermes` write `.orca_fail_stance` = fail-closed.
    """
    # Dual-read brand env (prefer RYK_ then ORCA_) — doctor/formatFix copy matches.
    for key in ("RYK_HERMES_FAIL_OPEN", "ORCA_HERMES_FAIL_OPEN"):
        if key in os.environ:
            value = os.environ.get(key, "").strip().lower()
            if value:
                return value not in _FAIL_CLOSED_TOKENS
    stance = _stance_file_fail_open()
    if stance is not None:
        return stance
    return True


def _redact(value: Any) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            if any(secret in str(key).lower() for secret in SECRET_KEYS):
                result[key] = "[REDACTED]"
            else:
                result[key] = _redact(item)
        return result
    if isinstance(value, list):
        return [_redact(item) for item in value]
    return value


def _error_has_marker(error: BaseException, markers: tuple[str, ...]) -> bool:
    message = str(error)
    return any(marker in message for marker in markers)


def _is_degraded_orca_error(error: BaseException) -> bool:
    if isinstance(error, OSError):
        return True
    return _error_has_marker(error, _PRE_TOOL_CALL_DEGRADED_MARKERS)


def _hook_smoke_passes(stdout: str) -> bool:
    """Lenient probe: exit 0 and decision is not block (matches install scripts)."""
    trimmed = stdout.strip()
    if not trimmed:
        return True
    try:
        parsed = json.loads(trimmed)
    except json.JSONDecodeError:
        return False
    if not isinstance(parsed, dict):
        return False
    return parsed.get("decision", "allow") != "block"


def _orca_executable(candidate: str) -> str | None:
    try:
        path = Path(candidate).resolve()
    except OSError:
        return None
    if not path.is_file() or not os.access(path, os.X_OK):
        return None
    return str(path)


def _supports_hermes_host(orca: str) -> bool:
    try:
        completed = subprocess.run(
            [orca, "hook", "hermes", "pre_tool_call"],
            input=_HERMES_SMOKE_PAYLOAD,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except OSError:
        return False
    if completed.returncode != 0:
        return False
    return _hook_smoke_passes(completed.stdout)


def _orca_candidates() -> list[str]:
    candidates: list[str] = []
    # Phase 5a dual-read: prefer RYK_BIN then ORCA_BIN.
    for env_key in ("RYK_BIN", "ORCA_BIN"):
        configured = os.environ.get(env_key)
        if configured:
            resolved = _orca_executable(configured)
            if resolved:
                candidates.append(resolved)

    # Trusted installs and PATH before cwd zig-out (F10): a planted
    # ./zig-out/bin/ryk must not beat ~/.local/bin or PATH when both exist.
    home = Path.home()
    for name in ("ryk", "orca"):
        for path in (home / ".local" / "bin" / name, home / ".orca" / "bin" / name, home / ".ryk" / "bin" / name):
            resolved = _orca_executable(str(path))
            if resolved:
                candidates.append(resolved)

    for name in ("ryk", "orca"):
        found = shutil.which(name)
        if found:
            resolved = _orca_executable(found)
            if resolved:
                candidates.append(resolved)

    # Dev tree last: only used when no install/PATH hit exists.
    directory = Path.cwd()
    for _ in range(3):
        for name in ("ryk", "orca"):
            zig_out = directory / "zig-out" / "bin" / name
            resolved = _orca_executable(str(zig_out))
            if resolved:
                candidates.append(resolved)
        if directory.parent == directory:
            break
        directory = directory.parent

    deduped: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            deduped.append(candidate)
    return deduped


def _find_orca() -> str | None:
    global _orca_cache_env, _orca_cache_path
    # Cache key tracks both brand env vars.
    env_bin = os.environ.get("RYK_BIN") or os.environ.get("ORCA_BIN")
    if _orca_cache_path is not None and _orca_cache_env == env_bin:
        return _orca_cache_path

    for candidate in _orca_candidates():
        try:
            if _supports_hermes_host(candidate):
                _orca_cache_env = env_bin
                _orca_cache_path = candidate
                return candidate
        except OSError:
            continue
    return None


def _warn_degraded(ctx: Any, event: str, message: str) -> None:
    """Always surface degraded-path warnings — never silent fail-open."""
    full = f"[ryk-hermes] {message}"
    logger = getattr(ctx, "logger", None)
    if logger and hasattr(logger, "warning"):
        logger.warning(full)
    # Also print so non-logger hosts and CI logs always see the stance.
    print(f"warning: {full}", flush=True)


def _handle_hook_error(ctx: Any, event: str, exc: BaseException) -> Any:
    if event == "pre_tool_call" and _is_degraded_orca_error(exc):
        if not _fail_open_enabled():
            return {
                "action": "block",
                "message": (
                    f"ryk unavailable for Hermes pre_tool_call: {exc} "
                    "(set ORCA_HERMES_FAIL_OPEN=1 to allow without guardrails)"
                ),
            }
        _warn_degraded(
            ctx,
            event,
            "FAIL-OPEN: ryk is missing or too old for Hermes hooks; upgrade ryk or set RYK_BIN. "
            "Allowing tool call WITHOUT ryk guardrails. "
            "Set ORCA_HERMES_FAIL_OPEN=0 to block, or use `ryk run -- hermes`.",
        )
        return None
    if event == "pre_tool_call":
        return {
            "action": "block",
            "message": f"ryk unavailable for Hermes pre_tool_call: {exc}",
        }
    if _error_has_marker(exc, _HERMES_HOST_MISMATCH_MARKERS):
        _warn_degraded(
            ctx,
            event,
            "FAIL-OPEN: ryk is too old for Hermes hooks; upgrade ryk or set RYK_BIN. "
            "Continuing without ryk guardrails for this event.",
        )
        return None
    logger = getattr(ctx, "logger", None)
    if logger and hasattr(logger, "warning"):
        logger.warning("ryk Hermes hook failed for %s: %s", event, exc)
    else:
        print(f"warning: [ryk-hermes] hook failed for {event}: {exc}", flush=True)
    return None


def _event_payload(event: str, hook_args: tuple[Any, ...], hook_kwargs: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "hook_event_name": event,
        "args": hook_args,
        "kwargs": hook_kwargs,
        "extra": dict(hook_kwargs),
    }

    if event in {"pre_tool_call", "post_tool_call"}:
        if "tool_name" in hook_kwargs:
            payload["tool_name"] = hook_kwargs["tool_name"]
        elif len(hook_args) > 0:
            payload["tool_name"] = hook_args[0]

        if "args" in hook_kwargs:
            payload["tool_input"] = hook_kwargs["args"]
        elif "params" in hook_kwargs:
            payload["tool_input"] = hook_kwargs["params"]
        elif len(hook_args) > 1:
            payload["tool_input"] = hook_args[1]

    if event in {"pre_llm_call", "post_llm_call"}:
        for key in ("session_id", "user_message", "conversation_history", "model", "platform"):
            if key in hook_kwargs:
                payload[key] = hook_kwargs[key]
        if "user_message" not in payload and len(hook_args) > 1:
            payload["user_message"] = hook_args[1]

    return payload


def _payload(event: str, data: Any) -> str:
    return json.dumps(
        {
            "version": 1,
            "host": "hermes",
            "event": event,
            "payload": _redact(data),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        separators=(",", ":"),
    )


def _call_orca(event: str, data: Any) -> dict[str, Any]:
    orca = _find_orca()
    if not orca:
        raise RuntimeError(
            "ryk binary not found or too old for Hermes hooks. "
            "Install ryk or set RYK_BIN to an absolute executable path."
        )

    try:
        completed = subprocess.run(
            [orca, "hook", "hermes", event],
            input=_payload(event, data),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15 if event in POLICY_EVENTS else 10,
            check=False,
        )
    except OSError as exc:
        raise RuntimeError(f"failed to run ryk at {orca}: {exc}") from exc
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"ryk exited {completed.returncode}")
    if not completed.stdout.strip():
        return {"decision": "allow"}
    return json.loads(completed.stdout)


def _log_policy_warn(ctx: Any, message: str) -> None:
    """Surface an advisory policy warn — not a degraded/fail-open path."""
    full = f"[ryk-hermes] {message}"
    logger = getattr(ctx, "logger", None)
    if logger and hasattr(logger, "warning"):
        logger.warning(full)
    print(f"warning: {full}", flush=True)


# Re-export pure mapping helpers for tests and external callers.
_ci_mode = _mapping.ci_mode
_stable_rule_key = _mapping.stable_rule_key
_format_tool_message = _mapping.format_tool_message
_map_pre_llm_call = _mapping.map_pre_llm_call


def _map_pre_tool_call(
    ctx: Any,
    response: dict[str, Any],
    tool_name: str,
    tool_input: Any,
) -> Any:
    return _mapping.map_pre_tool_call(
        response,
        tool_name,
        tool_input,
        log_warn=lambda msg: _log_policy_warn(ctx, msg),
    )


def _register(ctx: Any, event: str) -> None:
    def handler(*args: Any, **kwargs: Any) -> Any:
        payload = _event_payload(event, args, kwargs)
        try:
            response = _call_orca(event, payload)
        except (RuntimeError, json.JSONDecodeError, subprocess.SubprocessError, OSError) as exc:
            return _handle_hook_error(ctx, event, exc)

        if event == "pre_tool_call":
            tool_name = str(payload.get("tool_name") or kwargs.get("tool_name") or "")
            tool_input = payload.get("tool_input")
            if tool_input is None:
                tool_input = kwargs.get("args") or kwargs.get("params") or {}
            return _map_pre_tool_call(ctx, response, tool_name, tool_input)
        if event == "pre_llm_call":
            return _map_pre_llm_call(response)
        return None

    ctx.register_hook(event, handler)


def register(ctx: Any) -> None:
    for event in EVENTS:
        _register(ctx, event)
