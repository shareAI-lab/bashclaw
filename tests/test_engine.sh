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

# ---- engine_claude_run with mock claude CLI ----

test_start "engine_claude_run parses successful JSON result"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Create a mock claude command that outputs valid JSON
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"num_turns":2,"result":"Hello from Claude engine","session_id":"sess-abc-123","total_cost_usd":0.05,"usage":{"input_tokens":100,"output_tokens":50}}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
# Override claude command
claude() { "$mock_claude_bin" "$@"; }
export -f claude
# Override is_command_available to find mock claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test message" "default" "tester")"
assert_eq "$result" "Hello from Claude engine"
# Verify session metadata was persisted
local_sess="$(session_file "main" "default" "tester")"
cc_sid="$(engine_claude_session_id "$local_sess")"
assert_eq "$cc_sid" "sess-abc-123"
# Restore
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles error result"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_err"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","subtype":"success","is_error":true,"duration_ms":1000,"num_turns":1,"result":"Auth failed: 401","session_id":"sess-err-456","total_cost_usd":0,"usage":{}}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester")"
assert_eq "$result" "Auth failed: 401"
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles empty output"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_empty"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
# Output nothing
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester" 2>/dev/null)" || true
assert_eq "$result" ""
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles invalid JSON output"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_bad"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'not valid json at all'
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester" 2>/dev/null)" || true
assert_eq "$result" ""
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run with session resume passes --resume flag"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Pre-populate session with cc_session_id
local_sess="$(session_file "main" "default" "resume_tester")"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
session_meta_update "$local_sess" "cc_session_id" '"existing-sess-789"'
# Create mock that captures args
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_resume"
args_capture="${BASHCLAW_STATE_DIR}/claude_args_captured"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"resumed ok","session_id":"existing-sess-789","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "continue" "default" "resume_tester" >/dev/null 2>&1
# Check that --resume was passed
if grep -q "existing-sess-789" "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "--resume flag not passed with existing session_id"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_run dispatches to claude engine when configured"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_dispatch"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","is_error":false,"result":"dispatched to claude","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_run "main" "test dispatch" "default" "tester")"
assert_eq "$result" "dispatched to claude"
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run injects bashclaw-context into message"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Mock claude that captures its -p argument
args_capture="${BASHCLAW_STATE_DIR}/claude_ctx_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_ctx"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
# Capture all args to file
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"s1","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "hello world" "default" "ctx_tester" >/dev/null 2>&1
# Check that the -p arg contains <bashclaw-context> and the user message
prompt_arg="$(cat "$args_capture" 2>/dev/null)"
if printf '%s' "$prompt_arg" | grep -q '<bashclaw-context>'; then
  _test_pass
else
  _test_fail "Message does not contain <bashclaw-context> tag"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run passes --setting-sources empty"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_ss_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_ss"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "ss_tester" >/dev/null 2>&1
if grep -q '\-\-setting-sources' "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "Missing --setting-sources flag"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run includes bashclaw tool path in context"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_tool_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_tool"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "tool_tester" >/dev/null 2>&1
if grep -q 'bashclaw tool' "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "Context does not contain bashclaw tool invocation pattern"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

# ---- bashclaw tool CLI subcommand ----

test_start "bashclaw tool memory executes with flags"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory --action set --key test_key --value test_val 2>/dev/null)"
assert_contains "$result" "test_key"
result2="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory --action get --key test_key 2>/dev/null)"
assert_contains "$result2" "test_val"
teardown_test_env

test_start "bashclaw tool memory also accepts raw JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory '{"action":"set","key":"json_key","value":"json_val"}' 2>/dev/null)"
assert_contains "$result" "json_key"
result2="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory '{"action":"get","key":"json_key"}' 2>/dev/null)"
assert_contains "$result2" "json_val"
teardown_test_env

test_start "bashclaw tool unknown tool returns error"
setup_test_env
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool nonexistent_tool --foo bar 2>&1)" || true
assert_contains "$result" "unknown tool"
teardown_test_env

test_start "bashclaw tool with no args shows usage"
setup_test_env
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool 2>&1)" || true
assert_contains "$result" "Usage:"
teardown_test_env

# ---- tools_describe_bridge_only ----

test_start "tools_describe_bridge_only mentions bashclaw tool CLI"
setup_test_env
result="$(tools_describe_bridge_only)"
assert_contains "$result" "bashclaw tool"
teardown_test_env

