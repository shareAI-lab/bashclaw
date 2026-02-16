#!/usr/bin/env bash
# Process/command queue module for bashclaw
# Dual-layer queue with typed lanes and queue modes.
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

_QUEUE_DIR=""

# Lane concurrency defaults
LANE_MAIN_MAX=4
LANE_CRON_MAX=1
LANE_SUBAGENT_MAX=8

# Initialize queue directory
_queue_dir() {
  if [[ -z "$_QUEUE_DIR" ]]; then
    _QUEUE_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/queue"
  fi
  ensure_dir "$_QUEUE_DIR"
  printf '%s' "$_QUEUE_DIR"
}

# ---- Original FIFO Queue (preserved for backward compat) ----

# Enqueue a command for an agent
process_enqueue() {
  local agent_id="${1:?agent_id required}"
  local command="${2:?command required}"

  require_command jq "process_enqueue requires jq"

  local dir
  dir="$(_queue_dir)"
  local ts
  ts="$(timestamp_ms)"
  local id
  id="$(uuid_generate)"
  local safe_id
  safe_id="$(sanitize_key "${ts}_${id}")"
  local file="${dir}/${safe_id}.json"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq -nc \
    --arg id "$id" \
    --arg aid "$agent_id" \
    --arg cmd "$command" \
    --arg status "pending" \
    --arg ca "$now" \
    --argjson ts "$ts" \
    '{id: $id, agent_id: $aid, command: $cmd, status: $status, created_at: $ca, ts: $ts}' \
    > "$file"

  log_debug "Enqueued: id=$id agent=$agent_id"
  printf '%s' "$id"
}

# Dequeue the next pending item (oldest first by filename sort)
process_dequeue() {
  require_command jq "process_dequeue requires jq"

  local dir
  dir="$(_queue_dir)"
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue

    local status
    status="$(jq -r '.status // empty' < "$f" 2>/dev/null)"
    if [[ "$status" != "pending" ]]; then
      continue
    fi

    local updated
    updated="$(jq '.status = "processing"' < "$f")"
    printf '%s\n' "$updated" > "$f"

    printf '%s' "$updated"
    return 0
  done

  return 1
}

# Background worker that continuously processes the queue
process_worker() {
  log_info "Queue worker starting..."

  while true; do
    local item
    item="$(process_dequeue 2>/dev/null)" || {
      sleep 2
      continue
    }

    local item_id agent_id command
    item_id="$(printf '%s' "$item" | jq -r '.id // empty')"
    agent_id="$(printf '%s' "$item" | jq -r '.agent_id // "main"')"
    command="$(printf '%s' "$item" | jq -r '.command // empty')"

    if [[ -z "$command" ]]; then
      log_warn "Queue item $item_id has no command, skipping"
      _queue_mark_done "$item_id" "error" "no command"
      continue
    fi

    if ! process_lanes_check "$agent_id"; then
      log_debug "Agent $agent_id at max concurrency, re-queuing $item_id"
      _queue_mark_pending "$item_id"
      sleep 1
      continue
    fi

    log_info "Queue processing: id=$item_id agent=$agent_id"

    (
      _queue_lane_acquire "$agent_id"
      local result
      result="$(agent_run "$agent_id" "$command" "queue" "queue:${item_id}" 2>&1)" || true
      _queue_lane_release "$agent_id"
      _queue_mark_done "$item_id" "completed" "${result:0:500}"
    ) &

    sleep 1
  done
}

# Report queue status
process_status() {
  require_command jq "process_status requires jq"

  local dir
  dir="$(_queue_dir)"
  local pending=0
  local processing=0
  local completed=0
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local status
    status="$(jq -r '.status // empty' < "$f" 2>/dev/null)"
    case "$status" in
      pending) pending=$((pending + 1)) ;;
      processing) processing=$((processing + 1)) ;;
      completed|error) completed=$((completed + 1)) ;;
    esac
  done

  jq -nc \
    --argjson p "$pending" \
    --argjson r "$processing" \
    --argjson c "$completed" \
    '{pending: $p, processing: $r, completed: $c}'
}

# Check if an agent has available concurrency lanes (legacy per-agent check)
process_lanes_check() {
  local agent_id="${1:?agent_id required}"

  local max_concurrent
  max_concurrent="$(config_agent_get "$agent_id" "maxConcurrent" "3")"

  local lane_dir="${BASHCLAW_STATE_DIR:?}/queue/lanes"
  ensure_dir "$lane_dir"

  local current=0
  local f
  for f in "${lane_dir}/${agent_id}"_*.lock; do
    [[ -f "$f" ]] || continue
    local lock_pid
    lock_pid="$(cat "$f" 2>/dev/null)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      current=$((current + 1))
    else
      rm -f "$f"
    fi
  done

  if (( current >= max_concurrent )); then
    return 1
  fi
  return 0
}

