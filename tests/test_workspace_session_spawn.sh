#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-bootstrap"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

begin_test_file "test_workspace_session_spawn"

# ============================================================
# Feature 1: Workspace Bootstrap Files
# ============================================================

# ---- workspace_init ----

test_start "workspace_init creates directory structure"
setup_test_env
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/SOUL.md"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/USER.md"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/MEMORY.md"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/TOOLS.md"
assert_file_exists "${BASHCLAW_STATE_DIR}/workspace/AGENTS.md"
teardown_test_env

test_start "workspace_init creates skills and memory directories"
setup_test_env
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
if [[ -d "${BASHCLAW_STATE_DIR}/workspace/skills" ]]; then
  _test_pass
else
  _test_fail "skills directory not created"
fi
if [[ -d "${BASHCLAW_STATE_DIR}/workspace/memory" ]]; then
  _test_pass
else
  _test_fail "memory directory not created"
fi
teardown_test_env

test_start "workspace_init does not overwrite existing files"
setup_test_env
mkdir -p "${BASHCLAW_STATE_DIR}/workspace"
printf 'custom identity' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
content="$(cat "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md")"
assert_eq "$content" "custom identity"
teardown_test_env

test_start "workspace_init IDENTITY.md has default content"
setup_test_env
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
content="$(cat "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md")"
assert_contains "$content" "BashClaw"
teardown_test_env

test_start "workspace_init SOUL.md has default content"
setup_test_env
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
content="$(cat "${BASHCLAW_STATE_DIR}/workspace/SOUL.md")"
assert_contains "$content" "concisely"
teardown_test_env

# ---- agent_load_workspace_bootstrap ----

test_start "agent_load_workspace_bootstrap loads IDENTITY.md"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
printf 'Test identity content' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
result="$(agent_load_workspace_bootstrap "main")"
assert_contains "$result" "[Identity]"
assert_contains "$result" "Test identity content"
teardown_test_env

test_start "agent_load_workspace_bootstrap loads multiple files"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
printf 'My identity' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
printf 'My soul' > "${BASHCLAW_STATE_DIR}/workspace/SOUL.md"
printf 'User prefs' > "${BASHCLAW_STATE_DIR}/workspace/USER.md"
result="$(agent_load_workspace_bootstrap "main")"
assert_contains "$result" "[Identity]"
assert_contains "$result" "[Soul]"
assert_contains "$result" "[User]"
assert_contains "$result" "My identity"
assert_contains "$result" "My soul"
assert_contains "$result" "User prefs"
teardown_test_env

test_start "agent_load_workspace_bootstrap skips empty files"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
printf 'Has content' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
: > "${BASHCLAW_STATE_DIR}/workspace/SOUL.md"
result="$(agent_load_workspace_bootstrap "main")"
assert_contains "$result" "[Identity]"
assert_not_contains "$result" "[Soul]"
teardown_test_env

test_start "agent_load_workspace_bootstrap returns empty for missing workspace"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"workspace": "/nonexistent/path"}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
result="$(agent_load_workspace_bootstrap "main")"
assert_eq "$result" ""
teardown_test_env

test_start "agent_build_system_prompt includes workspace bootstrap"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
printf 'Custom agent identity' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
result="$(agent_build_system_prompt "main")"
assert_contains "$result" "[Identity]"
assert_contains "$result" "Custom agent identity"
teardown_test_env

test_start "agent_build_system_prompt skips workspace bootstrap for subagents"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
workspace_init "${BASHCLAW_STATE_DIR}/workspace"
printf 'Should not appear for subagent' > "${BASHCLAW_STATE_DIR}/workspace/IDENTITY.md"
result="$(agent_build_system_prompt "main" "true")"
assert_not_contains "$result" "[Identity]"
assert_not_contains "$result" "Should not appear for subagent"
teardown_test_env

# ============================================================
# Feature 2: Session JSONL Header
# ============================================================

# ---- session_ensure_header ----

test_start "session_ensure_header creates header for new file"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="${BASHCLAW_STATE_DIR}/sessions/header_test.jsonl"
mkdir -p "$(dirname "$f")"
session_ensure_header "$f"
assert_file_exists "$f"
first_line="$(head -n 1 "$f")"
assert_contains "$first_line" '"type":"session"'
assert_contains "$first_line" '"engine":"bashclaw"'
assert_contains "$first_line" '"version":"1"'
teardown_test_env