# ---- Engine Parity Phase 2 Tests ----

test_start "engine_run passes is_subagent to claude engine"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_subagent_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_sub"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"subagent ok","session_id":"s-sub","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
# Call via engine_run with is_subagent=true
engine_run "main" "test subagent" "default" "tester" "true" >/dev/null 2>&1
# The context should NOT contain "Memory recall:" since subagents skip memory guidance
prompt_arg="$(cat "$args_capture" 2>/dev/null)"
if printf '%s' "$prompt_arg" | grep -q 'Memory recall:'; then
  _test_fail "Subagent context should not contain Memory recall guidance"
else
  _test_pass
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run fires session_start hook for new sessions"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Register a session_start hook
hook_marker="${BASHCLAW_STATE_DIR}/session_start_fired"
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/session_start_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<HEOF
#!/usr/bin/env bash
touch "$hook_marker"
HEOF
chmod +x "$hook_script"
hooks_register "test_session_start" "session_start" "$hook_script"
# Mock claude
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_sshook"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"new-s","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "hook_tester" >/dev/null 2>&1
sleep 0.5
if [[ -f "$hook_marker" ]]; then
  _test_pass
else
  _test_fail "session_start hook was not fired"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_run fires pre_message hook and can modify message"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Register a pre_message hook that modifies the message
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/pre_msg_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<'HEOF'
#!/usr/bin/env bash
# Read input JSON from stdin and modify message
input="$(cat)"
printf '%s' "$input" | jq '.message = "MODIFIED_MSG"'
HEOF
chmod +x "$hook_script"
hooks_register "test_pre_msg" "pre_message" "$hook_script" --strategy modifying
# Mock claude that captures prompt
args_capture="${BASHCLAW_STATE_DIR}/claude_premsg_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_premsg"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_run "main" "original_msg" "default" "premsg_tester" >/dev/null 2>&1
prompt_arg="$(cat "$args_capture" 2>/dev/null)"
if printf '%s' "$prompt_arg" | grep -q 'MODIFIED_MSG'; then
  _test_pass
else
  _test_fail "pre_message hook did not modify the message"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_run fires post_message hook"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
hook_marker="${BASHCLAW_STATE_DIR}/post_message_fired"
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/post_msg_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<HEOF
#!/usr/bin/env bash
touch "$hook_marker"
HEOF
chmod +x "$hook_script"
hooks_register "test_post_msg" "post_message" "$hook_script"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_postmsg"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","is_error":false,"result":"response text","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_run "main" "test" "default" "postmsg_tester" >/dev/null 2>&1
sleep 0.5
if [[ -f "$hook_marker" ]]; then
  _test_pass
else
  _test_fail "post_message hook was not fired"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run tracks usage tokens"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/usage"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_usage"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"s-usage","total_cost_usd":0.05,"num_turns":2,"usage":{"input_tokens":500,"output_tokens":200}}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test usage" "default" "usage_tester" >/dev/null 2>&1
# Check usage file was written
if [[ -f "${BASHCLAW_STATE_DIR}/usage/usage.jsonl" ]]; then
  last_line="$(tail -1 "${BASHCLAW_STATE_DIR}/usage/usage.jsonl")"
  in_tok="$(printf '%s' "$last_line" | jq -r '.input_tokens')"
  out_tok="$(printf '%s' "$last_line" | jq -r '.output_tokens')"
  if [[ "$in_tok" == "500" && "$out_tok" == "200" ]]; then
    _test_pass
  else
    _test_fail "Usage tokens mismatch: in=$in_tok out=$out_tok"
  fi
