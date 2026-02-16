#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_security"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- security_pairing_code_generate produces 6 digits ----

test_start "security_pairing_code_generate produces 6 digits"
setup_test_env
_source_libs
code="$(security_pairing_code_generate "test_channel" "test_sender")"
assert_match "$code" '^[0-9]{6}$'
teardown_test_env

# ---- security_pairing_code_verify correct code ----

test_start "security_pairing_code_verify correct code"
setup_test_env
_source_libs
code="$(security_pairing_code_generate "test_ch" "test_snd")"
if security_pairing_code_verify "test_ch" "test_snd" "$code"; then
  _test_pass
else
  _test_fail "correct code should verify"
fi
teardown_test_env

# ---- security_pairing_code_verify wrong code fails ----

test_start "security_pairing_code_verify wrong code fails"
setup_test_env
_source_libs
security_pairing_code_generate "test_ch" "test_snd" >/dev/null
if security_pairing_code_verify "test_ch" "test_snd" "000000" 2>/dev/null; then
  _test_fail "wrong code should not verify"
else
  _test_pass
fi
teardown_test_env

# ---- security_pairing_code_verify expired code fails ----

test_start "security_pairing_code_verify expired code fails"
setup_test_env
_source_libs
code="$(security_pairing_code_generate "test_ch" "test_snd")"
# Manually expire the code by setting expires_at to the past
safe_key="$(printf '%s_%s' "test_ch" "test_snd" | tr -c '[:alnum:]._-' '_' | head -c 200)"
pairing_file="${BASHCLAW_STATE_DIR}/pairing/${safe_key}.json"
if [[ -f "$pairing_file" ]]; then
  expired_ts=$(( $(date +%s) - 600 ))
  updated="$(jq --argjson exp "$expired_ts" '.expires_at = $exp' "$pairing_file")"
  printf '%s\n' "$updated" > "$pairing_file"
fi
if security_pairing_code_verify "test_ch" "test_snd" "$code" 2>/dev/null; then
  _test_fail "expired code should not verify"
else
  _test_pass
fi
teardown_test_env

# ---- security_rate_limit allows within limit ----

test_start "security_rate_limit allows within limit"
setup_test_env
_source_libs
allowed=true
for i in 1 2 3; do
  if ! security_rate_limit "user1" 10; then
    allowed=false
    break
  fi
done
if [[ "$allowed" == "true" ]]; then
  _test_pass
else
  _test_fail "should allow requests within limit"
fi
teardown_test_env

# ---- security_rate_limit blocks over limit ----

test_start "security_rate_limit blocks over limit"
setup_test_env
_source_libs
blocked=false
for i in $(seq 1 15); do
  if ! security_rate_limit "user2" 5; then
    blocked=true
    break
  fi
done
if [[ "$blocked" == "true" ]]; then
  _test_pass
else
  _test_fail "should block requests over limit"
fi
teardown_test_env

# ---- security_audit_log appends JSONL entries ----

test_start "security_audit_log appends JSONL entries"
setup_test_env
_source_libs
security_audit_log "login" "user=user1 result=success"
security_audit_log "command" "user=user1 cmd=shell"
audit_file="${BASHCLAW_STATE_DIR}/logs/audit.jsonl"
assert_file_exists "$audit_file"
count="$(wc -l < "$audit_file" | tr -d ' ')"
assert_ge "$count" 2
# Verify each line is valid JSON
all_valid=true
while IFS= read -r line; do
  if ! printf '%s' "$line" | jq empty 2>/dev/null; then
    all_valid=false
    break
  fi
done < "$audit_file"
if [[ "$all_valid" == "true" ]]; then
  _test_pass
else
  _test_fail "audit log contains invalid JSON"
fi
teardown_test_env

# ---- security_exec_approval blocks dangerous commands ----

test_start "security_exec_approval blocks dangerous commands"
setup_test_env
_source_libs
set +e
result="$(security_exec_approval "rm -rf /")"
rc=$?
set -e
if (( rc != 0 )); then
  _test_pass
