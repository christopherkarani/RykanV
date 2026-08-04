#!/usr/bin/env bash
set -euo pipefail

# First-user / curl-door regression (D86) for w1-install-handoff.
# Executes scripts/install.sh against a mock product binary. After co-migration
# the primary post-binary door is `"$DESTINATION" doctor --fix --from-install`.
# When the mock advertises doctor --fix, start --auto is poison (must not green).
# A separate legacy section proves pre-W1 binaries fall back to start --auto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"

fail() {
  printf 'install-first-user-regression: %s\n' "$1" >&2
  exit 1
}

# D06 full-protection forbid-list (case-insensitive). Soft / partial success
# receipts and install step copy must never claim these.
assert_no_d06_full_protection() {
  local text="$1"
  local label="${2:-output}"
  if printf '%s\n' "${text}" | grep -Eiq \
    'fully protected|all hosts wired|protection complete|full protection'; then
    fail "${label} claimed a D06 full-protection phrase"
  fi
}

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) fail "unsupported host OS" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) fail "unsupported host architecture" ;;
esac

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/ryk-first-user.XXXXXX")"
# macOS commonly exposes /var as a system symlink to /private/var. Exercise the
# installer with the physical test path so only test-created symlinks are in
# scope for the rejection cases.
tmp_root="$(cd "${tmp_root}" && pwd -P)"
cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM

home="${tmp_root}/home"
escaped="${tmp_root}/escaped"
install_dir="${home}/bin \$(touch PATH_INJECTION)"
share_dir="${home}/share \$(touch RESOURCE_INJECTION)"
artifact_dir="${tmp_root}/artifacts"
release_root="${tmp_root}/orca-v${VERSION}-${os}-${arch}"
artifact="orca-v${VERSION}-${os}-${arch}.tar.gz"
mkdir -p "${home}" "${artifact_dir}" "${release_root}/bin"

for dir in integrations fixtures schemas policies orca-pi; do
  mkdir -p "${release_root}/${dir}"
  printf 'fixture\n' > "${release_root}/${dir}/fixture.txt"
done

# Mock product binary installed as ryk (or orca compat). Implements doctor for
# the W1 ensure door; start is poison so restoring start --auto cannot green
# when doctor --fix is advertised. doctor --help must list --fix so the
# installer's capability probe selects the W1 door (not legacy start --auto).
cat > "${release_root}/bin/orca" <<'EOF'
#!/usr/bin/env sh
# Log door line + trust-scope env for the first-user harness.
# Door line for doctor is "doctor <first-flag>" so count gate can use
# grep -c '^doctor --fix$'. Help probes must not count as the ensure door.
log_scope() {
  door_line="$1"
  shift
  printf '%s\n' "${door_line}" >> "${RYK_TEST_ONBOARD_LOG:?}"
  printf 'cwd=%s\n' "$PWD" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'ryk_resource=%s\n' "${RYK_RESOURCE_ROOT:-}" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'resource=%s\n' "${ORCA_RESOURCE_ROOT:-}" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'path=%s\n' "${PATH:-}" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'argv=' >> "${RYK_TEST_ONBOARD_LOG}"
  first=1
  for a in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf '%s' "$a" >> "${RYK_TEST_ONBOARD_LOG}"
      first=0
    else
      printf ' %s' "$a" >> "${RYK_TEST_ONBOARD_LOG}"
    fi
  done
  printf '\n' >> "${RYK_TEST_ONBOARD_LOG}"
}

