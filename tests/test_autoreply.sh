#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_autoreply"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- autoreply_add creates rule ----

test_start "autoreply_add creates rule"
setup_test_env
_source_libs
id="$(autoreply_add "hello|hi|hey" "Hello! How can I help?")"
result="$(autoreply_list)"
assert_json_valid "$result"
assert_contains "$result" "hello|hi|hey"
teardown_test_env

# ---- autoreply_check matches pattern ----

test_start "autoreply_check matches pattern"
setup_test_env
_source_libs
autoreply_add "hello|hi|hey" "Hello! How can I help?" >/dev/null
result="$(autoreply_check "hello there")"
assert_eq "$result" "Hello! How can I help?"
teardown_test_env

# ---- autoreply_check no match returns empty ----

test_start "autoreply_check no match returns failure"
setup_test_env
_source_libs
autoreply_add "hello|hi|hey" "Hello!" >/dev/null
set +e
result="$(autoreply_check "goodbye" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )); then
  _test_pass
else
  if [[ -z "$result" ]]; then
    _test_pass
  else
    _test_fail "no-match should return failure or empty"
  fi
fi
teardown_test_env

# ---- autoreply_remove deletes rule ----

test_start "autoreply_remove deletes rule"
setup_test_env
_source_libs
id="$(autoreply_add "hello" "Hello!")"
autoreply_remove "$id"
result="$(autoreply_list)"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "0"
teardown_test_env

# ---- autoreply_list shows all rules ----

test_start "autoreply_list shows all rules"
setup_test_env
_source_libs
autoreply_add "hello" "Hello!" >/dev/null
autoreply_add "goodbye|bye" "Goodbye!" >/dev/null
autoreply_add "help|assist" "How can I help?" >/dev/null
result="$(autoreply_list)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "3"
teardown_test_env

# ---- Channel filter restricts matching ----

test_start "channel filter restricts matching"
setup_test_env
_source_libs
autoreply_add "hello" "Telegram hello!" --channel "telegram" >/dev/null
# Should match for telegram channel
result="$(autoreply_check "hello" "telegram")"
assert_eq "$result" "Telegram hello!"
# Should NOT match for discord channel
set +e
result="$(autoreply_check "hello" "discord" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$result" ]]; then
  _test_pass
else
  _test_fail "channel filter should prevent match (got: $result)"
fi
teardown_test_env

# ---- Regex metacharacters in pattern are safe (fixed-string matching) ----

test_start "autoreply_check handles regex metacharacters safely"
setup_test_env
_source_libs
autoreply_add ".*+?{}()|[]^$" "Metachar response" >/dev/null
# The pattern itself should not match arbitrary text via regex
set +e
result="$(autoreply_check "anything" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$result" ]]; then
  _test_pass
else
  _test_fail "regex metacharacters should not match arbitrary text (got: $result)"
fi
teardown_test_env

# ---- Autoreply with empty message returns no match ----

test_start "autoreply_check with empty-string message"
setup_test_env
_source_libs
autoreply_add "hello" "Hello!" >/dev/null
set +e
result="$(autoreply_check "" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$result" ]]; then
  _test_pass
else
  _test_fail "empty message should not match (got: $result)"
fi
teardown_test_env

# ---- Autoreply remove nonexistent ID fails ----

test_start "autoreply_remove nonexistent ID returns failure"
setup_test_env
_source_libs
set +e
autoreply_remove "nonexistent-id-xyz" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Autoreply list with no rules returns empty array ----

test_start "autoreply_list with no rules returns empty array"
setup_test_env
_source_libs
result="$(autoreply_list)"
assert_eq "$result" "[]"
teardown_test_env

# ---- Autoreply priority ordering ----

test_start "autoreply_check respects priority ordering"
setup_test_env
_source_libs
autoreply_add "test" "Low priority" --priority 200 >/dev/null
autoreply_add "test" "High priority" --priority 10 >/dev/null
result="$(autoreply_check "this is a test")"
assert_eq "$result" "High priority"
teardown_test_env

# ---- Edge Case: autoreply with regex metacharacters in pattern ----

test_start "autoreply with regex metacharacters does not match arbitrary text"
setup_test_env
_source_libs
autoreply_add '.*+?{}()|[]^$' "Metachar response" >/dev/null
set +e
result="$(autoreply_check "random unrelated text" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$result" ]]; then
  _test_pass
else
  _test_fail "regex metacharacters should not match arbitrary text (got: $result)"
fi
teardown_test_env

test_start "autoreply with regex metachar pattern matches literal occurrence"
setup_test_env
_source_libs
autoreply_add '.*+?' "Metachar literal match" >/dev/null
result="$(autoreply_check "text containing .*+? literally")"
assert_eq "$result" "Metachar literal match"
teardown_test_env

# ---- Edge Case: autoreply with empty message ----

test_start "autoreply_check with empty message returns no match"
setup_test_env
_source_libs
autoreply_add "hello" "Hello there!" >/dev/null
set +e
result="$(autoreply_check "" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$result" ]]; then
  _test_pass
else
  _test_fail "empty message should not match any rule (got: $result)"
fi
teardown_test_env

# ---- Edge Case: autoreply with very long message ----

test_start "autoreply_check with very long message does not crash"
setup_test_env
_source_libs
autoreply_add "needle" "Found it!" >/dev/null
long_msg="$(printf 'x%.0s' $(seq 1 10001))needle"
result="$(autoreply_check "$long_msg")"
assert_eq "$result" "Found it!"
teardown_test_env

report_results
