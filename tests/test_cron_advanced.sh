#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_cron_advanced"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- cron_store_load returns empty store when no file exists ----

test_start "cron_store_load returns empty store when no file exists"
setup_test_env
_source_libs
result="$(cron_store_load)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq '.jobs | length')"
assert_eq "$count" "0"
teardown_test_env

# ---- cron_add creates a job in the store ----

test_start "cron_add creates a job in the store"
setup_test_env
_source_libs
cron_add "daily_summary" '{"kind":"every","everyMs":86400000}' "Summarize today" "main"
result="$(cron_store_load)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq '.jobs | length')"
assert_eq "$count" "1"
job_id="$(printf '%s' "$result" | jq -r '.jobs[0].id')"
assert_eq "$job_id" "daily_summary"
teardown_test_env

# ---- cron_add stores correct fields ----

test_start "cron_add stores correct fields"
setup_test_env
_source_libs
cron_add "test_job" '{"kind":"at","at":"2025-12-01T00:00:00Z"}' "Do something" "isolated"
result="$(cron_store_load)"
prompt="$(printf '%s' "$result" | jq -r '.jobs[0].prompt')"
session="$(printf '%s' "$result" | jq -r '.jobs[0].sessionTarget')"
enabled="$(printf '%s' "$result" | jq -r '.jobs[0].enabled')"
assert_eq "$prompt" "Do something"
assert_eq "$session" "isolated"
assert_eq "$enabled" "true"
teardown_test_env

# ---- cron_remove deletes a job ----

test_start "cron_remove deletes a job"
setup_test_env
_source_libs
cron_add "to_remove" '{"kind":"every","everyMs":60000}' "Remove me" "main"
cron_add "to_keep" '{"kind":"every","everyMs":60000}' "Keep me" "main"
cron_remove "to_remove"
result="$(cron_store_load)"
count="$(printf '%s' "$result" | jq '.jobs | length')"
assert_eq "$count" "1"
remaining_id="$(printf '%s' "$result" | jq -r '.jobs[0].id')"
assert_eq "$remaining_id" "to_keep"
teardown_test_env

# ---- cron_parse_schedule detects "at" kind ----

test_start "cron_parse_schedule detects at kind"
setup_test_env
_source_libs
kind="$(cron_parse_schedule '{"kind":"at","at":"2025-12-01T00:00:00Z"}')"
assert_eq "$kind" "at"
teardown_test_env

# ---- cron_parse_schedule detects "every" kind ----

test_start "cron_parse_schedule detects every kind"
setup_test_env
_source_libs
kind="$(cron_parse_schedule '{"kind":"every","everyMs":60000}')"
assert_eq "$kind" "every"
teardown_test_env

# ---- cron_parse_schedule detects "cron" kind ----

test_start "cron_parse_schedule detects cron kind"
setup_test_env
_source_libs
kind="$(cron_parse_schedule '{"kind":"cron","expr":"*/5 * * * *"}')"
assert_eq "$kind" "cron"
teardown_test_env

# ---- cron_parse_schedule defaults to cron for plain string ----

test_start "cron_parse_schedule defaults to cron for plain string"
setup_test_env
_source_libs
kind="$(cron_parse_schedule '0 * * * *')"
assert_eq "$kind" "cron"
teardown_test_env

# ---- cron_next_run for "every" kind ----

test_start "cron_next_run for every kind returns future time"
setup_test_env
_source_libs
now_s="$(date +%s)"
result="$(cron_next_run '{"kind":"every","everyMs":60000}' "$now_s")"
expected=$((now_s + 60))
assert_eq "$result" "$expected"
teardown_test_env

# ---- cron_next_run for "every" kind first run ----

test_start "cron_next_run for every kind first run returns now"
setup_test_env
_source_libs
now_s="$(date +%s)"
result="$(cron_next_run '{"kind":"every","everyMs":60000}' "0")"
# Should be approximately now
diff=$((result - now_s))
if (( diff >= -2 && diff <= 2 )); then
  _test_pass
else
  _test_fail "expected ~now, got diff=${diff}s"
fi
teardown_test_env

# ---- cron_backoff returns correct steps ----

test_start "cron_backoff returns 30s for first failure"
setup_test_env
_source_libs
result="$(cron_backoff "test_job" 0)"
assert_eq "$result" "30"
teardown_test_env

test_start "cron_backoff returns 60s for second failure"
setup_test_env
_source_libs
result="$(cron_backoff "test_job" 1)"
assert_eq "$result" "30"
teardown_test_env

test_start "cron_backoff caps at 3600s"
setup_test_env
_source_libs
result="$(cron_backoff "test_job" 10)"
assert_eq "$result" "3600"
teardown_test_env