case "${1:-}" in
  doctor)
    # Capability probe (install.sh cli_supports_doctor_fix): do not log help.
    if [ "${2:-}" = "--help" ] || [ "${2:-}" = "-h" ]; then
      printf 'Usage:\n  ryk doctor [-v|--verbose] [--check] [--json] [--fix] [--from-install]\n'
      printf 'Examples:\n  ryk doctor --fix\n'
      exit 0
    fi
    # Anchored door line uses $2 (expected --fix). Optional further flags
    # (--from-install, --preset) are recorded on the argv= line only.
    log_scope "doctor${2:+ $2}" "$@"
    if [ "${RYK_TEST_DOCTOR_EXIT:-0}" -ne 0 ]; then
      printf 'mock doctor: forced failure (exit %s)\n' "${RYK_TEST_DOCTOR_EXIT}" >&2
      exit "${RYK_TEST_DOCTOR_EXIT}"
    fi
    if [ "${RYK_TEST_DOCTOR_PARTIAL:-0}" = "1" ]; then
      # Soft host-fail honesty: exit 0, partial label, teach doctor --fix.
      # Must not emit D06 full-protection phrases.
      printf 'ryk ensure: protection partial — some hosts incomplete or none detected.\n'
      printf 'host mock-host: incomplete — ryk doctor --fix\n'
      exit 0
    fi
    printf 'ryk ensure: core ready (mock)\n'
    ;;
  start)
    # Poison path: log and fail so install.sh cannot green via start --auto
    # when the W1 doctor --fix door is available.
    log_scope "start${2:+ $2}" "$@"
    if [ "${RYK_TEST_START_EXIT:-99}" -ne 0 ]; then
      printf 'mock start: forbidden install door (exit %s)\n' "${RYK_TEST_START_EXIT:-99}" >&2
      exit "${RYK_TEST_START_EXIT:-99}"
    fi
    printf "You're now protected by ryk\n"
    ;;
  env|--print-install-env)
    printf 'export ORCA_FIRST_USER_ACTIVATED=1\n'
    ;;
  version|--version)
    printf 'orca 0.0.0\n'
    ;;
esac
EOF
chmod +x "${release_root}/bin/orca"
tar -czf "${artifact_dir}/${artifact}" -C "${tmp_root}" "$(basename "${release_root}")"
if command -v sha256sum >/dev/null 2>&1; then
  checksum="$(sha256sum "${artifact_dir}/${artifact}" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "${artifact_dir}/${artifact}" | awk '{print $1}')"
fi
printf '%s  %s\n' "${checksum}" "${artifact}" > "${artifact_dir}/checksums.txt"

onboard_log="${tmp_root}/onboard.log"
# Real upgrades may still have the Phase 5a markers. The new installer must
# migrate them rather than append a second managed block.
cat > "${home}/.profile" <<EOF
# Added by Orca installer
export PATH='/legacy/ryk/bin':"\$PATH"

# Orca runtime assets
export ORCA_RESOURCE_ROOT='/legacy/ryk/share'
EOF

# ── Non-TTY install: doctor --fix once under HOME + resource roots (D86) ──
output="$(
  HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  ORCA_RESOURCE_ROOT="${escaped}" \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  sh "${INSTALL_SH}"
)"

# Captured stdout is intentionally non-TTY. Setup must still be automatic via
# doctor --fix (ensure door). start --auto must not appear.
[[ "$(grep -c '^doctor --fix$' "${onboard_log}")" == 1 ]] ||
  fail "non-TTY install did not run doctor --fix exactly once (got: $(grep -c '^doctor --fix$' "${onboard_log}" 2>/dev/null || echo 0); log=$(cat "${onboard_log}" 2>/dev/null || true))"
[[ "$(grep -c '^start --auto$' "${onboard_log}")" == 0 ]] ||
  fail "install still invoked start --auto (forbidden; restore is not a green path)"
[[ "$(grep -c '^start' "${onboard_log}")" == 0 ]] ||
  fail "install invoked start door (forbidden after w1-install-handoff)"
# Install-scope flag must ride with the doctor --fix door (D32).
grep -qE '^argv=doctor --fix --from-install' "${onboard_log}" ||
  fail "onboarding argv missing --from-install (got: $(grep '^argv=' "${onboard_log}" 2>/dev/null || true))"

actual_onboard_cwd="$(sed -n 's/^cwd=//p' "${onboard_log}" | head -n 1)"
[[ -n "${actual_onboard_cwd}" && "${actual_onboard_cwd}" -ef "${home}" ]] ||
  fail "onboarding did not run from the global HOME scope (cwd=${actual_onboard_cwd})"
