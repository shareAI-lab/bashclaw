#!/usr/bin/env bash
# Advanced cron system for bashclaw
# Supports three schedule types (at/every/cron), exponential backoff,
# stuck job detection, isolated sessions, and concurrent run limits.
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

CRON_DEFAULT_MAX_CONCURRENT=1
CRON_DEFAULT_JOB_TIMEOUT=600
CRON_DEFAULT_STUCK_THRESHOLD=7200
CRON_DEFAULT_SESSION_RETENTION=86400
CRON_SESSION_REAP_INTERVAL=300
CRON_BACKOFF_STEPS="30 60 300 900 3600"

# -- Store operations --

# Directory for cron data
_cron_dir() {
  local dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/cron"
  ensure_dir "$dir"
  printf '%s' "$dir"
}

# Load all jobs from the consolidated jobs.json store
cron_store_load() {
  require_command jq "cron_store_load requires jq"

  local dir
  dir="$(_cron_dir)"
  local store="${dir}/jobs.json"

  if [[ ! -f "$store" ]]; then
    # Migrate from individual JSON files if they exist
    _cron_migrate_legacy "$dir" "$store"
    if [[ ! -f "$store" ]]; then
      printf '{"version":1,"jobs":[]}'
      return 0
    fi
  fi

  cat "$store"
}

# Save the full jobs array to the store
cron_store_save() {
  local jobs_json="${1:?jobs_json required}"

  require_command jq "cron_store_save requires jq"

  local dir
  dir="$(_cron_dir)"
  local store="${dir}/jobs.json"
  local lockfile="${dir}/jobs.lock"

  # Acquire lockfile
  local waited=0
  while ! (set -o noclobber; printf '%s' "$$" > "$lockfile") 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 10 )); then
      rm -f "$lockfile"
    fi
  done

  printf '%s\n' "$jobs_json" > "$store"
  rm -f "$lockfile"
}

# -- Schedule parsing --

# Parse a schedule JSON object and return its kind.
# Supports: {kind:"at", at:"ISO-timestamp"}, {kind:"every", everyMs:N}, {kind:"cron", expr:"...", tz:"UTC"}
# Also accepts plain cron expression strings for backward compatibility.
cron_parse_schedule() {
  local schedule_input="$1"

  require_command jq "cron_parse_schedule requires jq"

  # Check if input is valid JSON
  local kind
  kind="$(printf '%s' "$schedule_input" | jq -r '.kind // empty' 2>/dev/null)"

  if [[ -n "$kind" ]]; then
    printf '%s' "$kind"
    return 0
  fi

  # Backward compat: treat as a cron expression string
  printf 'cron'
}

# Calculate next run time in epoch seconds for a given schedule.
cron_next_run() {
  local schedule_input="$1"
  local last_run="${2:-0}"

  require_command jq "cron_next_run requires jq"

  local kind
  kind="$(cron_parse_schedule "$schedule_input")"

  case "$kind" in
    at)
      # One-shot at a specific ISO timestamp
      local at_str
      at_str="$(printf '%s' "$schedule_input" | jq -r '.at // empty')"
      if [[ -z "$at_str" ]]; then
        printf '0'
        return 1
      fi
      _cron_iso_to_epoch "$at_str"
      ;;

    every)
      # Interval-based: everyMs milliseconds
      local every_ms
      every_ms="$(printf '%s' "$schedule_input" | jq -r '.everyMs // 0')"
      if (( every_ms <= 0 )); then
        printf '0'
        return 1
      fi
      local every_s=$(( every_ms / 1000 ))
      if (( last_run <= 0 )); then
        # First run: now
        timestamp_s
      else
        printf '%s' "$(( last_run + every_s ))"
      fi
      ;;

    cron)
      # 5-field cron expression
      local expr tz
      expr="$(printf '%s' "$schedule_input" | jq -r '.expr // empty' 2>/dev/null)"
      tz="$(printf '%s' "$schedule_input" | jq -r '.tz // empty' 2>/dev/null)"

      # If input is a plain string (backward compat), use it directly
      if [[ -z "$expr" ]]; then
        expr="$schedule_input"
      fi

      _cron_next_match "$expr" "$tz"
      ;;

    *)
      printf '0'
      return 1
      ;;
  esac
}

