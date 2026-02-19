#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_install"

INSTALL_SCRIPT="${BASHCLAW_ROOT}/install.sh"

# Source install.sh functions without executing main.
# Strip the trailing `main "$@"` call so sourcing only defines functions.
_source_install_functions() {
  eval "$(sed '/^main "\$@"$/d' "$INSTALL_SCRIPT")"
}

# ---- install.sh --help shows usage ----

test_start "install.sh --help shows usage"
setup_test_env
if [[ -f "$INSTALL_SCRIPT" ]]; then
  result="$(bash "$INSTALL_SCRIPT" --help 2>&1)" || true
  if [[ -n "$result" ]]; then
    assert_match "$result" '[Uu]sage|[Hh]elp|[Ii]nstall'
  else
    _test_fail "install.sh --help produced no output"
  fi
else
  printf '  SKIP install.sh not found\n'
  _test_pass
fi
teardown_test_env

# ---- install.sh --prefix documented in help ----

test_start "install.sh --prefix documented in help"
setup_test_env
if [[ -f "$INSTALL_SCRIPT" ]]; then
  result="$(bash "$INSTALL_SCRIPT" --help 2>&1)" || true
  assert_contains "$result" "--prefix"
else
  printf '  SKIP install.sh not found\n'
  _test_pass
fi
teardown_test_env

# ---- _detect_os returns a known value ----

test_start "_detect_os returns a known value"
setup_test_env
(
  _source_install_functions
  os="$(_detect_os)"
  case "$os" in
    darwin|linux|termux|unknown)
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
)
rc=$?
assert_eq "$rc" "0" "_detect_os should return darwin, linux, termux, or unknown"
teardown_test_env

# ---- _check_bash_version does not fail on current bash ----

test_start "_check_bash_version does not fail on current bash"
setup_test_env
(
  _source_install_functions
  _check_bash_version >/dev/null 2>&1
)
rc=$?
assert_eq "$rc" "0" "_check_bash_version should succeed on current bash"
teardown_test_env

# ---- _is_command_available finds known commands ----

test_start "_is_command_available finds bash"
setup_test_env
(
  _source_install_functions
  _is_command_available bash
)
rc=$?
assert_eq "$rc" "0" "bash should be available"
teardown_test_env

test_start "_is_command_available finds cat"
setup_test_env
(
  _source_install_functions
  _is_command_available cat
)
rc=$?
assert_eq "$rc" "0" "cat should be available"
teardown_test_env

test_start "_is_command_available fails for nonexistent command"
setup_test_env
(
  _source_install_functions
  set +e
  _is_command_available _nonexistent_command_xyz_42
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    exit 0
  else
    exit 1
  fi
)
rc=$?
assert_eq "$rc" "0" "nonexistent command should not be available"
teardown_test_env

# ---- _parse_args --prefix sets _INSTALL_DIR ----

test_start "_parse_args --prefix sets _INSTALL_DIR"
setup_test_env
result="$(
  _source_install_functions
  _INSTALL_DIR=""
  _parse_args --prefix /tmp/test
  printf '%s' "$_INSTALL_DIR"
)"
assert_eq "$result" "/tmp/test"
teardown_test_env

# ---- _parse_args --no-path sets _NO_PATH ----

test_start "_parse_args --no-path sets _NO_PATH to true"
setup_test_env
result="$(
  _source_install_functions
  _NO_PATH=false
  _parse_args --no-path
  printf '%s' "$_NO_PATH"
)"
assert_eq "$result" "true"
teardown_test_env

# ---- _parse_args --uninstall sets _UNINSTALL ----

test_start "_parse_args --uninstall sets _UNINSTALL to true"
setup_test_env
result="$(
  _source_install_functions
  _UNINSTALL=false
  _parse_args --uninstall
  printf '%s' "$_UNINSTALL"
)"
assert_eq "$result" "true"
teardown_test_env

# ---- _create_default_config creates valid JSON ----

test_start "_create_default_config creates valid JSON config"
setup_test_env
(
  export HOME="$_TEST_TMPDIR"
  _source_install_functions
  _create_default_config
)
config_file="${_TEST_TMPDIR}/.bashclaw/bashclaw.json"
if [[ -f "$config_file" ]]; then
  content="$(cat "$config_file")"
  assert_json_valid "$content"
else
  _test_fail "config file was not created at $config_file"
fi
teardown_test_env

# ---- _install_command with existing bashclaw in PATH is a no-op ----

test_start "_install_command with existing bashclaw in PATH is a no-op"
setup_test_env
test_dir="${_TEST_TMPDIR}/alreadyhere"
mkdir -p "$test_dir"
printf '#!/bin/bash\necho test\n' > "$test_dir/bashclaw"
chmod +x "$test_dir/bashclaw"
export PATH="${test_dir}:$PATH"
export HOME="$_TEST_TMPDIR"
(
  _source_install_functions
  _NO_PATH=false
  _install_command "$test_dir" 2>/dev/null
  # Should report already in PATH without creating symlinks
  if [[ ! -L /usr/local/bin/bashclaw ]] && [[ ! -L "${_TEST_TMPDIR}/.local/bin/bashclaw" ]]; then
    exit 0
  else
    exit 1
  fi
)
rc=$?
assert_eq "$rc" "0" "_install_command should be a no-op when bashclaw is already in PATH"
teardown_test_env

# ---- _install_command creates symlink in ~/.local/bin ----

test_start "_install_command creates symlink in ~/.local/bin"
setup_test_env
test_dir="${_TEST_TMPDIR}/install_bin"
mkdir -p "$test_dir"
printf '#!/bin/bash\necho test\n' > "$test_dir/bashclaw"
chmod +x "$test_dir/bashclaw"
export HOME="$_TEST_TMPDIR"
(
  # Remove bashclaw from PATH so it needs to create a symlink
  export PATH="/usr/bin:/bin"
  _source_install_functions
  _NO_PATH=false
  _install_command "$test_dir" 2>/dev/null
  if [[ -L "${HOME}/.local/bin/bashclaw" ]]; then
    exit 0
  else
    exit 1
  fi
)
rc=$?
assert_eq "$rc" "0" "_install_command should create symlink at ~/.local/bin/bashclaw"
teardown_test_env

report_results