else
  _test_fail "usage.jsonl not written"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "tools_describe_bridge_only filters by allow list"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {},
    "list": [{"id": "restricted", "tools": {"allow": ["memory", "cron"]}}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(tools_describe_bridge_only "restricted")"
assert_contains "$result" "memory"
assert_contains "$result" "cron"
if printf '%s' "$result" | grep -q 'spawn'; then
  _test_fail "spawn should be filtered out by allow list"
fi
teardown_test_env

test_start "tools_describe_bridge_only filters by deny list"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {},
    "list": [{"id": "nodeny", "tools": {"deny": ["spawn", "spawn_status"]}}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(tools_describe_bridge_only "nodeny")"
assert_contains "$result" "memory"
if printf '%s' "$result" | grep -q '^\s*[0-9]*\. spawn '; then
  _test_fail "spawn should be filtered out by deny list"
fi
teardown_test_env

test_start "bashclaw tool fires pre_tool hook"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
mkdir -p "${BASHCLAW_STATE_DIR}/hooks"
hook_marker="${BASHCLAW_STATE_DIR}/pre_tool_fired"
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/pre_tool_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<HEOF
#!/usr/bin/env bash
input="\$(cat)"
touch "$hook_marker"
printf '%s' "\$input"
HEOF
chmod +x "$hook_script"
hooks_register "test_pre_tool" "pre_tool" "$hook_script" --strategy modifying
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory --action list 2>/dev/null)" || true
sleep 0.5
if [[ -f "$hook_marker" ]]; then
  _test_pass
else
  _test_fail "pre_tool hook was not fired via bashclaw tool CLI"
fi
teardown_test_env

# ---- Phase 3: Settings injection, hooks bridge, tool profiles ----

test_start "_engine_claude_build_settings generates valid hooks JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(_engine_claude_build_settings "/usr/local/bin/bashclaw")"
assert_json_valid "$result"
# Must contain PreCompact and PostToolUse hooks
has_precompact="$(printf '%s' "$result" | jq '.hooks.PreCompact | length')"
assert_ne "$has_precompact" "0"
has_posttool="$(printf '%s' "$result" | jq '.hooks.PostToolUse | length')"
assert_ne "$has_posttool" "0"
# Command must reference bashclaw hooks-bridge
bridge_cmd="$(printf '%s' "$result" | jq -r '.hooks.PreCompact[0].hooks[0].command')"
assert_contains "$bridge_cmd" "hooks-bridge pre_compact"
teardown_test_env

test_start "_engine_claude_map_profile maps coding profile correctly"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {},
    "list": [{"id": "coder", "tools": {"profile": "coding"}}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(_engine_claude_map_profile "coder")"
# coding profile includes shell -> Bash should be allowed
assert_contains "$result" "+Bash"
assert_contains "$result" "+Read"
assert_contains "$result" "+Write"
# coding profile does NOT include message or agent_message -> no effect on native tools
# But should NOT disallow tools that are in the profile
if printf '%s' "$result" | grep -q '^\-Bash$'; then
  _test_fail "Bash should not be disallowed for coding profile"
fi
teardown_test_env

test_start "_engine_claude_map_profile skips full profile"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {},
    "list": [{"id": "fullprofile", "tools": {"profile": "full"}}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(_engine_claude_map_profile "fullprofile")"
# Full profile should return nothing (no filtering needed)
assert_eq "$result" ""
teardown_test_env

test_start "_engine_claude_map_profile maps minimal profile"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {},
    "list": [{"id": "minimal_agent", "tools": {"profile": "minimal"}}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(_engine_claude_map_profile "minimal_agent")"
# minimal profile: web_fetch, web_search, memory, session_status
# shell is NOT in minimal -> Bash should be disallowed EXCEPT the +Bash override at end
assert_contains "$result" "+WebFetch"
assert_contains "$result" "+WebSearch"
# read_file is NOT in minimal -> Read should be disallowed
if printf '%s' "$result" | grep -q '^\-Read$'; then
  _test_pass
else
  _test_fail "Read should be disallowed for minimal profile"
fi
teardown_test_env

test_start "engine_claude_run passes --settings flag"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_settings_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_settings"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "settings_tester" >/dev/null 2>&1
if grep -q '\-\-settings' "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "Missing --settings flag in Claude CLI args"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run maps deny list to --disallowedTools"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "claude"},
    "list": [{"id": "limited", "engine": "claude", "tools": {"deny": ["shell", "write_file"]}}]
  },
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_deny_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_deny"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "limited" "test deny" "default" "deny_tester" >/dev/null 2>&1
captured="$(cat "$args_capture" 2>/dev/null)"
if printf '%s' "$captured" | grep -q '\-\-disallowedTools' && \
   printf '%s' "$captured" | grep -q 'Bash' && \
   printf '%s' "$captured" | grep -q 'Write'; then
  _test_pass
else
  _test_fail "Expected --disallowedTools Bash and Write for denied shell and write_file"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "hooks-bridge pre_compact returns valid JSON with additionalContext"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
result="$(printf '{"trigger":"auto"}' | bash "${BASHCLAW_ROOT}/bashclaw" hooks-bridge pre_compact 2>/dev/null)"
assert_json_valid "$result"
assert_contains "$result" "additionalContext"
assert_contains "$result" "PreCompact"
teardown_test_env

test_start "hooks-bridge post_tool_use returns reflection prompt"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "${BASHCLAW_ROOT}/bashclaw" hooks-bridge post_tool_use 2>/dev/null)"
assert_json_valid "$result"
assert_contains "$result" "additionalContext"
assert_contains "$result" "PostToolUse"
teardown_test_env

test_start "hooks-bridge post_tool_use respects disabled reflection"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{"reflectionPrompt":"false"},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(printf '{"tool_name":"Read"}' | bash "${BASHCLAW_ROOT}/bashclaw" hooks-bridge post_tool_use 2>/dev/null)"
assert_eq "$result" "{}"
teardown_test_env

# ---- Phase D: New parity tests ----

test_start "is_subagent=true blocks SOUL.md in prompt"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[{"id":"test","systemPrompt":"base prompt"}]}}
EOF
_CONFIG_CACHE=""
config_load
# Create SOUL.md in agent state dir (prompt_builder looks at agents/{id}/SOUL.md)
soul_dir="${BASHCLAW_STATE_DIR}/agents/test"
mkdir -p "$soul_dir"
printf 'SOUL_CONTENT_MARKER' > "${soul_dir}/SOUL.md"
# is_subagent=false should include SOUL.md
prompt_full="$(agent_build_system_prompt "test" "false" "default" 2>/dev/null)"
# is_subagent=true should NOT include SOUL.md
prompt_sub="$(agent_build_system_prompt "test" "true" "default" 2>/dev/null)"
if printf '%s' "$prompt_full" | grep -q 'SOUL_CONTENT_MARKER'; then
  _test_pass "full agent includes SOUL.md"