grep -qF "resource=${share_dir}/current" "${onboard_log}" ||
  fail "onboarding did not receive ORCA_RESOURCE_ROOT at installed resource root"
grep -qF "ryk_resource=${share_dir}/current" "${onboard_log}" ||
  fail "onboarding did not receive RYK_RESOURCE_ROOT at installed resource root"
grep -qF "${install_dir}" "${onboard_log}" ||
  fail "onboarding PATH did not contain the installed binary directory"

# Reinstalling must update the managed blocks instead of appending duplicates.
HOME="${home}" \
SHELL=/bin/sh \
ORCA_VERSION="${VERSION}" \
ORCA_ARTIFACT_DIR="${artifact_dir}" \
ORCA_INSTALL_DIR="${install_dir}" \
ORCA_SHARE_DIR="${share_dir}" \
RYK_TEST_ONBOARD_LOG="${onboard_log}" \
sh "${INSTALL_SH}" >/dev/null
[[ "$(grep -c '^# Added by ryk installer$' "${home}/.profile")" == 1 ]] || fail "reinstall duplicated the PATH block"
[[ "$(grep -c '^# ryk runtime assets$' "${home}/.profile")" == 1 ]] || fail "reinstall duplicated the runtime block"
[[ "$(grep -ci 'Orca installer\\|Orca runtime assets' "${home}/.profile")" == 0 ]] || fail "legacy profile markers were not migrated"

[[ ! -e "${escaped}" ]] || fail "ORCA_RESOURCE_ROOT escaped the install destination"
resource_root="${share_dir}/${VERSION}"
[[ -f "${resource_root}/fixtures/fixture.txt" ]] || fail "runtime assets were not installed under HOME"
[[ "$(readlink "${share_dir}/current")" == "${resource_root}" ]] || fail "current link targets the wrong runtime root"

activation="$(printf '%s\n' "${output}" | awk '/^    eval / { sub(/^    /, ""); print; exit }')"
[[ -n "${activation}" ]] || fail "installer did not print an activation command"
[[ "${activation}" == *"${install_dir}/ryk"* ]] || fail "activation command does not use the absolute installed binary"
# UX receipt: brand + success + hierarchy (presentation may use ANSI; strip for asserts).
plain_output="$(printf '%s\n' "${output}" | sed $'s/\x1b\\[[0-9;]*m//g')"
printf '%s\n' "${plain_output}" | grep -Eq 'Rykan V|ryk' || fail "installer did not print brand header"
printf '%s\n' "${plain_output}" | grep -Eqi 'Rykan V' || fail "installer did not print Rykan V brand"
printf '%s\n' "${plain_output}" | grep -Eq 'installed|reinstalled' || fail "installer did not print success receipt"
printf '%s\n' "${plain_output}" | grep -Fqi 'doctor --fix' ||
  fail "installer did not surface doctor --fix in user-facing copy (step/receipt)"
if printf '%s\n' "${plain_output}" | grep -Fqi 'ryk start'; then
  fail "installer still teaches ryk start as user-facing door"
fi
if printf '%s\n' "${plain_output}" | grep -Fqi 'start --auto'; then
  fail "installer still surfaces start --auto in user-facing copy"
fi
assert_no_d06_full_protection "${plain_output}" "success receipt"
printf '%s\n' "${plain_output}" | grep -Eq 'Activate this terminal|Activate this session' || fail "installer did not print activation hero"
printf '%s\n' "${plain_output}" | grep -Eq 'Details' || fail "installer did not print details section"
# Dashboard soft-warn belongs on the receipt stdout, without retired branding.
printf '%s\n' "${plain_output}" | grep -Eq 'dashboard UI' || fail "installer did not surface missing dashboard UI on the receipt"
if printf '%s\n' "${plain_output}" | grep -Eiq '(^|[^[:alnum:]_])orca([^[:alnum:]_]|$)'; then
  fail "installer exposed retired Orca branding"
fi
unset ORCA_FIRST_USER_ACTIVATED
eval "${activation}"
[[ "${ORCA_FIRST_USER_ACTIVATED:-}" == 1 ]] || fail "printed activation command did not activate the current shell"