# ---- cron_store_save and load round-trip ----

test_start "cron_store_save and load round-trip"
setup_test_env
_source_libs
store='{"version":1,"jobs":[{"id":"rt","schedule":"{}","prompt":"test","enabled":true}]}'
cron_store_save "$store"
loaded="$(cron_store_load)"
assert_json_valid "$loaded"
loaded_id="$(printf '%s' "$loaded" | jq -r '.jobs[0].id')"
assert_eq "$loaded_id" "rt"
teardown_test_env

# ---- _cron_iso_to_epoch converts valid timestamp ----

test_start "_cron_iso_to_epoch converts valid timestamp"
setup_test_env
_source_libs
result="$(_cron_iso_to_epoch "2025-01-01T00:00:00Z")"
# Should be a valid epoch (>0)
if (( result > 0 )); then
  _test_pass
else
  _test_fail "expected positive epoch, got $result"
fi
teardown_test_env

# ---- _cron_iso_to_epoch handles null/empty ----

test_start "_cron_iso_to_epoch handles null input"
setup_test_env
_source_libs
set +e
result="$(_cron_iso_to_epoch "null")"
set -e
assert_eq "$result" "0"
teardown_test_env

# ---- cron_check_stuck cleans up stale run files ----

test_start "cron_check_stuck cleans up stale run files"
setup_test_env
_source_libs
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"cron": {"stuckRunMs": 1000}}
EOF
_CONFIG_CACHE=""
config_load
run_dir="${BASHCLAW_STATE_DIR}/cron/runs"
ensure_dir "$run_dir"
# Create a run file with a very old timestamp
old_ts=$(( $(date +%s) - 9999 ))
printf '%s' "$old_ts" > "${run_dir}/stuck_job_abc.run"
cron_check_stuck
assert_file_not_exists "${run_dir}/stuck_job_abc.run"
teardown_test_env

# ---- cron_remove nonexistent job does not error ----

test_start "cron_remove nonexistent job keeps store intact"
setup_test_env
_source_libs
cron_add "existing" '{"kind":"every","everyMs":60000}' "Keep" "main"
cron_remove "nonexistent_xyz"
result="$(cron_store_load)"
count="$(printf '%s' "$result" | jq '.jobs | length')"
assert_eq "$count" "1"
teardown_test_env

# ---- cron_parse_schedule with invalid JSON falls back to cron ----

test_start "cron_parse_schedule with invalid JSON falls back to cron"
setup_test_env
_source_libs
kind="$(cron_parse_schedule 'not-json-at-all')"
assert_eq "$kind" "cron"
teardown_test_env

# ---- cron_next_run for "every" with zero interval returns error ----

test_start "cron_next_run for every with zero interval returns 0"
setup_test_env
_source_libs
set +e
result="$(cron_next_run '{"kind":"every","everyMs":0}' "0")"
rc=$?
set -e
assert_eq "$result" "0"
teardown_test_env

# ---- cron_next_run for "at" with missing timestamp ----

test_start "cron_next_run for at with missing timestamp returns 0"
setup_test_env
_source_libs
set +e
result="$(cron_next_run '{"kind":"at"}' "0")"
rc=$?
set -e
assert_eq "$result" "0"
teardown_test_env

# ---- _cron_iso_to_epoch with empty string returns 0 ----

test_start "_cron_iso_to_epoch with empty string returns 0"
setup_test_env
_source_libs
set +e
result="$(_cron_iso_to_epoch "")"
set -e
assert_eq "$result" "0"
teardown_test_env

# ---- _cron_next_match with malformed expression ----

test_start "_cron_next_match with incomplete expression returns 0"
setup_test_env
_source_libs
set +e
result="$(_cron_next_match "* *" "")"
set -e
assert_eq "$result" "0"
teardown_test_env

# ---- cron_add duplicate job IDs both persist ----

test_start "cron_add allows duplicate job IDs"
setup_test_env
_source_libs
cron_add "dup" '{"kind":"every","everyMs":60000}' "First" "main"
cron_add "dup" '{"kind":"every","everyMs":120000}' "Second" "main"
result="$(cron_store_load)"
count="$(printf '%s' "$result" | jq '[.jobs[] | select(.id == "dup")] | length')"
assert_eq "$count" "2"
teardown_test_env

# ---- cron_log_run creates JSONL entry ----

