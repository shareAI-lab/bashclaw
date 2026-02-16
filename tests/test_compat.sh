#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_compat"

# ---- All lib/*.sh files source without error ----

test_start "all lib/*.sh files source without error"
setup_test_env
all_ok=true
for f in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  set +e
  (
    export BASHCLAW_STATE_DIR="$_TEST_TMPDIR"
    export LOG_LEVEL="silent"
    source "$f" 2>/dev/null
  )
  rc=$?
  set -e
  if (( rc != 0 )); then
    printf '  WARNING: %s failed to source (rc=%d)\n' "$name" "$rc"
    all_ok=false
  fi
done
if [[ "$all_ok" == "true" ]]; then
  _test_pass
else
  _test_fail "some lib/*.sh files failed to source"
fi
teardown_test_env

# ---- All channel/*.sh files source without error ----

test_start "all channel/*.sh files source without error"
setup_test_env
all_ok=true
for f in "${BASHCLAW_ROOT}"/channels/*.sh; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  set +e
  (
    export BASHCLAW_STATE_DIR="$_TEST_TMPDIR"
    export LOG_LEVEL="silent"
    for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
      [[ -f "$_lib" ]] && source "$_lib" 2>/dev/null
    done
    source "$f" 2>/dev/null
  )
  rc=$?
  set -e
  if (( rc != 0 )); then
    printf '  WARNING: %s failed to source (rc=%d)\n' "$name" "$rc"
    all_ok=false
  fi
done
if [[ "$all_ok" == "true" ]]; then
  _test_pass
else
  _test_fail "some channel/*.sh files failed to source"
fi
teardown_test_env

# ---- No declare -A usage (associative arrays require bash 4+) ----

test_start "no declare -A usage in lib and channel scripts"
setup_test_env
found=""
for f in "${BASHCLAW_ROOT}"/lib/*.sh "${BASHCLAW_ROOT}"/channels/*.sh; do
  [[ -f "$f" ]] || continue
  if grep -n 'declare[[:space:]]\+-A' "$f" 2>/dev/null; then
    found="$found $(basename "$f")"
  fi
done
if [[ -z "$found" ]]; then
  _test_pass
else
  _test_fail "declare -A found in:$found"
fi
teardown_test_env

# ---- No declare -g usage (requires bash 4.2+) ----

test_start "no declare -g usage in lib and channel scripts"
setup_test_env
found=""
for f in "${BASHCLAW_ROOT}"/lib/*.sh "${BASHCLAW_ROOT}"/channels/*.sh; do
  [[ -f "$f" ]] || continue
  if grep -n 'declare[[:space:]]\+-g' "$f" 2>/dev/null; then
    found="$found $(basename "$f")"
  fi
done
if [[ -z "$found" ]]; then
  _test_pass
else
  _test_fail "declare -g found in:$found"
fi
teardown_test_env

# ---- No bash 4+ only features: mapfile, readarray, &>> ----

test_start "no mapfile/readarray/&>> usage"
setup_test_env
found=""
for f in "${BASHCLAW_ROOT}"/lib/*.sh "${BASHCLAW_ROOT}"/channels/*.sh; do
  [[ -f "$f" ]] || continue
  if grep -nE '^\s*(mapfile|readarray)\b' "$f" 2>/dev/null; then
    found="$found $(basename "$f"):mapfile/readarray"
  fi
  if grep -n '&>>' "$f" 2>/dev/null; then
    found="$found $(basename "$f"):&>>"
  fi
done
if [[ -z "$found" ]]; then
  _test_pass
else
  _test_fail "bash 4+ features found:$found"
fi
teardown_test_env

# ---- jq is available ----

test_start "jq is available"
setup_test_env
if command -v jq &>/dev/null; then
  _test_pass
else
  _test_fail "jq not found in PATH"
fi
teardown_test_env

# ---- curl is available ----

test_start "curl is available"
setup_test_env
if command -v curl &>/dev/null; then
  _test_pass
else
  _test_fail "curl not found in PATH"
fi
teardown_test_env

# ---- mktemp works ----

test_start "mktemp works"
setup_test_env
tmp="$(mktemp -t bashclaw_compat_test.XXXXXX 2>/dev/null || mktemp /tmp/bashclaw_compat_test.XXXXXX)"
if [[ -f "$tmp" ]]; then
  _test_pass
  rm -f "$tmp"
else
  _test_fail "mktemp did not create a file"
fi
teardown_test_env

# ---- date +%s works ----

test_start "date +%s returns epoch seconds"
setup_test_env
ts="$(date +%s 2>/dev/null)"
if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 1700000000 )); then
  _test_pass
else
  _test_fail "date +%s returned: $ts"
fi
teardown_test_env

# ---- All key functions are defined after sourcing libs ----

test_start "key functions are defined after sourcing all libs"
setup_test_env
(
  export BASHCLAW_STATE_DIR="$_TEST_TMPDIR"
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done

  missing=""
  key_funcs=(
    config_init_default config_load config_get config_set config_validate
    config_agent_get config_channel_get config_reload config_backup
    session_file session_append session_load session_clear session_delete
    session_prune session_count session_list session_export
    agent_resolve_model agent_resolve_provider agent_build_system_prompt
    agent_build_messages agent_build_tools_spec agent_run
    tool_execute tool_memory tool_shell tool_web_fetch tool_cron
    tools_build_spec
    routing_resolve_agent routing_check_allowlist routing_check_mention_gating
    routing_format_reply routing_split_long_message
    log_debug log_info log_warn log_error
    trim timestamp_s uuid_generate json_escape hash_string
    ensure_dir tmpfile is_command_available
  )

  for fn in "${key_funcs[@]}"; do
    if ! declare -f "$fn" &>/dev/null; then
      missing="$missing $fn"
    fi
  done

  if [[ -z "$missing" ]]; then
    exit 0
  else
    printf 'Missing functions:%s\n' "$missing" >&2
    exit 1
  fi
)
if (( $? == 0 )); then
  _test_pass
else
  _test_fail "some key functions are not defined"
fi
teardown_test_env

report_results