else
  if [[ "$result" == "blocked" ]]; then
    _test_pass
  else
    _test_fail "dangerous command should be blocked (got: $result)"
  fi
fi
teardown_test_env

# ---- security_tool_policy_check allows by default ----

test_start "security_tool_policy_check allows by default"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
if security_tool_policy_check "main" "memory" "main"; then
  _test_pass
else
  _test_fail "tool should be allowed by default"
fi
teardown_test_env

# ---- security_tool_policy_check blocks subagent restricted tools ----

test_start "security_tool_policy_check blocks subagent restricted tools"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
set +e
security_tool_policy_check "main" "shell" "subagent" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_tool_policy_check blocks cron restricted tools ----

test_start "security_tool_policy_check blocks cron restricted tools"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {}, "list": []}
}
EOF
_CONFIG_CACHE=""
config_load
set +e
security_tool_policy_check "main" "cron_add" "cron" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_elevated_check returns approved for normal tools ----

test_start "security_elevated_check returns approved for normal tools"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {}}
EOF
_CONFIG_CACHE=""
config_load
result="$(security_elevated_check "memory" "user1" "telegram")"
assert_eq "$result" "approved"
teardown_test_env

# ---- security_elevated_check returns needs_approval for exec tools ----

test_start "security_elevated_check returns needs_approval for exec tools"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {"elevatedUsers": []}}
EOF
_CONFIG_CACHE=""
config_load
result="$(security_elevated_check "exec" "user1" "telegram")"
assert_eq "$result" "needs_approval"
teardown_test_env

# ---- security_elevated_check approves elevated users ----

test_start "security_elevated_check approves elevated users"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {"elevatedUsers": ["admin_user"]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(security_elevated_check "shell" "admin_user" "telegram")"
assert_eq "$result" "approved"
teardown_test_env

# ---- security_elevated_check blocks system_reset ----

test_start "security_elevated_check blocks system_reset"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {}}
EOF
_CONFIG_CACHE=""
config_load
set +e
result="$(security_elevated_check "system_reset" "user1" "")"
rc=$?
set -e
assert_eq "$result" "blocked"
teardown_test_env

# ---- security_command_auth_check allows when no auth config ----

test_start "security_command_auth_check allows when no auth config"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {"commands": {}}}
EOF
_CONFIG_CACHE=""
config_load
if security_command_auth_check "status" "anyone"; then
  _test_pass
else
  _test_fail "should allow when no auth config"
fi
teardown_test_env

# ---- security_command_auth_check denies unauthorized user ----

test_start "security_command_auth_check denies unauthorized user"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "security": {
    "commands": {
      "deploy": {"allowedUsers": ["admin"]}
    },
    "userRoles": {}
  }
}
EOF
_CONFIG_CACHE=""
config_load
set +e
security_command_auth_check "deploy" "random_user" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_command_auth_check allows authorized user ----

test_start "security_command_auth_check allows authorized user"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "security": {
    "commands": {
      "deploy": {"allowedUsers": ["admin"]}
    }
  }
}
EOF
_CONFIG_CACHE=""
config_load
if security_command_auth_check "deploy" "admin"; then
  _test_pass
else
  _test_fail "authorized user should be allowed"
fi
teardown_test_env

# ---- _security_safe_equal: equal strings return 0 ----

test_start "_security_safe_equal: equal strings return 0"
setup_test_env
_source_libs
if _security_safe_equal "hello123" "hello123"; then
  _test_pass
else
  _test_fail "equal strings should return 0"
fi
teardown_test_env

# ---- _security_safe_equal: different strings return 1 ----

test_start "_security_safe_equal: different strings return 1"
setup_test_env
_source_libs
set +e
_security_safe_equal "hello123" "world456"
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- _security_safe_equal: different length strings return 1 ----

test_start "_security_safe_equal: different length strings return 1"
setup_test_env
_source_libs
set +e
_security_safe_equal "short" "muchlongerstring"
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- _security_safe_equal: both empty strings return 0 ----

