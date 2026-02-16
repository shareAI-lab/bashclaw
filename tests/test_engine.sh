#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-engine"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

begin_test_file "test_engine"

# ---- engine_detect ----

test_start "engine_detect returns a valid engine name"
setup_test_env
result="$(engine_detect)"
case "$result" in
  builtin|claude|codex)
    _test_pass
    ;;
  *)
    _test_fail "unexpected engine: $result"
    ;;
esac
teardown_test_env

# ---- engine_resolve ----

test_start "engine_resolve reads config defaults"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
assert_eq "$result" "builtin"
teardown_test_env

test_start "engine_resolve reads per-agent engine"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": [{"id": "research", "engine": "claude"}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "research")"
assert_eq "$result" "claude"
teardown_test_env

test_start "engine_resolve auto falls back to valid engine"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "auto"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
case "$result" in
  builtin|claude|codex)
    _test_pass
    ;;
  *)
    _test_fail "unexpected engine from auto: $result"
    ;;
esac
teardown_test_env

test_start "engine_resolve unknown engine falls back to builtin"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "nonexistent-engine"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
assert_eq "$result" "builtin"
teardown_test_env

# ---- engine_info ----

test_start "engine_info returns valid JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "auto"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_info)"
assert_json_valid "$result"
# Must contain detected and engines fields
detected="$(printf '%s' "$result" | jq -r '.detected')"
assert_ne "$detected" "null"
has_builtin="$(printf '%s' "$result" | jq -r '.engines.builtin.available')"
assert_eq "$has_builtin" "true"
teardown_test_env

# ---- engine_claude_available ----

test_start "engine_claude_available returns without error"
setup_test_env
# Just test it doesn't crash
engine_claude_available || true
_test_pass
teardown_test_env

# ---- engine_claude_session_id ----

test_start "engine_claude_session_id reads from session metadata"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
local_sess="${BASHCLAW_STATE_DIR}/sessions/test_cc.jsonl"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
# Write metadata with cc_session_id
session_meta_update "$local_sess" "cc_session_id" '"abc-123-def"'
result="$(engine_claude_session_id "$local_sess")"
assert_eq "$result" "abc-123-def"
teardown_test_env

test_start "engine_claude_session_id returns empty for no metadata"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
local_sess="${BASHCLAW_STATE_DIR}/sessions/test_cc_empty.jsonl"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
result="$(engine_claude_session_id "$local_sess")"
assert_eq "$result" ""
teardown_test_env

# ---- engine_claude_version ----

test_start "engine_claude_version does not crash"
setup_test_env
# Returns version string or empty, should not error
result="$(engine_claude_version)" || true
_test_pass
teardown_test_env

# ---- engine_run with builtin engine calls agent_run ----

test_start "engine_run with builtin engine calls agent_run"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
# Mock agent_run to return a known value
agent_run() {
  printf 'mock_agent_response'
}
result="$(engine_run "main" "test message" "web" "tester")"
assert_eq "$result" "mock_agent_response"
# Restore original agent_run
for _lib in "${BASHCLAW_ROOT}"/lib/agent.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
teardown_test_env

# ---- engine_run with unknown agent falls back to builtin ----

test_start "engine_run with unknown agent falls back to builtin"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
# Mock agent_run to confirm builtin path is taken
agent_run() {
  printf 'fallback_builtin_response'
}
result="$(engine_run "nonexistent_agent_xyz" "hello" "web" "tester")"
assert_eq "$result" "fallback_builtin_response"
# Restore original agent_run
for _lib in "${BASHCLAW_ROOT}"/lib/agent.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
teardown_test_env

report_results
