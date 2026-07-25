#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

fail() {
  printf 'install-first-user-regression: %s\n' "$1" >&2
  exit 1
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

cat > "${release_root}/bin/orca" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
  start)
    printf 'start%s\n' "${2:+ $2}" >> "${RYK_TEST_ONBOARD_LOG:?}"
    printf 'cwd=%s\n' "$PWD" >> "${RYK_TEST_ONBOARD_LOG}"
    printf 'resource=%s\n' "${ORCA_RESOURCE_ROOT:-}" >> "${RYK_TEST_ONBOARD_LOG}"
    printf 'path=%s\n' "${PATH:-}" >> "${RYK_TEST_ONBOARD_LOG}"
    if [ "${RYK_TEST_START_EXIT:-0}" -ne 0 ]; then
      exit "${RYK_TEST_START_EXIT}"
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

output="$(
  HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  ORCA_RESOURCE_ROOT="${escaped}" \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  sh "${REPO_ROOT}/scripts/install.sh"
)"

# Captured stdout is intentionally non-TTY. Setup must still be automatic.
[[ "$(grep -c '^start --auto$' "${onboard_log}")" == 1 ]] || fail "non-TTY install did not run onboarding exactly once"
actual_onboard_cwd="$(sed -n 's/^cwd=//p' "${onboard_log}" | head -n 1)"
[[ -n "${actual_onboard_cwd}" && "${actual_onboard_cwd}" -ef "${home}" ]] ||
  fail "onboarding did not run from the global HOME scope (cwd=${actual_onboard_cwd})"
grep -qF "resource=${share_dir}/current" "${onboard_log}" || fail "onboarding did not receive the installed resource root"
grep -qF "${install_dir}" "${onboard_log}" || fail "onboarding PATH did not contain the installed binary directory"

# Reinstalling must update the managed blocks instead of appending duplicates.
HOME="${home}" \
SHELL=/bin/sh \
ORCA_VERSION="${VERSION}" \
ORCA_ARTIFACT_DIR="${artifact_dir}" \
ORCA_INSTALL_DIR="${install_dir}" \
ORCA_SHARE_DIR="${share_dir}" \
RYK_TEST_ONBOARD_LOG="${onboard_log}" \
sh "${REPO_ROOT}/scripts/install.sh" >/dev/null
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
printf '%s\n' "${plain_output}" | grep -Eq 'ryk' || fail "installer did not print brand header"
printf '%s\n' "${plain_output}" | grep -Eq 'installed|reinstalled' || fail "installer did not print success receipt"
printf '%s\n' "${plain_output}" | grep -Fq "You're now protected by ryk" || fail "installer did not print the protected completion"
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
quiet_output="$(
  HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  ORCA_INSTALL_QUIET=1 \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  sh "${REPO_ROOT}/scripts/install.sh" 2>/dev/null
)"
quiet_activation="$(printf '%s\n' "${quiet_output}" | awk '/^    eval / { sub(/^    /, ""); print; exit }')"
[[ -n "${quiet_activation}" ]] || fail "quiet mode did not print an activation command"
if printf '%s\n' "${quiet_output}" | grep -Eq 'Platform|Details|Resolve release|Activate this terminal'; then
  fail "quiet mode leaked non-activation UI"
fi
# Only the activation line should be non-empty content (allow blank lines).
nonempty_quiet="$(printf '%s\n' "${quiet_output}" | sed '/^[[:space:]]*$/d')"
[[ "$(printf '%s\n' "${nonempty_quiet}" | wc -l | tr -d ' ')" == "1" ]] || fail "quiet mode printed more than the activation line"

# Protection setup failure must fail the install receipt instead of claiming
# success and requiring the user to notice a dim warning.
failed_output="${tmp_root}/failed.out"
if HOME="${home}" \
  SHELL=/bin/sh \
  ORCA_VERSION="${VERSION}" \
  ORCA_ARTIFACT_DIR="${artifact_dir}" \
  ORCA_INSTALL_DIR="${install_dir}" \
  ORCA_SHARE_DIR="${share_dir}" \
  RYK_TEST_ONBOARD_LOG="${onboard_log}" \
  RYK_TEST_START_EXIT=17 \
  sh "${REPO_ROOT}/scripts/install.sh" >"${failed_output}" 2>&1; then
  fail "installer succeeded after onboarding failed"
fi
if grep -Fq "You're now protected by ryk" "${failed_output}"; then
  fail "installer claimed protection after onboarding failed"
fi

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
    sh "${REPO_ROOT}/scripts/install.sh" >"${output_path}" 2>&1; then
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

grep -qF 'version "1.2.9"' "${REPO_ROOT}/packaging/homebrew/Formula/ryk.rb" ||
  fail "primary Homebrew formula version does not match VERSION"
grep -qF 'brew install christopherkarani/orca/ryk' "${REPO_ROOT}/packaging/homebrew/README.md" ||
  fail "Homebrew README does not provide a one-line primary ryk install"
grep -qF 'raw.githubusercontent.com/christopherkarani/rykan/main/scripts/install.sh' "${REPO_ROOT}/scripts/install.sh" ||
  fail "curl installer guidance does not use the canonical rykan repository"
grep -qF 'github.com/christopherkarani/rykan/releases/download' "${REPO_ROOT}/packaging/homebrew/Formula/ryk.rb" ||
  fail "Homebrew release artifacts do not use the canonical rykan repository"
if git -C "${REPO_ROOT}" grep -nE \
  'github\.com/(christopherkarani|chriskarani)/(Orca|orca|ryk)([^A-Za-z0-9_-]|$)|raw\.githubusercontent\.com/(christopherkarani|chriskarani)/(Orca|orca|ryk)/' \
  -- README.md AGENTS.md scripts packaging integrations schemas macos docs; then
  fail "public metadata still contains a stale main-repository URL"
fi

(
  cd "${home}"
  # shellcheck disable=SC1090
  . "${home}/.profile"
)
[[ ! -e "${home}/PATH_INJECTION" ]] || fail "install path executed shell syntax from the profile"
[[ ! -e "${home}/RESOURCE_INJECTION" ]] || fail "resource path executed shell syntax from the profile"

printf '[install-first-user-regression] passed\n'