# Quiet mode: only the activation line on stdout (no banner / steps / details).
# Quiet call site must still invoke doctor --fix under HOME + resource roots.
: > "${onboard_log}"
quiet_output="$(
  HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  ORCA_INSTALL_QUIET=1 \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  sh "${INSTALL_SH}" 2>/dev/null
)"
[[ "$(grep -c '^doctor --fix$' "${onboard_log}")" == 1 ]] ||
  fail "quiet install did not run doctor --fix exactly once"
[[ "$(grep -c '^start --auto$' "${onboard_log}")" == 0 ]] ||
  fail "quiet install invoked start --auto"
actual_quiet_cwd="$(sed -n 's/^cwd=//p' "${onboard_log}" | head -n 1)"
[[ -n "${actual_quiet_cwd}" && "${actual_quiet_cwd}" -ef "${home}" ]] ||
  fail "quiet onboarding did not run from HOME (cwd=${actual_quiet_cwd})"
grep -qF "resource=${share_dir}/current" "${onboard_log}" ||
  fail "quiet onboarding missing ORCA_RESOURCE_ROOT"
grep -qF "ryk_resource=${share_dir}/current" "${onboard_log}" ||
  fail "quiet onboarding missing RYK_RESOURCE_ROOT"
quiet_activation="$(printf '%s\n' "${quiet_output}" | awk '/^    eval / { sub(/^    /, ""); print; exit }')"
[[ -n "${quiet_activation}" ]] || fail "quiet mode did not print an activation command"
if printf '%s\n' "${quiet_output}" | grep -Eq 'Platform|Details|Resolve release|Activate this terminal'; then
  fail "quiet mode leaked non-activation UI"
fi
# Only the activation line should be non-empty content (allow blank lines).
nonempty_quiet="$(printf '%s\n' "${quiet_output}" | sed '/^[[:space:]]*$/d')"
[[ "$(printf '%s\n' "${nonempty_quiet}" | wc -l | tr -d ' ')" == "1" ]] || fail "quiet mode printed more than the activation line"

# Core / hard onboarding failure must fail the install receipt instead of claiming
# success and requiring the user to notice a dim warning.
: > "${onboard_log}"
failed_output="${tmp_root}/failed.out"
if HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  RYK_TEST_DOCTOR_EXIT=17 \
  sh "${INSTALL_SH}" >"${failed_output}" 2>&1; then
  fail "installer succeeded after doctor --fix failed"
fi
failed_plain="$(sed $'s/\x1b\\[[0-9;]*m//g' "${failed_output}")"
if printf '%s\n' "${failed_plain}" | grep -Fq "You're now protected by ryk"; then
  fail "installer claimed protection after doctor --fix failed"
fi
assert_no_d06_full_protection "${failed_plain}" "failed install"
# Hard-fail remediation must re-teach install trust scope (HOME + --from-install),
# not a bare `ryk doctor --fix` that drops the install-time scope flags.
printf '%s\n' "${failed_plain}" | grep -Fq 'doctor --fix --from-install' ||
  fail "hard-fail remediation missing doctor --fix --from-install (got remediation from failed install output)"
if ! printf '%s\n' "${failed_plain}" | grep -Eiq 'home directory|cd ["'\'']?\$?HOME'; then
  fail "hard-fail remediation missing HOME guidance (home directory / cd HOME)"
fi

# Soft host-fail honesty: doctor --fix exits 0 with partial receipt.
# Install must not step_done / claim D06 full-protection phrases.
: > "${onboard_log}"
partial_output="${tmp_root}/partial.out"
HOME="${home}" \
SHELL=/bin/sh \
ORCA_VERSION="${VERSION}" \
ORCA_ARTIFACT_DIR="${artifact_dir}" \
ORCA_INSTALL_DIR="${install_dir}" \
ORCA_SHARE_DIR="${share_dir}" \
RYK_TEST_ONBOARD_LOG="${onboard_log}" \
RYK_TEST_DOCTOR_PARTIAL=1 \
sh "${INSTALL_SH}" >"${partial_output}" 2>&1 ||
  fail "installer failed on soft host-fail (doctor --fix exit 0 / partial)"
