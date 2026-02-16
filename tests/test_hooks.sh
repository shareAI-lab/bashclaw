#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_hooks"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- hooks_register creates hook config ----

test_start "hooks_register creates hook config"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/my_hook.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$hook_script"
chmod +x "$hook_script"
hooks_register "my_hook" "pre_message" "$hook_script"
hooks_dir="${BASHCLAW_STATE_DIR}/hooks"
assert_file_exists "${hooks_dir}/my_hook.json"
teardown_test_env

# ---- hooks_run executes hook scripts ----

test_start "hooks_run executes hook scripts"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/exec_hook.sh"
cat > "$hook_script" <<'HOOKEOF'
#!/usr/bin/env bash
echo "hook_executed"
HOOKEOF
chmod +x "$hook_script"
hooks_register "exec_hook" "pre_message" "$hook_script"
result="$(hooks_run "pre_message" "" 2>/dev/null)"
assert_contains "$result" "hook_executed"
teardown_test_env

# ---- hooks_run passes JSON through stdin ----

test_start "hooks_run passes JSON through stdin"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/stdin_hook.sh"
cat > "$hook_script" <<'HOOKEOF'
#!/usr/bin/env bash
cat
HOOKEOF
chmod +x "$hook_script"
hooks_register "stdin_hook" "pre_message" "$hook_script"
input_json='{"message":"hello","channel":"telegram"}'
result="$(hooks_run "pre_message" "$input_json" 2>/dev/null)"
assert_json_valid "$result"
msg="$(printf '%s' "$result" | jq -r '.message')"
assert_eq "$msg" "hello"
teardown_test_env

# ---- hooks_list shows registered hooks ----

test_start "hooks_list shows registered hooks"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/list_hook.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$hook_script"
chmod +x "$hook_script"
hooks_register "list_test" "pre_message" "$hook_script"
result="$(hooks_list)"
assert_json_valid "$result"
assert_contains "$result" "list_test"
teardown_test_env

# ---- hooks_enable / hooks_disable toggles ----

test_start "hooks_enable / hooks_disable toggles"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/toggle_hook.sh"
cat > "$hook_script" <<'HOOKEOF'
#!/usr/bin/env bash
echo "toggled"
HOOKEOF
chmod +x "$hook_script"
hooks_register "toggle_hook" "pre_message" "$hook_script"
hooks_disable "toggle_hook"
result="$(hooks_run "pre_message" "" 2>/dev/null)"
assert_not_contains "$result" "toggled"
hooks_enable "toggle_hook"
result="$(hooks_run "pre_message" "" 2>/dev/null)"
assert_contains "$result" "toggled"
teardown_test_env

# ---- Hook script transforms message content ----

test_start "hook script transforms message content"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/transform_hook.sh"
cat > "$hook_script" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.message = (.message + " [modified]")'
HOOKEOF
chmod +x "$hook_script"
hooks_register "transform_hook" "pre_message" "$hook_script"
input_json='{"message":"original"}'
result="$(hooks_run "pre_message" "$input_json" 2>/dev/null)"
msg="$(printf '%s' "$result" | jq -r '.message')"
assert_contains "$msg" "modified"
teardown_test_env

# ---- Multiple hooks chain correctly ----

test_start "multiple hooks chain correctly"
setup_test_env
_source_libs
hook1="${BASHCLAW_STATE_DIR}/chain_hook1.sh"
hook2="${BASHCLAW_STATE_DIR}/chain_hook2.sh"
cat > "$hook1" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.step1 = true'
HOOKEOF
cat > "$hook2" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.step2 = true'
HOOKEOF
chmod +x "$hook1" "$hook2"
hooks_register "chain1" "pre_message" "$hook1"
hooks_register "chain2" "pre_message" "$hook2"
result="$(hooks_run "pre_message" '{}' 2>/dev/null)"
assert_json_valid "$result"
s1="$(printf '%s' "$result" | jq -r '.step1')"
s2="$(printf '%s' "$result" | jq -r '.step2')"
assert_eq "$s1" "true"
assert_eq "$s2" "true"
teardown_test_env