# -- Job management --

# Add a new cron job
cron_add() {
  local job_id="${1:?job_id required}"
  local schedule="${2:?schedule required}"
  local prompt="${3:?prompt required}"
  local session_target="${4:-main}"

  require_command jq "cron_add requires jq"

  local store
  store="$(cron_store_load)"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local updated
  updated="$(printf '%s' "$store" | jq \
    --arg id "$job_id" \
    --arg sched "$schedule" \
    --arg pr "$prompt" \
    --arg st "$session_target" \
    --arg ts "$ts" \
    '.jobs += [{
      id: $id,
      schedule: $sched,
      prompt: $pr,
      sessionTarget: $st,
      createdAt: $ts,
      enabled: true,
      failureCount: 0,
      lastRunAt: null,
      lastResult: null,
      backoffUntil: null
    }]')"

  cron_store_save "$updated"
  log_info "cron_add: job $job_id added"
}

# Remove a cron job by ID
cron_remove() {
  local job_id="${1:?job_id required}"

  require_command jq "cron_remove requires jq"

  local store
  store="$(cron_store_load)"

  local updated
  updated="$(printf '%s' "$store" | jq --arg id "$job_id" \
    '.jobs = [.jobs[] | select(.id != $id)]')"

  cron_store_save "$updated"
  log_info "cron_remove: job $job_id removed"
}

# -- Job execution --

# Run a specific cron job
cron_run_job() {
  local job_id="${1:?job_id required}"

  require_command jq "cron_run_job requires jq"

  local store
  store="$(cron_store_load)"

  local job
  job="$(printf '%s' "$store" | jq -c --arg id "$job_id" \
    '[.jobs[] | select(.id == $id)] | .[0] // empty')"

  if [[ -z "$job" || "$job" == "null" ]]; then
    log_error "cron_run_job: job $job_id not found"
    return 1
  fi

  local prompt session_target agent_id
  prompt="$(printf '%s' "$job" | jq -r '.prompt // .command // empty')"
  session_target="$(printf '%s' "$job" | jq -r '.sessionTarget // "main"')"
  agent_id="$(printf '%s' "$job" | jq -r '.agent_id // "main"')"

  if [[ -z "$prompt" ]]; then
    log_error "cron_run_job: job $job_id has no prompt"
    _cron_update_job_status "$job_id" "error" "no prompt" 1
    return 1
  fi

  # Mark run start
  local run_lock_dir="${BASHCLAW_STATE_DIR:?}/cron/runs"
  ensure_dir "$run_lock_dir"
  local run_id
  run_id="$(uuid_generate)"
  printf '%s' "$(timestamp_s)" > "${run_lock_dir}/${job_id}_${run_id}.run"

  local result=""
  local exit_status=0
  local run_start_ms
  run_start_ms="$(timestamp_ms)"

  case "$session_target" in
    isolated)
      result="$(cron_run_isolated "$job_id" "$prompt" "$agent_id" 2>&1)" || exit_status=$?
      ;;
    *)
      result="$(cron_run_in_main "$job_id" "$prompt" "$agent_id" 2>&1)" || exit_status=$?
      ;;
  esac

  local run_end_ms
  run_end_ms="$(timestamp_ms)"
  local run_duration_ms=$((run_end_ms - run_start_ms))

  # Clean up run lock
  rm -f "${run_lock_dir}/${job_id}_${run_id}.run"

  # Update job status
  if (( exit_status == 0 )); then
    _cron_update_job_status "$job_id" "success" "${result:0:500}" 0
    cron_log_run "$job_id" "success" "" "$run_duration_ms" "${result:0:500}"
  else
    _cron_update_job_status "$job_id" "error" "${result:0:500}" 1
    cron_log_run "$job_id" "error" "${result:0:500}" "$run_duration_ms" ""
  fi

  # Log to history
  local history_dir
  history_dir="$(_cron_dir)/history"
  ensure_dir "$history_dir"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local entry
  entry="$(jq -nc --arg id "$job_id" --arg ts "$ts" --arg out "${result:0:500}" --arg st "$exit_status" \
    '{job_id: $id, ran_at: $ts, output: $out, exit_status: ($st | tonumber)}')"
  printf '%s\n' "$entry" >> "${history_dir}/runs.jsonl"

  printf '%s' "$result"
}