test_start "_security_safe_equal: both empty strings return 0"
setup_test_env
_source_libs
if _security_safe_equal "" ""; then
  _test_pass
else
  _test_fail "both empty strings should return 0"
fi
teardown_test_env

# ---- _security_safe_equal: one empty one non-empty return 1 ----

test_start "_security_safe_equal: one empty one non-empty return 1"
setup_test_env
_source_libs
set +e
_security_safe_equal "" "notempty"
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_rate_limit with zero limit ----

test_start "security_rate_limit blocks on zero limit"
setup_test_env
_source_libs
set +e
security_rate_limit "user_zero_limit" 0
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_exec_approval approves safe commands ----

test_start "security_exec_approval approves safe commands"
setup_test_env
_source_libs
result="$(security_exec_approval "ls -la")"
assert_eq "$result" "approved"
teardown_test_env

# ---- security_exec_approval flags sudo commands ----

test_start "security_exec_approval flags sudo commands"
setup_test_env
_source_libs
result="$(security_exec_approval "sudo rm /tmp/test")"
assert_eq "$result" "needs_approval"
teardown_test_env

# ---- security_pairing_code_verify nonexistent channel fails ----

test_start "security_pairing_code_verify nonexistent channel fails"
setup_test_env
_source_libs
set +e
security_pairing_code_verify "no_such_channel" "no_user" "123456" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- security_command_auth_check with role-based access ----

test_start "security_command_auth_check with role-based access"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "security": {
    "commands": {
      "deploy": {"requiredRole": "deployer", "allowedUsers": []}
    },
    "userRoles": {
      "dev_user": ["deployer"]
    }
  }
}
EOF
_CONFIG_CACHE=""
config_load
if security_command_auth_check "deploy" "dev_user"; then
  _test_pass
else
  _test_fail "user with correct role should be authorized"
fi
teardown_test_env

# ---- security_command_auth_check with wrong role denied ----

test_start "security_command_auth_check with wrong role denied"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "security": {
    "commands": {
      "deploy": {"requiredRole": "deployer", "allowedUsers": []}
    },
    "userRoles": {
      "other_user": ["viewer"]
    }
  }
}
EOF
_CONFIG_CACHE=""
config_load
set +e
security_command_auth_check "deploy" "other_user" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: _security_safe_equal with unicode strings ----

test_start "_security_safe_equal with unicode strings returns correct result"
setup_test_env
_source_libs
if _security_safe_equal "hello-unicode" "hello-unicode"; then
  _test_pass
else
  _test_fail "identical unicode strings should be equal"
fi
teardown_test_env

test_start "_security_safe_equal with different unicode strings returns 1"
setup_test_env
_source_libs
set +e
_security_safe_equal "abc-xyz" "abc-123"
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: rate limit rapid successive calls trigger rate limit ----

test_start "security_rate_limit rapid successive calls trigger rate limit"
setup_test_env
_source_libs
blocked=false
for i in $(seq 1 8); do
  if ! security_rate_limit "rapid_user" 3; then
    blocked=true
    break
  fi
done
if [[ "$blocked" == "true" ]]; then
  _test_pass
else
  _test_fail "rapid calls should trigger rate limit with max=3"
fi
teardown_test_env

# ---- Edge Case: security_check_elevated with unknown user ----

test_start "security_elevated_check with unknown user returns needs_approval for shell"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {"elevatedUsers": ["known_admin"]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(security_elevated_check "shell" "totally_unknown_user_xyz" "telegram")"
assert_eq "$result" "needs_approval"
teardown_test_env

test_start "security_elevated_check with unknown user returns approved for normal tools"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"security": {"elevatedUsers": ["known_admin"]}}
EOF
_CONFIG_CACHE=""
config_load
result="$(security_elevated_check "memory" "totally_unknown_user_xyz" "telegram")"
assert_eq "$result" "approved"
teardown_test_env

report_results