else
  _test_fail "full agent should include SOUL.md content"
fi
if printf '%s' "$prompt_sub" | grep -q 'SOUL_CONTENT_MARKER'; then
  _test_fail "subagent should NOT include SOUL.md content"
else
  _test_pass "subagent excludes SOUL.md"
fi
teardown_test_env

test_start "engine_run fires before_agent_start hook"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{"engine":"builtin"},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
hook_marker="${BASHCLAW_STATE_DIR}/before_agent_start_fired"
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/bas_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<HEOF
#!/usr/bin/env bash
touch "$hook_marker"
HEOF
chmod +x "$hook_script"
hooks_register "test_bas" "before_agent_start" "$hook_script"
# Mock agent_run to avoid real API calls
agent_run() { printf 'mock response'; }
engine_run "main" "test" "default" "" >/dev/null 2>&1
if [[ -f "$hook_marker" ]]; then
  _test_pass
else
  _test_fail "before_agent_start hook was not fired"
fi
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_run fires agent_end hook"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{"engine":"builtin"},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
hook_marker="${BASHCLAW_STATE_DIR}/agent_end_fired"
hook_script="${BASHCLAW_STATE_DIR}/hooks_scripts/ae_hook.sh"
mkdir -p "$(dirname "$hook_script")"
cat > "$hook_script" <<HEOF
#!/usr/bin/env bash
touch "$hook_marker"
HEOF
chmod +x "$hook_script"
hooks_register "test_ae" "agent_end" "$hook_script"
agent_run() { printf 'mock response'; }
engine_run "main" "test" "default" "" >/dev/null 2>&1
sleep 0.5  # agent_end uses void strategy (background execution)
if [[ -f "$hook_marker" ]]; then
  _test_pass
else
  _test_fail "agent_end hook was not fired"
fi
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "builtin engine reads maxTurns from config"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[{"id":"main","maxTurns":2}]}}
EOF
_CONFIG_CACHE=""
config_load
max_val="$(config_agent_get "main" "maxTurns" "10")"
assert_eq "$max_val" "2"
teardown_test_env

test_start "is_jq_empty utility works correctly"
setup_test_env
is_jq_empty "" && _test_pass "empty string" || _test_fail "empty string should be jq-empty"
is_jq_empty "null" && _test_pass "null" || _test_fail "null should be jq-empty"
is_jq_empty "[]" && _test_pass "empty array" || _test_fail "[] should be jq-empty"
is_jq_empty "{}" && _test_pass "empty object" || _test_fail "{} should be jq-empty"
is_jq_empty "hello" && _test_fail "non-empty should not be jq-empty" || _test_pass "non-empty string"
is_jq_empty '[1]' && _test_fail "non-empty array should not be jq-empty" || _test_pass "non-empty array"
teardown_test_env

report_results