test_start "session_ensure_header is idempotent"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="${BASHCLAW_STATE_DIR}/sessions/header_test2.jsonl"
mkdir -p "$(dirname "$f")"
session_ensure_header "$f"
lines_before="$(wc -l < "$f" | tr -d ' ')"
session_ensure_header "$f"
lines_after="$(wc -l < "$f" | tr -d ' ')"
assert_eq "$lines_before" "$lines_after"
teardown_test_env

test_start "session_ensure_header prepends to existing headerless file"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="${BASHCLAW_STATE_DIR}/sessions/header_test3.jsonl"
mkdir -p "$(dirname "$f")"
printf '{"role":"user","content":"hello","ts":12345}\n' > "$f"
session_ensure_header "$f"
first_line="$(head -n 1 "$f")"
assert_contains "$first_line" '"type":"session"'
second_line="$(sed -n '2p' "$f")"
assert_contains "$second_line" '"role":"user"'
teardown_test_env

# ---- session_append writes header ----

test_start "session_append auto-creates header"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="$(session_file "main" "test")"
session_append "$f" "user" "hello world"
first_line="$(head -n 1 "$f")"
assert_contains "$first_line" '"type":"session"'
second_line="$(sed -n '2p' "$f")"
assert_contains "$second_line" '"role":"user"'
assert_contains "$second_line" "hello world"
teardown_test_env

# ---- session_load skips header ----

test_start "session_load skips header line"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="$(session_file "main" "test")"
session_append "$f" "user" "msg1"
session_append "$f" "assistant" "reply1"
result="$(session_load "$f")"
assert_json_valid "$result"
length="$(printf '%s' "$result" | jq 'length')"
assert_eq "$length" "2"
# Verify no session header in loaded messages
has_header="$(printf '%s' "$result" | jq '[.[] | select(.type == "session")] | length')"
assert_eq "$has_header" "0"
teardown_test_env

# ---- session_count excludes header ----

test_start "session_count excludes header line"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="$(session_file "main" "test")"
session_append "$f" "user" "msg1"
session_append "$f" "assistant" "reply1"
session_append "$f" "user" "msg2"
count="$(session_count "$f")"
assert_eq "$count" "3"
teardown_test_env

# ---- agent_build_messages skips header ----

test_start "agent_build_messages excludes session header"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="$(session_file "main" "test")"
session_append "$f" "user" "hello"
session_append "$f" "assistant" "hi"
result="$(agent_build_messages "$f" "new q" 50)"
assert_json_valid "$result"
length="$(printf '%s' "$result" | jq 'length')"
assert_eq "$length" "3"
# No header lines should appear as messages
has_session_type="$(printf '%s' "$result" | jq '[.[] | select(.role == null or .role == "")] | length')"
assert_eq "$has_session_type" "0"
teardown_test_env

# ---- session header has correct format ----

test_start "session header contains valid JSON with required fields"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
f="$(session_file "main" "test")"
session_ensure_header "$f"
first_line="$(head -n 1 "$f")"
assert_json_valid "$first_line"
header_type="$(printf '%s' "$first_line" | jq -r '.type')"
assert_eq "$header_type" "session"
header_version="$(printf '%s' "$first_line" | jq -r '.version')"
assert_eq "$header_version" "1"
header_engine="$(printf '%s' "$first_line" | jq -r '.engine')"
assert_eq "$header_engine" "bashclaw"
header_id="$(printf '%s' "$first_line" | jq -r '.id')"
assert_ne "$header_id" ""
assert_ne "$header_id" "null"
header_ts="$(printf '%s' "$first_line" | jq -r '.timestamp')"
assert_ne "$header_ts" ""
assert_ne "$header_ts" "null"
teardown_test_env

# ============================================================
# Feature 3: Spawn Tool
# ============================================================

# ---- tool_spawn basic ----

test_start "tool_spawn requires task parameter"
setup_test_env
result="$(tool_spawn '{}' 2>/dev/null)" || true
assert_contains "$result" "error"
assert_contains "$result" "task"
teardown_test_env