# Run a cron job in the main session context via events queue
cron_run_in_main() {
  local job_id="${1:?job_id required}"
  local prompt="${2:?prompt required}"
  local agent_id="${3:-main}"

  # Enqueue as a system event
  local session_key
  session_key="$(session_key "$agent_id" "default" "")"
  events_enqueue "$session_key" "Cron job [$job_id]: $prompt" "cron"

  # Optionally trigger an immediate heartbeat
  if heartbeat_should_run "$agent_id" 2>/dev/null; then
    heartbeat_run "$agent_id" "cron-event" 2>/dev/null || true
  fi

  printf 'event-queued'
}

# Run a cron job in an isolated session
cron_run_isolated() {
  local job_id="${1:?job_id required}"
  local prompt="${2:?prompt required}"
  local agent_id="${3:-main}"

  local run_id
  run_id="$(uuid_generate)"
  local session_sender="cron:${job_id}:run:${run_id}"

  log_info "cron_run_isolated: job=$job_id session=$session_sender"

  # Run agent in isolated session with timeout
  local timeout_s
  timeout_s="$(config_get '.cron.jobTimeoutMs' "$((CRON_DEFAULT_JOB_TIMEOUT * 1000))")"
  timeout_s=$((timeout_s / 1000))

  local result=""
  local result_file
  result_file="$(tmpfile "cron_result")"

  # Run with timeout in a subshell
  (
    agent_run "$agent_id" "$prompt" "cron" "$session_sender" > "$result_file" 2>&1
  ) &
  local pid=$!

  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < timeout_s )); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    log_warn "cron_run_isolated: job $job_id timed out after ${timeout_s}s"
    result="[timed out after ${timeout_s}s]"
  else
    wait "$pid" 2>/dev/null || true
    result="$(cat "$result_file" 2>/dev/null)"
  fi

  rm -f "$result_file"

  # Optionally deliver result to main session
  if [[ -n "$result" && "$result" != "[timed out"* ]]; then
    local session_key
    session_key="$(session_key "$agent_id" "default" "")"
    events_enqueue "$session_key" "Cron [$job_id]: ${result:0:500}" "cron"
  fi

  printf '%s' "$result"
}

# Exponential backoff calculation.
# Returns the backoff duration in seconds for a given failure count.
cron_backoff() {
  local job_id="${1:?job_id required}"
  local failure_count="${2:-0}"

  # Backoff steps: 30s, 60s, 5min, 15min, 60min (cap)
  local step=0
  local duration=30
  local s
  for s in $CRON_BACKOFF_STEPS; do
    if (( step >= failure_count )); then
      break
    fi
    duration="$s"
    step=$((step + 1))
  done

  printf '%s' "$duration"
}