[[ "$(grep -c '^doctor --fix$' "${onboard_log}")" == 1 ]] ||
  fail "partial-path install did not run doctor --fix once"
partial_plain="$(sed $'s/\x1b\\[[0-9;]*m//g' "${partial_output}")"
assert_no_d06_full_protection "${partial_plain}" "soft host-fail install"
if printf '%s\n' "${partial_plain}" | grep -Fqi 'ryk start'; then
  fail "soft host-fail path still teaches ryk start"
fi
# Soft path must not claim the old start full-protection completion string.
if printf '%s\n' "${partial_plain}" | grep -Fq "You're now protected by ryk"; then
  fail "soft host-fail path claimed full protection completion"
fi

# SKIP_ONBOARD must suppress the ensure door entirely (both RYK_ and ORCA_ names).
: > "${onboard_log}"
HOME="${home}" \
SHELL=/bin/sh \
ORCA_VERSION="${VERSION}" \
ORCA_ARTIFACT_DIR="${artifact_dir}" \
ORCA_INSTALL_DIR="${install_dir}" \
ORCA_SHARE_DIR="${share_dir}" \
RYK_INSTALL_SKIP_ONBOARD=1 \
RYK_TEST_ONBOARD_LOG="${onboard_log}" \
sh "${INSTALL_SH}" >/dev/null
[[ ! -s "${onboard_log}" ]] ||
  fail "RYK_INSTALL_SKIP_ONBOARD=1 still invoked doctor/start (log not empty)"

: > "${onboard_log}"
HOME="${home}" \
SHELL=/bin/sh \
ORCA_VERSION="${VERSION}" \
ORCA_ARTIFACT_DIR="${artifact_dir}" \
ORCA_INSTALL_DIR="${install_dir}" \
ORCA_SHARE_DIR="${share_dir}" \
ORCA_INSTALL_SKIP_ONBOARD=1 \
RYK_TEST_ONBOARD_LOG="${onboard_log}" \
sh "${INSTALL_SH}" >/dev/null
[[ ! -s "${onboard_log}" ]] ||
  fail "ORCA_INSTALL_SKIP_ONBOARD=1 still invoked doctor/start (log not empty)"

# Destination hardening: even force mode must not write through symlinked
# install/share parents or final binary/runtime targets.
assert_rejected_without_touching() {
  case_name="$1"
  case_install_dir="$2"
  case_share_dir="$3"
  victim="$4"
  output_path="${tmp_root}/${case_name}.out"

  if HOME="${home}" \
    SHELL=/bin/sh \
    RYK_VERSION="${VERSION}" \
    RYK_ARTIFACT_DIR="${artifact_dir}" \
    RYK_INSTALL_DIR="${case_install_dir}" \
    RYK_SHARE_DIR="${case_share_dir}" \
    RYK_INSTALL_FORCE=1 \
    RYK_INSTALL_SKIP_ONBOARD=1 \
    sh "${INSTALL_SH}" >"${output_path}" 2>&1; then
    fail "${case_name}: installer accepted a symlinked destination"
  fi
  [[ "$(cat "${victim}")" == "untouched" ]] || fail "${case_name}: installer modified the symlink target"
}

victim_file="${tmp_root}/victim-file"
printf 'untouched\n' > "${victim_file}"
binary_final_dir="${tmp_root}/binary-final"
mkdir -p "${binary_final_dir}"
ln -s "${victim_file}" "${binary_final_dir}/ryk"
assert_rejected_without_touching \
  "binary-final-symlink" "${binary_final_dir}" "${tmp_root}/binary-final-share" "${victim_file}"

binary_parent_target="${tmp_root}/binary-parent-target"
mkdir -p "${binary_parent_target}"
ln -s "${binary_parent_target}" "${tmp_root}/binary-parent-link"
assert_rejected_without_touching \
  "binary-parent-symlink" "${tmp_root}/binary-parent-link" "${tmp_root}/binary-parent-share" "${victim_file}"