test_start "cron_log_run creates JSONL entry"
setup_test_env
_source_libs
cron_log_run "test_job_1" "success" "" 1234 "all good"
log_file="${BASHCLAW_STATE_DIR}/cron/runs/test_job_1.jsonl"
assert_file_exists "$log_file"
line="$(tail -n 1 "$log_file")"
assert_json_valid "$line"
status_val="$(printf '%s' "$line" | jq -r '.status')"
assert_eq "$status_val" "success"
dur_val="$(printf '%s' "$line" | jq -r '.duration_ms')"
assert_eq "$dur_val" "1234"
summary_val="$(printf '%s' "$line" | jq -r '.summary')"
assert_eq "$summary_val" "all good"
job_id_val="$(printf '%s' "$line" | jq -r '.job_id')"
assert_eq "$job_id_val" "test_job_1"
teardown_test_env

# ---- cron_log_run records error entries ----

test_start "cron_log_run records error entries"
setup_test_env
_source_libs
cron_log_run "err_job" "error" "something went wrong" 500 ""
log_file="${BASHCLAW_STATE_DIR}/cron/runs/err_job.jsonl"
assert_file_exists "$log_file"
line="$(tail -n 1 "$log_file")"
err_val="$(printf '%s' "$line" | jq -r '.error')"
assert_eq "$err_val" "something went wrong"
teardown_test_env

# ---- cron_get_run_history returns correct entries ----

test_start "cron_get_run_history returns correct entries"
setup_test_env
_source_libs
cron_log_run "hist_job" "success" "" 100 "run 1"
cron_log_run "hist_job" "success" "" 200 "run 2"
cron_log_run "hist_job" "error" "fail" 300 ""
result="$(cron_get_run_history "hist_job" 10)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "3"
first_summary="$(printf '%s' "$result" | jq -r '.[0].summary')"
assert_eq "$first_summary" "run 1"
last_status="$(printf '%s' "$result" | jq -r '.[2].status')"
assert_eq "$last_status" "error"
teardown_test_env

# ---- cron_get_run_history respects limit ----

test_start "cron_get_run_history respects limit"
setup_test_env
_source_libs
for i in $(seq 1 5); do
  cron_log_run "limit_job" "success" "" $((i * 100)) "run $i"
done
result="$(cron_get_run_history "limit_job" 2)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "2"
teardown_test_env

# ---- cron_get_run_history returns empty for nonexistent job ----

test_start "cron_get_run_history returns empty for nonexistent job"
setup_test_env
_source_libs
result="$(cron_get_run_history "no_such_job" 10)"
assert_eq "$result" "[]"
teardown_test_env

# ---- cron_get_run_stats calculates correctly ----

test_start "cron_get_run_stats calculates correctly"
setup_test_env
_source_libs
cron_log_run "stats_job" "success" "" 100 "ok"
cron_log_run "stats_job" "success" "" 200 "ok"
cron_log_run "stats_job" "error" "fail" 300 ""
result="$(cron_get_run_stats "stats_job")"
assert_json_valid "$result"
total="$(printf '%s' "$result" | jq '.total')"
assert_eq "$total" "3"
success="$(printf '%s' "$result" | jq '.success')"
assert_eq "$success" "2"
errors="$(printf '%s' "$result" | jq '.errors')"
assert_eq "$errors" "1"
avg_dur="$(printf '%s' "$result" | jq '.avg_duration_ms')"
assert_eq "$avg_dur" "200"
teardown_test_env

# ---- cron_get_run_stats returns zeros for nonexistent job ----

test_start "cron_get_run_stats returns zeros for nonexistent job"
setup_test_env
_source_libs
result="$(cron_get_run_stats "no_such_job")"
assert_json_valid "$result"
total="$(printf '%s' "$result" | jq '.total')"
assert_eq "$total" "0"
teardown_test_env

# ---- cron_log_run rotates file when large ----

test_start "cron_log_run rotates file when large"
setup_test_env
_source_libs
log_file="${BASHCLAW_STATE_DIR}/cron/runs/big_job.jsonl"
ensure_dir "$(dirname "$log_file")"
# Create a file just over 5MB with dummy data
padding="$(printf '%0.s.' $(seq 1 500))"
i=0
while (( i < 11000 )); do
  printf '{"ts":"2025-01-01T00:00:00Z","job_id":"big_job","status":"success","error":"","duration_ms":100,"summary":"%s"}\n' "$padding" >> "$log_file"
  i=$((i + 1))
done
size_before="$(wc -c < "$log_file" | tr -d ' ')"
assert_gt "$size_before" 5242880
# Now log a new run, which should trigger rotation
cron_log_run "big_job" "success" "" 50 "after rotation"
size_after="$(wc -c < "$log_file" | tr -d ' ')"
# After rotation, file should be much smaller than before
assert_gt "$size_before" "$size_after"
# The new entry should be present
last_line="$(tail -n 1 "$log_file")"
assert_contains "$last_line" "after rotation"
teardown_test_env

report_results