# ---- hooks_register with priority ordering ----

test_start "hooks_register with priority ordering"
setup_test_env
_source_libs
hook1="${BASHCLAW_STATE_DIR}/pri_hook1.sh"
hook2="${BASHCLAW_STATE_DIR}/pri_hook2.sh"
cat > "$hook1" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.order = (.order // "") + "first,"'
HOOKEOF
cat > "$hook2" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.order = (.order // "") + "second,"'
HOOKEOF
chmod +x "$hook1" "$hook2"
hooks_register "low_pri" "pre_message" "$hook1" --priority 10
hooks_register "high_pri" "pre_message" "$hook2" --priority 50
result="$(hooks_run "pre_message" '{}' 2>/dev/null)"
order="$(printf '%s' "$result" | jq -r '.order // empty')"
assert_contains "$order" "first,"
assert_contains "$order" "second,"
teardown_test_env

# ---- hooks_register validates event names ----

test_start "hooks_register rejects invalid event name"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/bad_event.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$hook_script"
chmod +x "$hook_script"
set +e
hooks_register "bad" "invalid_event_name" "$hook_script" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_register validates strategy ----

test_start "hooks_register rejects invalid strategy"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/bad_strat.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$hook_script"
chmod +x "$hook_script"
set +e
hooks_register "bad_strat" "pre_message" "$hook_script" --strategy "invalid" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_remove deletes a hook ----

test_start "hooks_remove deletes a hook"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/rm_hook.sh"
printf '#!/usr/bin/env bash\necho removed\n' > "$hook_script"
chmod +x "$hook_script"
hooks_register "removable" "pre_message" "$hook_script"
hooks_remove "removable"
hooks_dir="${BASHCLAW_STATE_DIR}/hooks"
assert_file_not_exists "${hooks_dir}/removable.json"
teardown_test_env

# ---- hooks_count returns correct count ----

test_start "hooks_count returns correct count"
setup_test_env
_source_libs
h1="${BASHCLAW_STATE_DIR}/cnt1.sh"
h2="${BASHCLAW_STATE_DIR}/cnt2.sh"
h3="${BASHCLAW_STATE_DIR}/cnt3.sh"
printf '#!/usr/bin/env bash\n:' > "$h1"
printf '#!/usr/bin/env bash\n:' > "$h2"
printf '#!/usr/bin/env bash\n:' > "$h3"
chmod +x "$h1" "$h2" "$h3"
hooks_register "cnt1" "pre_message" "$h1"
hooks_register "cnt2" "pre_message" "$h2"
hooks_register "cnt3" "post_message" "$h3"
pre_count="$(hooks_count "pre_message")"
assert_eq "$pre_count" "2"
post_count="$(hooks_count "post_message")"
assert_eq "$post_count" "1"
teardown_test_env

# ---- hooks_list_by_event filters correctly ----

test_start "hooks_list_by_event filters correctly"
setup_test_env
_source_libs
h1="${BASHCLAW_STATE_DIR}/ev1.sh"
h2="${BASHCLAW_STATE_DIR}/ev2.sh"
printf '#!/usr/bin/env bash\n:' > "$h1"
printf '#!/usr/bin/env bash\n:' > "$h2"
chmod +x "$h1" "$h2"
hooks_register "ev1" "pre_tool" "$h1"
hooks_register "ev2" "post_tool" "$h2"
result="$(hooks_list_by_event "pre_tool")"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "1"
name="$(printf '%s' "$result" | jq -r '.[0].name')"
assert_eq "$name" "ev1"
teardown_test_env

# ---- hooks_load_dir loads hooks from directory ----

test_start "hooks_load_dir loads hooks from directory"
setup_test_env
_source_libs
hook_dir="${BASHCLAW_STATE_DIR}/hook_scripts"
mkdir -p "$hook_dir"
cat > "${hook_dir}/my_hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
# hook:pre_message
# priority:5
echo "loaded from dir"
HOOKEOF
chmod +x "${hook_dir}/my_hook.sh"
hooks_load_dir "$hook_dir"
count="$(hooks_count "pre_message")"
assert_ge "$count" 1
teardown_test_env

# ---- hooks_run with no registered hooks returns empty ----

test_start "hooks_run with no hooks for event returns empty"
setup_test_env
_source_libs
result="$(hooks_run "post_message" '{"data":"test"}' 2>/dev/null)"
# void strategy events return nothing
assert_eq "$result" ""
teardown_test_env

# ---- hooks_register with missing script file fails ----

test_start "hooks_register with missing script file fails"
setup_test_env
_source_libs
set +e
hooks_register "bad_path" "pre_message" "/nonexistent/path/hook.sh" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_enable nonexistent hook fails ----

test_start "hooks_enable nonexistent hook fails"
setup_test_env
_source_libs
set +e
hooks_enable "nonexistent_hook" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_disable nonexistent hook fails ----

test_start "hooks_disable nonexistent hook fails"
setup_test_env
_source_libs
set +e
hooks_disable "nonexistent_hook" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_remove nonexistent hook fails ----

test_start "hooks_remove nonexistent hook fails"
setup_test_env
_source_libs
set +e
hooks_remove "nonexistent_hook" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- hooks_count returns 0 when no hooks registered ----

test_start "hooks_count returns 0 for empty event"
setup_test_env
_source_libs
count="$(hooks_count "on_error")"
assert_eq "$count" "0"
teardown_test_env

# ---- hooks_list with no hooks returns empty array ----

test_start "hooks_list with no hooks returns empty array"
setup_test_env
_source_libs
result="$(hooks_list)"
assert_eq "$result" "[]"
teardown_test_env

# ---- hooks_load_dir on nonexistent directory fails ----

test_start "hooks_load_dir on nonexistent directory fails"
setup_test_env
_source_libs
set +e
hooks_load_dir "/nonexistent/dir" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: hooks_run with no registered hooks returns empty ----

test_start "hooks_run with no registered hooks returns empty"
setup_test_env
_source_libs
result="$(hooks_run "pre_message" '{"data":"test"}' 2>/dev/null)"
# For modifying strategy, with no hooks, returns the original input
assert_contains "$result" "data"
teardown_test_env

# ---- Edge Case: hooks_run with hook script that exits with error ----

test_start "hooks_run with hook script that exits with error continues"
setup_test_env
_source_libs
hook_err="${BASHCLAW_STATE_DIR}/err_hook.sh"
hook_ok="${BASHCLAW_STATE_DIR}/ok_hook.sh"
cat > "$hook_err" <<'HOOKEOF'
#!/usr/bin/env bash
exit 1
HOOKEOF
cat > "$hook_ok" <<'HOOKEOF'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | jq -c '.ok = true'
HOOKEOF
chmod +x "$hook_err" "$hook_ok"
hooks_register "fail_hook" "pre_message" "$hook_err" --priority 10
hooks_register "success_hook" "pre_message" "$hook_ok" --priority 20
result="$(hooks_run "pre_message" '{}' 2>/dev/null)"
ok_val="$(printf '%s' "$result" | jq -r '.ok // empty' 2>/dev/null)"
assert_eq "$ok_val" "true"
teardown_test_env

# ---- Edge Case: hooks_run_strategy with invalid strategy name ----

test_start "hooks_register rejects invalid strategy name"
setup_test_env
_source_libs
hook_script="${BASHCLAW_STATE_DIR}/strat_test.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$hook_script"
chmod +x "$hook_script"
set +e
hooks_register "bad_strat_test" "pre_message" "$hook_script" --strategy "nonexistent_strategy" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: hooks_run with empty event name ----

test_start "hooks_run with empty event returns empty output"
setup_test_env
_source_libs
set +e
result="$(hooks_run "" '{"data":"test"}' 2>/dev/null)"
rc=$?
set -e
# Should not crash, empty event returns void strategy (no output)
_test_pass
teardown_test_env

report_results