runtime_victim_dir="${tmp_root}/runtime-victim"
mkdir -p "${runtime_victim_dir}"
runtime_victim="${runtime_victim_dir}/sentinel"
printf 'untouched\n' > "${runtime_victim}"
runtime_final_share="${tmp_root}/runtime-final-share"
mkdir -p "${runtime_final_share}"
ln -s "${runtime_victim_dir}" "${runtime_final_share}/${VERSION}"
assert_rejected_without_touching \
  "runtime-final-symlink" "${tmp_root}/runtime-final-bin" "${runtime_final_share}" "${runtime_victim}"

runtime_parent_target="${tmp_root}/runtime-parent-target"
mkdir -p "${runtime_parent_target}"
runtime_parent_victim="${runtime_parent_target}/sentinel"
printf 'untouched\n' > "${runtime_parent_victim}"
ln -s "${runtime_parent_target}" "${tmp_root}/runtime-parent-link"
assert_rejected_without_touching \
  "runtime-parent-symlink" "${tmp_root}/runtime-parent-bin" "${tmp_root}/runtime-parent-link" "${runtime_parent_victim}"

if find "${share_dir}" "${install_dir}" -maxdepth 1 \
  \( -name '.ryk-install.*' -o -name '.ryk-runtime.*' -o -name '.ryk-old.*' -o -name '.ryk-current.*' \) \
  -print -quit | grep -q .; then
  fail "installer left atomic-install staging paths behind"
fi

# ── Release/install skew: pre-W1 binary (no doctor --fix) falls back ─────
# Models tagged v1.2.9 (or any artifact whose doctor help omits --fix) while
# install.sh already prefers the W1 door. Capability probe must select
# start --auto; doctor --fix must not be attempted as the ensure door.
legacy_home="${tmp_root}/legacy-home"
legacy_install_dir="${legacy_home}/bin"
legacy_share_dir="${legacy_home}/share"
legacy_artifact_dir="${tmp_root}/legacy-artifacts"
legacy_release_root="${tmp_root}/orca-v${VERSION}-legacy-${os}-${arch}"
legacy_artifact="orca-v${VERSION}-${os}-${arch}.tar.gz"
legacy_onboard_log="${tmp_root}/legacy-onboard.log"
mkdir -p "${legacy_home}" "${legacy_install_dir}" "${legacy_share_dir}" \
  "${legacy_artifact_dir}" "${legacy_release_root}/bin"
for dir in integrations fixtures schemas policies orca-pi; do
  mkdir -p "${legacy_release_root}/${dir}"
  printf 'fixture\n' > "${legacy_release_root}/${dir}/fixture.txt"
done
cat > "${legacy_release_root}/bin/orca" <<'EOF'
#!/usr/bin/env sh
# Pre-W1 mock: doctor help has no --fix; start --auto is the ensure door.
log_scope() {
  door_line="$1"
  shift
  printf '%s\n' "${door_line}" >> "${RYK_TEST_ONBOARD_LOG:?}"
  printf 'cwd=%s\n' "$PWD" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'ryk_resource=%s\n' "${RYK_RESOURCE_ROOT:-}" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'resource=%s\n' "${ORCA_RESOURCE_ROOT:-}" >> "${RYK_TEST_ONBOARD_LOG}"
  printf 'argv=' >> "${RYK_TEST_ONBOARD_LOG}"
  first=1
  for a in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf '%s' "$a" >> "${RYK_TEST_ONBOARD_LOG}"
      first=0
    else
      printf ' %s' "$a" >> "${RYK_TEST_ONBOARD_LOG}"
    fi
  done
  printf '\n' >> "${RYK_TEST_ONBOARD_LOG}"
}
case "${1:-}" in
  doctor)
    if [ "${2:-}" = "--help" ] || [ "${2:-}" = "-h" ]; then
      # Mirrors released v1.2.9: no --fix in usage.
      printf 'Usage:\n  ryk doctor [-v|--verbose] [--check] [--json]\n'
      exit 0
    fi
    # If install still calls doctor --fix, surface the real product error.
    log_scope "doctor${2:+ $2}" "$@"
    printf "ryk doctor: unknown option '%s'.\n" "${2:---}" >&2
    exit 2
    ;;
  start)
    log_scope "start${2:+ $2}" "$@"
    if [ "${2:-}" != "--auto" ]; then
      printf 'mock start: expected --auto for legacy ensure\n' >&2
      exit 3
    fi
    # Installer may pass --skip-verify for soft-success parity with doctor --fix.
    printf 'ryk ensure: core ready via start --auto (legacy mock)\n'
    ;;
  env|--print-install-env)
    printf 'export ORCA_FIRST_USER_ACTIVATED=1\n'
    ;;
  version|--version)
    printf 'ryk 1.2.9\n'
    ;;