_queue_lane_acquire() {
  local agent_id="$1"
  local lane_dir="${BASHCLAW_STATE_DIR:?}/queue/lanes"
  ensure_dir "$lane_dir"
  printf '%s' "$$" > "${lane_dir}/${agent_id}_$$.lock"
}

_queue_lane_release() {
  local agent_id="$1"
  local lane_dir="${BASHCLAW_STATE_DIR:?}/queue/lanes"
  rm -f "${lane_dir}/${agent_id}_$$.lock"
}

_queue_mark_done() {
  local item_id="$1"
  local status="${2:-completed}"
  local detail="${3:-}"

  local dir
  dir="$(_queue_dir)"
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local fid
    fid="$(jq -r '.id // empty' < "$f" 2>/dev/null)"
    if [[ "$fid" == "$item_id" ]]; then
      local updated
      updated="$(jq --arg s "$status" --arg d "$detail" \
        '.status = $s | .detail = $d | .completed_at = (now | todate)' < "$f")"
      printf '%s\n' "$updated" > "$f"
      return 0
    fi
  done
}

_queue_mark_pending() {
  local item_id="$1"

  local dir
  dir="$(_queue_dir)"
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local fid
    fid="$(jq -r '.id // empty' < "$f" 2>/dev/null)"
    if [[ "$fid" == "$item_id" ]]; then
      local updated
      updated="$(jq '.status = "pending"' < "$f")"
      printf '%s\n' "$updated" > "$f"
      return 0
    fi
  done
}

# ============================================================================
# Dual-Layer Queue System
# Layer 1: Session-level serialization (max 1 per session key)
# Layer 2: Global lane concurrency (typed lanes with max limits)
# ============================================================================

# Get the max concurrent count for a lane type
_lane_max_for_type() {
  local lane_type="$1"

  case "$lane_type" in
    main)
      config_get '.lanes.main.maxConcurrent' "$LANE_MAIN_MAX"
      ;;
    cron)
      config_get '.lanes.cron.maxConcurrent' "$LANE_CRON_MAX"
      ;;
    subagent)
      config_get '.lanes.subagent.maxConcurrent' "$LANE_SUBAGENT_MAX"
      ;;
    nested)
      # Nested lanes are unlimited
      printf '999999'
      ;;
    *)
      printf '%s' "$LANE_MAIN_MAX"
      ;;
  esac
}

# Layer 1: Session-level enqueue.
# Ensures max 1 concurrent execution per session key using lockfiles.
# Blocks until the session lock is available, then runs the callback.
# Usage: lane_session_enqueue <session_key> <callback_fn> [args...]
lane_session_enqueue() {
  local session_key="${1:?session_key required}"
  shift
  local callback="${1:?callback required}"
  shift

  local lock_dir="${BASHCLAW_STATE_DIR:?}/queue/session_locks"
  ensure_dir "$lock_dir"

  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local lockfile="${lock_dir}/${safe_key}.lock"

  # Spin-wait to acquire session lock
  local waited=0
  while ! (set -o noclobber; printf '%s' "$$" > "$lockfile") 2>/dev/null; do
    # Check if the lock holder is still alive
    local lock_pid
    lock_pid="$(cat "$lockfile" 2>/dev/null)"
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -f "$lockfile"
      log_debug "lane_session_enqueue: stale lock removed for $session_key"
      continue
    fi

    sleep 1
    waited=$((waited + 1))
    if (( waited >= 300 )); then
      log_error "lane_session_enqueue: timeout waiting for session lock ($session_key)"
      return 1
    fi
  done

  # Execute callback directly, then release lock
  local result=0
  "$callback" "$@" || result=$?

  rm -f "$lockfile"
  return $result
}

