#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_process"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- process_enqueue / process_dequeue FIFO order ----

test_start "process_enqueue / process_dequeue FIFO order"
setup_test_env
_source_libs
id1="$(process_enqueue "main" "msg_alpha")"
sleep 0.1
id2="$(process_enqueue "main" "msg_beta")"
sleep 0.1
id3="$(process_enqueue "main" "msg_gamma")"

first="$(process_dequeue)"
first_cmd="$(printf '%s' "$first" | jq -r '.command')"
assert_eq "$first_cmd" "msg_alpha"

second="$(process_dequeue)"
second_cmd="$(printf '%s' "$second" | jq -r '.command')"
assert_eq "$second_cmd" "msg_beta"

third="$(process_dequeue)"
third_cmd="$(printf '%s' "$third" | jq -r '.command')"
assert_eq "$third_cmd" "msg_gamma"
teardown_test_env

# ---- process_status shows correct depth ----

test_start "process_status shows correct counts"
setup_test_env
_source_libs
process_enqueue "main" "a" >/dev/null
sleep 0.05
process_enqueue "main" "b" >/dev/null
sleep 0.05
process_enqueue "main" "c" >/dev/null
status="$(process_status)"
assert_json_valid "$status"
pending="$(printf '%s' "$status" | jq -r '.pending')"
assert_eq "$pending" "3"
teardown_test_env

# ---- Empty queue returns empty ----

test_start "empty queue dequeue returns failure"
setup_test_env
_source_libs
set +e
result="$(process_dequeue 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )); then
  _test_pass
else
  _test_fail "dequeue on empty queue should return non-zero"
fi
teardown_test_env

# ---- lane_get_queue_size returns 0 for empty lane ----

test_start "lane_get_queue_size returns 0 for empty lane"
setup_test_env
_source_libs
result="$(lane_get_queue_size "main")"
assert_eq "$result" "0"
teardown_test_env

# ---- queue_mode_resolve defaults to followup ----

test_start "queue_mode_resolve defaults to followup"
setup_test_env
_source_libs
result="$(queue_mode_resolve "sess1")"
assert_eq "$result" "followup"
teardown_test_env

# ---- queue_handle_busy followup mode queues message ----

test_start "queue_handle_busy followup mode queues message"
setup_test_env
_source_libs
result="$(queue_handle_busy "test_sess" "new message" "followup")"
assert_eq "$result" "queued"
pending="$(queue_drain_pending "test_sess")"
assert_json_valid "$pending"
count="$(printf '%s' "$pending" | jq 'length')"
assert_eq "$count" "1"
teardown_test_env

# ---- queue_handle_busy collect mode collects messages ----

test_start "queue_handle_busy collect mode returns collected"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"queueDebounceMs": 100}}
EOF
_CONFIG_CACHE=""
config_load
result="$(queue_handle_busy "collect_sess" "message one" "collect")"
assert_eq "$result" "collected"
teardown_test_env

# ---- queue_handle_busy interrupt mode creates abort signal ----

test_start "queue_handle_busy interrupt mode creates abort signal"
setup_test_env
_source_libs
result="$(queue_handle_busy "int_sess" "urgent message" "interrupt")"
assert_eq "$result" "interrupted"
if queue_check_abort "int_sess"; then
  _test_pass
else
  _test_fail "abort signal should exist"
fi
teardown_test_env

# ---- queue_drain_pending returns empty for no pending ----

test_start "queue_drain_pending returns empty for no pending"
setup_test_env
_source_libs
result="$(queue_drain_pending "empty_sess")"
assert_eq "$result" "[]"
teardown_test_env

# ---- queue_drain_pending clears queue after drain ----

test_start "queue_drain_pending clears queue after drain"
setup_test_env
_source_libs
queue_handle_busy "drain_sess" "msg1" "followup"
queue_handle_busy "drain_sess" "msg2" "followup"
first="$(queue_drain_pending "drain_sess")"
count="$(printf '%s' "$first" | jq 'length')"
assert_eq "$count" "2"
second="$(queue_drain_pending "drain_sess")"
count2="$(printf '%s' "$second" | jq 'length')"
assert_eq "$count2" "0"
teardown_test_env

# ---- queue_check_abort returns 1 when no abort ----

test_start "queue_check_abort returns 1 when no abort"
setup_test_env
_source_libs
set +e
queue_check_abort "no_abort_sess"
rc=$?
set -e
assert_eq "$rc" "1"
teardown_test_env

# ---- queue_is_session_busy returns 1 when not busy ----

test_start "queue_is_session_busy returns 1 when not busy"
setup_test_env
_source_libs
set +e
queue_is_session_busy "idle_sess"
rc=$?
set -e
assert_eq "$rc" "1"
teardown_test_env

# ---- _lane_max_for_type returns defaults ----

test_start "_lane_max_for_type returns correct defaults"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{}
EOF
_CONFIG_CACHE=""
config_load
main_max="$(_lane_max_for_type "main")"
assert_eq "$main_max" "$LANE_MAIN_MAX"
cron_max="$(_lane_max_for_type "cron")"
assert_eq "$cron_max" "$LANE_CRON_MAX"
sub_max="$(_lane_max_for_type "subagent")"
assert_eq "$sub_max" "$LANE_SUBAGENT_MAX"
nested_max="$(_lane_max_for_type "nested")"
assert_eq "$nested_max" "999999"
teardown_test_env

report_results