esac
EOF
chmod +x "${legacy_release_root}/bin/orca"
tar -czf "${legacy_artifact_dir}/${legacy_artifact}" -C "${tmp_root}" "$(basename "${legacy_release_root}")"
if command -v sha256sum >/dev/null 2>&1; then
  legacy_checksum="$(sha256sum "${legacy_artifact_dir}/${legacy_artifact}" | awk '{print $1}')"
else
  legacy_checksum="$(shasum -a 256 "${legacy_artifact_dir}/${legacy_artifact}" | awk '{print $1}')"
fi
printf '%s  %s\n' "${legacy_checksum}" "${legacy_artifact}" > "${legacy_artifact_dir}/checksums.txt"

: > "${legacy_onboard_log}"
legacy_output="$(
  HOME="${legacy_home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${legacy_artifact_dir}" \
  ORCA_INSTALL_DIR="${legacy_install_dir}" \
  ORCA_SHARE_DIR="${legacy_share_dir}" \
  RYK_INSTALL_FORCE=1 \
  RYK_TEST_ONBOARD_LOG="${legacy_onboard_log}" \
  sh "${INSTALL_SH}"
)" || fail "legacy (pre-doctor --fix) install failed (version skew fallback broken)"

# Must use legacy ensure door (start --auto, optionally with --skip-verify), not doctor --fix.
grep -qE '^start --auto$' "${legacy_onboard_log}" ||
  fail "legacy install did not invoke start --auto (log=$(cat "${legacy_onboard_log}" 2>/dev/null || true))"
grep -qE '^argv=start --auto --skip-verify' "${legacy_onboard_log}" ||
  fail "legacy install missing start --auto --skip-verify (got: $(grep '^argv=' "${legacy_onboard_log}" 2>/dev/null || true))"
# grep -c prints 0 but exits 1 when no matches — do not `|| echo 0` (that doubles).
legacy_doctor_fix_count="$(grep -c '^doctor --fix$' "${legacy_onboard_log}" 2>/dev/null || true)"
[[ "${legacy_doctor_fix_count}" == "0" ]] ||
  fail "legacy install still ran doctor --fix against a pre-W1 binary (count=${legacy_doctor_fix_count}; log=$(cat "${legacy_onboard_log}" 2>/dev/null || true))"
legacy_cwd="$(sed -n 's/^cwd=//p' "${legacy_onboard_log}" | head -n 1)"
[[ -n "${legacy_cwd}" && "${legacy_cwd}" -ef "${legacy_home}" ]] ||
  fail "legacy ensure did not run from HOME (cwd=${legacy_cwd})"
grep -qF "resource=${legacy_share_dir}/current" "${legacy_onboard_log}" ||
  fail "legacy ensure missing ORCA_RESOURCE_ROOT at installed share current"
legacy_plain="$(printf '%s\n' "${legacy_output}" | sed $'s/\x1b\\[[0-9;]*m//g')"
printf '%s\n' "${legacy_plain}" | grep -Eqi 'legacy|start --auto' ||
  fail "legacy install success path did not surface legacy/start --auto receipt language"
assert_no_d06_full_protection "${legacy_plain}" "legacy install receipt"

grep -qF 'version "1.2.9"' "${REPO_ROOT}/packaging/homebrew/Formula/ryk.rb" ||
  fail "primary Homebrew formula version does not match VERSION"