# Layer 2: Global lane enqueue.
# Enforces per-lane-type concurrency limits.
# Blocks until a slot is available in the specified lane.
# Usage: lane_global_enqueue <lane_type> <callback_fn> [args...]
lane_global_enqueue() {
  local lane_type="${1:?lane_type required}"
  shift
  local callback="${1:?callback required}"
  shift

  local lane_dir="${BASHCLAW_STATE_DIR:?}/queue/global_lanes/${lane_type}"
  ensure_dir "$lane_dir"

  local max_concurrent
  max_concurrent="$(_lane_max_for_type "$lane_type")"

  # Spin-wait for an available slot
  local waited=0
  while true; do
    # Count active slots (clean up stale ones)
    local current=0
    local f
    for f in "${lane_dir}"/*.slot; do
      [[ -f "$f" ]] || continue
      local slot_pid
      slot_pid="$(cat "$f" 2>/dev/null)"
      if [[ -n "$slot_pid" ]] && kill -0 "$slot_pid" 2>/dev/null; then
        current=$((current + 1))
      else
        rm -f "$f"
      fi
    done

    if (( current < max_concurrent )); then
      break
    fi

    sleep 1
    waited=$((waited + 1))
    if (( waited >= 300 )); then
      log_error "lane_global_enqueue: timeout waiting for $lane_type slot"
      return 1
    fi
  done

  # Acquire a slot
  local slot_id
  slot_id="$(uuid_generate)"
  local slot_file="${lane_dir}/${slot_id}.slot"
  printf '%s' "$$" > "$slot_file"

  # Execute callback directly, then release slot
  local result=0
  "$callback" "$@" || result=$?

  rm -f "$slot_file"
  return $result
}

# Get the count of active + queued items for a lane type
lane_get_queue_size() {
  local lane_type="${1:?lane_type required}"

  local lane_dir="${BASHCLAW_STATE_DIR:?}/queue/global_lanes/${lane_type}"
  if [[ ! -d "$lane_dir" ]]; then
    printf '0'
    return 0
  fi

  local count=0
  local f
  for f in "${lane_dir}"/*.slot; do
    [[ -f "$f" ]] || continue
    local slot_pid
    slot_pid="$(cat "$f" 2>/dev/null)"
    if [[ -n "$slot_pid" ]] && kill -0 "$slot_pid" 2>/dev/null; then
      count=$((count + 1))
    else
      rm -f "$f"
    fi
  done

  printf '%s' "$count"
}

# Dual-layer enqueue: session serialization wrapping global concurrency.
# This is the primary entry point for controlled execution.
lane_dual_enqueue() {
  local session_key="${1:?session_key required}"
  local lane_type="${2:?lane_type required}"
  local callback="${3:?callback required}"

  log_debug "lane_dual_enqueue: session=$session_key lane=$lane_type"

  # Session lock wraps global lane: acquire session lock first,
  # then acquire a global lane slot, then execute the callback.
  lane_session_enqueue "$session_key" lane_global_enqueue "$lane_type" "$callback"
}

# ============================================================================
# Queue Modes (5 modes for handling messages when agent is busy)
# ============================================================================

# Resolve the queue mode for a session.
# Reads from session config, defaults to "followup".
# "steer" and "steer-backlog" are mapped to "followup" in bash
# since streaming injection is impractical.
queue_mode_resolve() {
  local session_key="${1:?session_key required}"

  # Try to get from session metadata
  local meta_dir="${BASHCLAW_STATE_DIR:?}/queue/meta"
  ensure_dir "$meta_dir"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local meta_file="${meta_dir}/${safe_key}.mode"

  if [[ -f "$meta_file" ]]; then
    local mode
    mode="$(cat "$meta_file" 2>/dev/null)"
    if [[ -n "$mode" ]]; then
      # Normalize steer variants to followup
      case "$mode" in
        steer|steer-backlog) mode="followup" ;;
      esac
      printf '%s' "$mode"
      return 0
    fi
  fi

  # Default
  printf 'followup'
}

# Handle a new message arriving while the agent is busy processing.
# Implements the 5 queue modes:
#   followup  - queue as next message after current turn
#   collect   - debounce and merge multiple pending messages
#   interrupt - signal abort and process new message immediately
#   steer     - mapped to followup (streaming injection not supported)
#   steer-backlog - mapped to followup
queue_handle_busy() {
  local session_key="${1:?session_key required}"
  local new_message="${2:?new_message required}"
  local mode="${3:-}"

  if [[ -z "$mode" ]]; then
    mode="$(queue_mode_resolve "$session_key")"
  fi

  require_command jq "queue_handle_busy requires jq"

  local pending_dir="${BASHCLAW_STATE_DIR:?}/queue/pending"
  ensure_dir "$pending_dir"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local pending_file="${pending_dir}/${safe_key}.jsonl"

  case "$mode" in
    followup|steer|steer-backlog)
      # Append to pending queue
      local ts
      ts="$(timestamp_ms)"
      local line
      line="$(jq -nc --arg msg "$new_message" --argjson ts "$ts" \
        '{message: $msg, ts: $ts}')"
      printf '%s\n' "$line" >> "$pending_file"
      log_debug "queue_handle_busy: followup queued for $session_key"
      printf 'queued'
      ;;

    collect)
      # Append to pending queue with debounce marker
      local ts
      ts="$(timestamp_ms)"
      local line
      line="$(jq -nc --arg msg "$new_message" --argjson ts "$ts" --arg mode "collect" \
        '{message: $msg, ts: $ts, mode: $mode}')"
      printf '%s\n' "$line" >> "$pending_file"

      # Schedule a debounce merge (check if one is already pending)
      local debounce_file="${pending_dir}/${safe_key}.debounce"
      local debounce_ms
      debounce_ms="$(config_get '.session.queueDebounceMs' '2000')"
      local debounce_s=$(( debounce_ms / 1000 ))
      if (( debounce_s < 1 )); then
        debounce_s=1
      fi

      if [[ ! -f "$debounce_file" ]]; then
        printf '%s' "$ts" > "$debounce_file"
        # Start debounce timer in background
        (
          sleep "$debounce_s"
          _queue_merge_collected "$session_key"
          rm -f "$debounce_file"
        ) &
      fi

      log_debug "queue_handle_busy: collect queued for $session_key"
      printf 'collected'
      ;;

    interrupt)
      # Write abort signal file
      local abort_dir="${BASHCLAW_STATE_DIR:?}/queue/abort"
      ensure_dir "$abort_dir"
      printf '%s' "$new_message" > "${abort_dir}/${safe_key}.abort"

      # Clear any pending messages (the new one takes priority)
      rm -f "$pending_file"

      # Enqueue the new message as the next to process
      local ts
      ts="$(timestamp_ms)"
      local line
      line="$(jq -nc --arg msg "$new_message" --argjson ts "$ts" \
        '{message: $msg, ts: $ts}')"
      printf '%s\n' "$line" > "$pending_file"

      log_debug "queue_handle_busy: interrupt signal for $session_key"
      printf 'interrupted'
      ;;

    *)
      # Unknown mode, fall back to followup
      queue_handle_busy "$session_key" "$new_message" "followup"
      ;;
  esac
}

# Drain all pending messages for a session.
# Returns messages as a JSON array and clears the pending queue.
queue_drain_pending() {
  local session_key="${1:?session_key required}"

  require_command jq "queue_drain_pending requires jq"

  local pending_dir="${BASHCLAW_STATE_DIR:?}/queue/pending"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local pending_file="${pending_dir}/${safe_key}.jsonl"

  if [[ ! -f "$pending_file" ]]; then
    printf '[]'
    return 0
  fi

  local messages
  messages="$(jq -s '[.[] | .message]' < "$pending_file" 2>/dev/null)"
  if [[ -z "$messages" || "$messages" == "null" ]]; then
    messages="[]"
  fi

  rm -f "$pending_file"
  printf '%s' "$messages"
}

# Check if there is an abort signal for a session.
# Returns 0 if abort signal exists (and clears it), 1 otherwise.
queue_check_abort() {
  local session_key="${1:?session_key required}"

  local abort_dir="${BASHCLAW_STATE_DIR:?}/queue/abort"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local abort_file="${abort_dir}/${safe_key}.abort"

  if [[ -f "$abort_file" ]]; then
    rm -f "$abort_file"
    return 0
  fi
  return 1
}

# Check if a session is currently busy (has an active session lock)
queue_is_session_busy() {
  local session_key="${1:?session_key required}"

  local lock_dir="${BASHCLAW_STATE_DIR:?}/queue/session_locks"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local lockfile="${lock_dir}/${safe_key}.lock"

  if [[ -f "$lockfile" ]]; then
    local lock_pid
    lock_pid="$(cat "$lockfile" 2>/dev/null)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$lockfile"
  fi

  return 1
}

# ---- Internal: merge collected messages ----

_queue_merge_collected() {
  local session_key="$1"

  require_command jq "_queue_merge_collected requires jq"

  local pending_dir="${BASHCLAW_STATE_DIR:?}/queue/pending"
  local safe_key
  safe_key="$(sanitize_key "$session_key")"
  local pending_file="${pending_dir}/${safe_key}.jsonl"

  if [[ ! -f "$pending_file" ]]; then
    return 0
  fi

  # Read all pending messages
  local messages
  messages="$(jq -s '[.[] | .message]' < "$pending_file" 2>/dev/null)"
  local count
  count="$(printf '%s' "$messages" | jq 'length')"

  if (( count <= 1 )); then
    return 0
  fi

  # Merge into a single message
  local merged
  merged="$(printf '%s' "$messages" | jq -r '
    "Messages received while you were busy:\n" +
    ([to_entries[] | "- User: \(.value)"] | join("\n"))
  ')"

  # Replace pending queue with merged message
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc --arg msg "$merged" --argjson ts "$ts" \
    '{message: $msg, ts: $ts}')"
  printf '%s\n' "$line" > "$pending_file"

  log_debug "_queue_merge_collected: merged $count messages for $session_key"
}