# Check for stuck jobs (runs exceeding the stuck threshold).
# Auto-releases stuck run locks.
cron_check_stuck() {
  local stuck_threshold
  stuck_threshold="$(config_get '.cron.stuckRunMs' "$((CRON_DEFAULT_STUCK_THRESHOLD * 1000))")"
  stuck_threshold=$((stuck_threshold / 1000))

  local run_dir="${BASHCLAW_STATE_DIR:?}/cron/runs"
  if [[ ! -d "$run_dir" ]]; then
    return 0
  fi

  local now_s
  now_s="$(timestamp_s)"

  local f
  for f in "${run_dir}"/*.run; do
    [[ -f "$f" ]] || continue
    local start_ts
    start_ts="$(cat "$f" 2>/dev/null)"
    if [[ -z "$start_ts" ]]; then
      continue
    fi

    local elapsed=$((now_s - start_ts))
    if (( elapsed > stuck_threshold )); then
      local fname
      fname="$(basename "$f")"
      log_warn "cron_check_stuck: releasing stuck run $fname (${elapsed}s > ${stuck_threshold}s)"
      rm -f "$f"
    fi
  done
}

# Background service loop: checks all jobs, runs due jobs, enforces concurrency.
cron_service_loop() {
  log_info "cron_service_loop: starting"

  local last_reap=0

  while true; do
    sleep 10

    local cron_enabled
    cron_enabled="$(config_get '.cron.enabled' 'false')"
    if [[ "$cron_enabled" != "true" ]]; then
      continue
    fi

    # Check for stuck jobs
    cron_check_stuck

    # Session reap (every CRON_SESSION_REAP_INTERVAL seconds)
    local now_s
    now_s="$(timestamp_s)"
    if (( now_s - last_reap > CRON_SESSION_REAP_INTERVAL )); then
      cron_session_reap
      last_reap="$now_s"
    fi

    # Load jobs and check which are due
    local store
    store="$(cron_store_load)"

    local max_concurrent
    max_concurrent="$(config_get '.cron.maxConcurrentRuns' "$CRON_DEFAULT_MAX_CONCURRENT")"

    # Count active runs
    local active_runs=0
    local run_dir="${BASHCLAW_STATE_DIR:?}/cron/runs"
    if [[ -d "$run_dir" ]]; then
      local f
      for f in "${run_dir}"/*.run; do
        [[ -f "$f" ]] || continue
        active_runs=$((active_runs + 1))
      done
    fi

    if (( active_runs >= max_concurrent )); then
      continue
    fi

    # Iterate jobs
    local job_count
    job_count="$(printf '%s' "$store" | jq '.jobs | length')"
    local i=0
    while (( i < job_count && active_runs < max_concurrent )); do
      local job
      job="$(printf '%s' "$store" | jq -c ".jobs[$i]")"

      local enabled job_id schedule last_run_at backoff_until
      enabled="$(printf '%s' "$job" | jq -r '.enabled // false')"
      job_id="$(printf '%s' "$job" | jq -r '.id // empty')"

      i=$((i + 1))

      if [[ "$enabled" != "true" || -z "$job_id" ]]; then
        continue
      fi

      schedule="$(printf '%s' "$job" | jq -r '.schedule // empty')"
      last_run_at="$(printf '%s' "$job" | jq -r '.lastRunAt // empty')"
      backoff_until="$(printf '%s' "$job" | jq -r '.backoffUntil // empty')"

      # Check backoff
      if [[ -n "$backoff_until" && "$backoff_until" != "null" ]]; then
        local backoff_ts
        backoff_ts="$(_cron_iso_to_epoch "$backoff_until" 2>/dev/null)" || backoff_ts=0
        if (( now_s < backoff_ts )); then
          continue
        fi
      fi

      # Calculate next run time
      local last_epoch=0
      if [[ -n "$last_run_at" && "$last_run_at" != "null" ]]; then
        last_epoch="$(_cron_iso_to_epoch "$last_run_at" 2>/dev/null)" || last_epoch=0
      fi

      local next_run
      next_run="$(cron_next_run "$schedule" "$last_epoch" 2>/dev/null)" || next_run=0

      if (( next_run <= 0 || now_s < next_run )); then
        # Check if "at" type and already ran (one-shot)
        local kind
        kind="$(cron_parse_schedule "$schedule" 2>/dev/null)"
        if [[ "$kind" == "at" && -n "$last_run_at" && "$last_run_at" != "null" ]]; then
          continue
        fi
        if (( next_run > 0 )); then
          continue
        fi
      fi

      # Job is due - run it in background
      log_info "cron_service_loop: running job $job_id"
      (cron_run_job "$job_id") &
      active_runs=$((active_runs + 1))
    done
  done
}

# Clean up isolated cron sessions older than the retention period.
cron_session_reap() {
  local retention_s
  retention_s="$(config_get '.cron.sessionRetentionMs' "$((CRON_DEFAULT_SESSION_RETENTION * 1000))")"
  retention_s=$((retention_s / 1000))

  local sessions_dir="${BASHCLAW_STATE_DIR:?}/sessions"
  if [[ ! -d "$sessions_dir" ]]; then
    return 0
  fi

  local now_s
  now_s="$(timestamp_s)"

  # Find cron session files
  local f
  while IFS= read -r -d '' f; do
    # Check if file is old enough
    local file_mtime
    if [[ "$(uname -s)" == "Darwin" ]]; then
      file_mtime="$(stat -f%m "$f" 2>/dev/null)" || continue
    else
      file_mtime="$(stat -c%Y "$f" 2>/dev/null)" || continue
    fi

    local age=$((now_s - file_mtime))
    if (( age > retention_s )); then
      rm -f "$f"
      log_debug "cron_session_reap: removed $f (age=${age}s)"
    fi
  done < <(find "$sessions_dir" -name 'cron:*' -print0 2>/dev/null)
}

# -- Run History (JSONL-based) --

# Log a cron job run to JSONL history.
# Rotates the log file if it exceeds 5MB.
cron_log_run() {
  local job_id="${1:?job_id required}"
  local status="${2:?status required}"
  local error_msg="${3:-}"
  local duration_ms="${4:-0}"
  local summary="${5:-}"

  require_command jq "cron_log_run requires jq"

  local runs_dir
  runs_dir="$(_cron_dir)/runs"
  ensure_dir "$runs_dir"

  local log_file="${runs_dir}/${job_id}.jsonl"

  # Rotate if file exceeds 5MB
  if [[ -f "$log_file" ]]; then
    local file_size
    file_size="$(file_size_bytes "$log_file")"
    if (( file_size > 5242880 )); then
      local rotated="${log_file}.old"
      mv "$log_file" "$rotated"
      # Keep only the last 1000 lines from the rotated file
      tail -n 1000 "$rotated" > "$log_file"
      rm -f "$rotated"
      log_debug "cron_log_run: rotated log for job $job_id"
    fi
  fi

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local entry
  entry="$(jq -nc \
    --arg ts "$ts" \
    --arg jid "$job_id" \
    --arg st "$status" \
    --arg err "$error_msg" \
    --argjson dur "$duration_ms" \
    --arg sum "$summary" \
    '{ts: $ts, job_id: $jid, status: $st, error: $err, duration_ms: $dur, summary: $sum}')"

  printf '%s\n' "$entry" >> "$log_file"
}

# Get the last N run history entries for a job.
# Returns a JSON array.
cron_get_run_history() {
  local job_id="${1:?job_id required}"
  local limit="${2:-20}"

  require_command jq "cron_get_run_history requires jq"

  local log_file
  log_file="$(_cron_dir)/runs/${job_id}.jsonl"

  if [[ ! -f "$log_file" ]]; then
    printf '[]'
    return 0
  fi

  tail -n "$limit" "$log_file" | jq -s '.'
}

# Get aggregate run statistics for a job.
# Returns a JSON object with total, success, error counts and avg duration.
cron_get_run_stats() {
  local job_id="${1:?job_id required}"

  require_command jq "cron_get_run_stats requires jq"

  local log_file
  log_file="$(_cron_dir)/runs/${job_id}.jsonl"

  if [[ ! -f "$log_file" ]]; then
    printf '{"total":0,"success":0,"errors":0,"avg_duration_ms":0}'
    return 0
  fi

  jq -s '{
    total: length,
    success: [.[] | select(.status == "success")] | length,
    errors: [.[] | select(.status == "error")] | length,
    avg_duration_ms: (if length > 0 then ([.[].duration_ms] | add / length | floor) else 0 end)
  }' < "$log_file"
}

# -- Internal helpers --

# Update a job's status after a run
_cron_update_job_status() {
  local job_id="$1"
  local status="$2"
  local detail="${3:-}"
  local is_failure="${4:-0}"

  require_command jq "_cron_update_job_status requires jq"

  local store
  store="$(cron_store_load)"

  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local updated
  if (( is_failure )); then
    # Increment failure count and calculate backoff
    local failure_count
    failure_count="$(printf '%s' "$store" | jq --arg id "$job_id" \
      '[.jobs[] | select(.id == $id) | .failureCount // 0] | .[0] // 0')"
    failure_count=$((failure_count + 1))

    local backoff_s
    backoff_s="$(cron_backoff "$job_id" "$failure_count")"
    local backoff_epoch=$(($(timestamp_s) + backoff_s))
    local backoff_iso
    backoff_iso="$(date -u -r "$backoff_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
      date -u -d "@$backoff_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
      printf '%s' "$now_iso")"

    updated="$(printf '%s' "$store" | jq \
      --arg id "$job_id" \
      --arg ts "$now_iso" \
      --arg st "$status" \
      --arg dt "$detail" \
      --argjson fc "$failure_count" \
      --arg bu "$backoff_iso" \
      '.jobs = [.jobs[] | if .id == $id then
        .lastRunAt = $ts | .lastResult = $st | .lastDetail = $dt |
        .failureCount = $fc | .backoffUntil = $bu
      else . end]')"
  else
    updated="$(printf '%s' "$store" | jq \
      --arg id "$job_id" \
      --arg ts "$now_iso" \
      --arg st "$status" \
      --arg dt "$detail" \
      '.jobs = [.jobs[] | if .id == $id then
        .lastRunAt = $ts | .lastResult = $st | .lastDetail = $dt |
        .failureCount = 0 | .backoffUntil = null
      else . end]')"
  fi

  cron_store_save "$updated"
}

# Convert ISO 8601 timestamp to epoch seconds (cross-platform)
_cron_iso_to_epoch() {
  local iso_str="$1"

  if [[ -z "$iso_str" || "$iso_str" == "null" ]]; then
    printf '0'
    return 1
  fi

  # Try GNU date
  local epoch
  epoch="$(date -d "$iso_str" '+%s' 2>/dev/null)" && {
    printf '%s' "$epoch"
    return 0
  }

  # Try macOS date
  # Convert ISO format to something macOS date understands
  local cleaned
  cleaned="$(printf '%s' "$iso_str" | sed 's/T/ /; s/Z//')"
  epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "$cleaned" '+%s' 2>/dev/null)" && {
    printf '%s' "$epoch"
    return 0
  }

  printf '0'
  return 1
}

# Parse a single cron field into a list of matching values.
# Usage: _cron_parse_field FIELD LO HI
# Output: space-separated list of matching integers
_cron_parse_field() {
  local field="$1"
  local lo="$2"
  local hi="$3"
  local result=""

  # Split on commas
  local IFS=','
  local part
  for part in $field; do
    if [[ "$part" == "*" ]]; then
      local v
      for (( v=lo; v<=hi; v++ )); do
        result="$result $v"
      done
    elif [[ "$part" == *"/"* ]]; then
      local base="${part%%/*}"
      local step="${part#*/}"
      local start="$lo"
      if [[ "$base" != "*" ]]; then
        start="$base"
      fi
      local v
      for (( v=start; v<=hi; v+=step )); do
        result="$result $v"
      done
    elif [[ "$part" == *"-"* ]]; then
      local range_lo="${part%%-*}"
      local range_hi="${part#*-}"
      local v
      for (( v=range_lo; v<=range_hi; v++ )); do
        result="$result $v"
      done
    else
      result="$result $part"
    fi
  done

  printf '%s' "$result"
}