grep -qF 'brew install christopherkarani/orca/ryk' "${REPO_ROOT}/packaging/homebrew/README.md" ||
  fail "Homebrew README does not provide a one-line primary ryk install"
grep -qF 'raw.githubusercontent.com/christopherkarani/rykan/main/scripts/install.sh' "${INSTALL_SH}" ||
  fail "curl installer guidance does not use the canonical rykan repository"
grep -qF 'github.com/christopherkarani/rykan/releases/download' "${REPO_ROOT}/packaging/homebrew/Formula/ryk.rb" ||
  fail "Homebrew release artifacts do not use the canonical rykan repository"
if git -C "${REPO_ROOT}" grep -nE \
  'github\.com/(christopherkarani|chriskarani)/(Orca|orca|ryk)([^A-Za-z0-9_-]|$)|raw\.githubusercontent\.com/(christopherkarani|chriskarani)/(Orca|orca|ryk)/' \
  -- README.md AGENTS.md scripts packaging integrations schemas macos docs; then
  fail "public metadata still contains a stale main-repository URL"
fi

# ── Static machine gates on install.sh (D84 adjunct; D86 runtime is above) ──
# Primary ensure door remains doctor --fix --from-install. start --auto is
# allowed only as a capability-probed legacy fallback (release/install skew).
if ! grep -nF 'cli_supports_doctor_fix' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh missing cli_supports_doctor_fix capability probe'
fi
if ! grep -nF '"$DESTINATION" doctor --fix' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh missing invocation-anchored "$DESTINATION" doctor --fix'
fi
if ! grep -nF '"$DESTINATION" doctor --fix --from-install' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh missing "$DESTINATION" doctor --fix --from-install (install-scope flag)'
fi
if ! grep -nF '"$DESTINATION" start --auto --skip-verify' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh missing legacy fallback "$DESTINATION" start --auto --skip-verify for pre-W1 binaries'
fi
# Hard-fail operator remediation must re-teach install trust scope (not bare doctor --fix).
# Match re-teach copy (ryk doctor --fix --from-install), not only the binary invocation.
if ! grep -nE 'ryk doctor --fix --from-install' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh hard-fail remediation missing re-teach of ryk doctor --fix --from-install'
fi
if ! grep -nF 'Re-run from your home directory:' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh hard-fail remediation missing HOME guidance (Re-run from your home directory)'
fi
if ! grep -nF 'cd "$HOME"' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail 'scripts/install.sh missing cd "$HOME" around ensure invocation'
fi
if ! grep -n 'RYK_RESOURCE_ROOT' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail "scripts/install.sh missing RYK_RESOURCE_ROOT export around ensure"
fi
if grep -niE 'fully protected|all hosts wired|protection complete|full protection' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail "scripts/install.sh contains D06 full-protection forbid phrases"
fi
# Interactive guided start must not be the taught W1 door; path-qualified
# start --auto after a capability probe is the only allowed start form.
if grep -nE '(^|[^$])ryk start' "${INSTALL_SH}" >/dev/null 2>&1; then
  fail "scripts/install.sh still teaches bare ryk start (use doctor --fix or path-qualified legacy start --auto)"
fi
# Harness self-check (D84): capable-binary path must require doctor --fix and
# must not green solely on counting start --auto once as the success door.
if ! grep -nF "grep -c '^doctor --fix$'" "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  fail "harness must count doctor --fix (D86)"
fi
if grep -nE "grep -c '\\^start --auto\\\$'[[:space:]].*==[[:space:]]*1" "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  fail "harness must not treat start --auto count==1 as the green path for capable binaries"
fi

(
  cd "${home}"
  # shellcheck disable=SC1090
  . "${home}/.profile"
)
[[ ! -e "${home}/PATH_INJECTION" ]] || fail "install path executed shell syntax from the profile"
[[ ! -e "${home}/RESOURCE_INJECTION" ]] || fail "resource path executed shell syntax from the profile"

printf '[install-first-user-regression] passed\n'