test_start "tool_spawn returns spawn ID"
setup_test_env
result="$(tool_spawn '{"task":"test task","label":"test-label"}')"
assert_contains "$result" "test-label"
assert_contains "$result" "started"
assert_contains "$result" "spawn_status"
teardown_test_env

test_start "tool_spawn creates status file"
setup_test_env
result="$(tool_spawn '{"task":"test task","label":"mytest"}')"
# Extract spawn ID from response
spawn_id="$(printf '%s' "$result" | grep -o 'id: [a-f0-9]*' | awk '{print $2}')"
if [[ -n "$spawn_id" ]]; then
  status_file="${BASHCLAW_STATE_DIR}/spawn/${spawn_id}.json"
  # Give a small delay for file creation
  sleep 0.2
  assert_file_exists "$status_file"
  status_content="$(cat "$status_file")"
  assert_json_valid "$status_content"
  status_val="$(printf '%s' "$status_content" | jq -r '.status')"
  # Status is either "running" or "completed" depending on timing
  if [[ "$status_val" == "running" || "$status_val" == "completed" ]]; then
    _test_pass
  else
    _test_fail "unexpected status: $status_val"
  fi
else
  _test_fail "could not extract spawn ID from response: $result"
fi
teardown_test_env

# ---- tool_spawn_status ----

test_start "tool_spawn_status requires task_id parameter"
setup_test_env
result="$(tool_spawn_status '{}' 2>/dev/null)" || true
assert_contains "$result" "error"
assert_contains "$result" "task_id"
teardown_test_env

test_start "tool_spawn_status returns error for unknown task"
setup_test_env
result="$(tool_spawn_status '{"task_id":"nonexistent123"}')"
assert_contains "$result" "error"
assert_contains "$result" "not found"
teardown_test_env

test_start "tool_spawn_status reads existing status file"
setup_test_env
mkdir -p "${BASHCLAW_STATE_DIR}/spawn"
printf '{"id":"abc12345","label":"test","status":"running","started_at":"2025-01-01T00:00:00Z"}\n' \
  > "${BASHCLAW_STATE_DIR}/spawn/abc12345.json"
result="$(tool_spawn_status '{"task_id":"abc12345"}')"
assert_json_valid "$result"
status="$(printf '%s' "$result" | jq -r '.status')"
assert_eq "$status" "running"
label="$(printf '%s' "$result" | jq -r '.label')"
assert_eq "$label" "test"
teardown_test_env

test_start "tool_spawn_status reads completed status"
setup_test_env
mkdir -p "${BASHCLAW_STATE_DIR}/spawn"
printf '{"id":"def67890","label":"done","status":"completed","result":"all done","completed_at":"2025-01-01T01:00:00Z"}\n' \
  > "${BASHCLAW_STATE_DIR}/spawn/def67890.json"
result="$(tool_spawn_status '{"task_id":"def67890"}')"
assert_json_valid "$result"
status="$(printf '%s' "$result" | jq -r '.status')"
assert_eq "$status" "completed"
result_text="$(printf '%s' "$result" | jq -r '.result')"
assert_eq "$result_text" "all done"
teardown_test_env

# ---- spawn tools registered in spec ----

test_start "tools_build_spec includes spawn tool"
setup_test_env
result="$(tools_build_spec)"
names="$(printf '%s' "$result" | jq -r '.[].name')"
assert_contains "$names" "spawn"
teardown_test_env

test_start "tools_build_spec includes spawn_status tool"
setup_test_env
result="$(tools_build_spec)"
names="$(printf '%s' "$result" | jq -r '.[].name')"
assert_contains "$names" "spawn_status"
teardown_test_env

test_start "tool_execute dispatches spawn_status"
setup_test_env
mkdir -p "${BASHCLAW_STATE_DIR}/spawn"
printf '{"id":"test123","status":"running"}\n' > "${BASHCLAW_STATE_DIR}/spawn/test123.json"
result="$(tool_execute "spawn_status" '{"task_id":"test123"}')"
assert_json_valid "$result"
assert_contains "$result" "running"
teardown_test_env

report_results