# Check if a value is in a space-separated list
_cron_in_list() {
  local needle="$1"
  local haystack="$2"
  local v
  for v in $haystack; do
    if [[ "$v" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# Calculate next matching time for a 5-field cron expression.
# Pure bash implementation, minute granularity.
_cron_next_match() {
  local expr="$1"
  local tz="${2:-}"

  local f1 f2 f3 f4 f5 _rest
  read -r f1 f2 f3 f4 f5 _rest <<< "$expr"

  if [[ -z "$f1" || -z "$f2" || -z "$f3" || -z "$f4" || -z "$f5" ]]; then
    printf '0'
    return 1
  fi

  local minutes hours mdays months wdays
  minutes="$(_cron_parse_field "$f1" 0 59)"
  hours="$(_cron_parse_field "$f2" 0 23)"
  mdays="$(_cron_parse_field "$f3" 1 31)"
  months="$(_cron_parse_field "$f4" 1 12)"
  wdays="$(_cron_parse_field "$f5" 0 6)"

  local now_s
  now_s="$(date +%s)"
  # Start from the next minute boundary
  local t=$(( now_s + 60 - (now_s % 60) ))

  # Search up to 1 year ahead (525600 minutes)
  local i
  for (( i=0; i<525600; i++ )); do
    local check_min check_hour check_mday check_mon check_wday
    if [[ "$(uname -s)" == "Darwin" ]]; then
      check_min="$(date -r "$t" '+%-M' 2>/dev/null)"
      check_hour="$(date -r "$t" '+%-H' 2>/dev/null)"
      check_mday="$(date -r "$t" '+%-d' 2>/dev/null)"
      check_mon="$(date -r "$t" '+%-m' 2>/dev/null)"
      check_wday="$(date -r "$t" '+%w' 2>/dev/null)"
    else
      check_min="$(date -d "@$t" '+%-M' 2>/dev/null)"
      check_hour="$(date -d "@$t" '+%-H' 2>/dev/null)"
      check_mday="$(date -d "@$t" '+%-d' 2>/dev/null)"
      check_mon="$(date -d "@$t" '+%-m' 2>/dev/null)"
      check_wday="$(date -d "@$t" '+%w' 2>/dev/null)"
    fi

    if _cron_in_list "$check_min" "$minutes" && \
       _cron_in_list "$check_hour" "$hours" && \
       _cron_in_list "$check_mday" "$mdays" && \
       _cron_in_list "$check_mon" "$months" && \
       _cron_in_list "$check_wday" "$wdays"; then
      printf '%s' "$t"
      return 0
    fi

    t=$((t + 60))
  done

  printf '0'
}

# Migrate legacy individual JSON job files into the consolidated store
_cron_migrate_legacy() {
  local dir="$1"
  local store="$2"

  local jobs_ndjson=""
  local found=0
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    # Skip the store file itself and any meta files
    case "$base" in
      jobs.json|*.lock) continue ;;
    esac

    local entry
    entry="$(cat "$f" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
      # Normalize fields
      entry="$(printf '%s' "$entry" | jq '
        {
          id: (.id // "unknown"),
          schedule: (.schedule // ""),
          prompt: (.command // .prompt // ""),
          sessionTarget: (.sessionTarget // "main"),
          createdAt: (.created_at // .createdAt // ""),
          enabled: (.enabled // true),
          failureCount: 0,
          lastRunAt: null,
          lastResult: null,
          backoffUntil: null
        } + (if .agent_id then {agent_id: .agent_id} else {} end)
      ')"
      jobs_ndjson="${jobs_ndjson}${entry}"$'\n'
      found=$((found + 1))
    fi
  done

  if (( found > 0 )); then
    local jobs
    jobs="$(printf '%s' "$jobs_ndjson" | jq -s '.')"
    local result
    result="$(jq -nc --argjson j "$jobs" '{version: 1, jobs: $j}')"
    printf '%s\n' "$result" > "$store"
    log_info "cron: migrated $found legacy jobs to jobs.json"
  fi
}
