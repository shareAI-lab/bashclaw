#!/usr/bin/env bash
# Gateway server command for bashclaw

GATEWAY_PID_FILE=""
GATEWAY_PORT=""
GATEWAY_RUNNING=false

cmd_gateway() {
  local port="" verbose=false daemon=false stop=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port) port="$2"; shift 2 ;;
      -v|--verbose) verbose=true; shift ;;
      -d|--daemon) daemon=true; shift ;;
      --stop) stop=true; shift ;;
      -h|--help) _cmd_gateway_usage; return 0 ;;
      *) log_error "Unknown option: $1"; _cmd_gateway_usage; return 1 ;;
    esac
  done

  if [[ "$verbose" == "true" ]]; then
    LOG_LEVEL="debug"
  fi

  GATEWAY_PORT="${port:-$(config_get '.gateway.port' '18789')}"
  GATEWAY_PID_FILE="${BASHCLAW_STATE_DIR:?}/gateway.pid"

  if [[ "$stop" == "true" ]]; then
    gateway_shutdown
    return $?
  fi

  if [[ "$daemon" == "true" ]]; then
    gateway_start_daemon
    return $?
  fi

  gateway_start
}

gateway_start() {
  # Check port availability
  if ! is_port_available "$GATEWAY_PORT"; then
    log_error "Port $GATEWAY_PORT is already in use"
    return 1
  fi

  # Write PID file
  printf '%s' "$$" > "$GATEWAY_PID_FILE"
  GATEWAY_RUNNING=true

  # Install signal handlers
  trap 'gateway_handle_sigint' INT
  trap 'gateway_handle_sigterm' TERM
  trap 'gateway_reload' USR1

  log_info "Gateway starting on port $GATEWAY_PORT (pid=$$)"
  printf 'Dashboard: http://localhost:%s\n' "$GATEWAY_PORT"

  # Fire gateway_start hook event
  if declare -f hooks_run &>/dev/null; then
    hooks_run "gateway_start" "{\"port\":$GATEWAY_PORT,\"pid\":$$}" 2>/dev/null || true
  fi

  # Start background services
  gateway_start_channels &
  local channels_pid=$!

  gateway_cron_runner &
  local cron_pid=$!

  gateway_health_monitor &
  local health_pid=$!

  # Start the HTTP server (foreground)
  if is_command_available socat; then
    gateway_run_socat
  elif is_command_available nc; then
    gateway_run_nc
  else
    log_warn "No HTTP server available (need socat or nc)"
    log_warn "Gateway is running but cannot serve HTTP."
    log_warn "CLI and channel listeners will still work."
    while [[ "$GATEWAY_RUNNING" == "true" ]]; do
      sleep 10
    done
  fi

  # Cleanup on exit
  GATEWAY_RUNNING=false

  # Fire gateway_stop hook event
  if declare -f hooks_run &>/dev/null; then
    hooks_run "gateway_stop" "{\"port\":$GATEWAY_PORT}" 2>/dev/null || true
  fi

  kill "$channels_pid" "$cron_pid" "$health_pid" 2>/dev/null
  wait "$channels_pid" "$cron_pid" "$health_pid" 2>/dev/null
  rm -f "$GATEWAY_PID_FILE"
  rm -f "${BASHCLAW_STATE_DIR:?}/gateway.fifo"
  log_info "Gateway stopped"
}

gateway_start_daemon() {
  log_info "Starting gateway as daemon..."

  # Check for existing daemon
  if [[ -f "$GATEWAY_PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$GATEWAY_PID_FILE" 2>/dev/null)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log_error "Gateway already running (pid=$existing_pid)"
      return 1
    fi
    rm -f "$GATEWAY_PID_FILE"
  fi

  local log_file="${BASHCLAW_STATE_DIR:?}/logs/gateway.log"
  ensure_dir "$(dirname "$log_file")"

  nohup bash -c "
    export BASHCLAW_STATE_DIR='${BASHCLAW_STATE_DIR}'
    export LOG_FILE='${log_file}'
    $(declare -p GATEWAY_PORT 2>/dev/null)
    source '${BASH_SOURCE[0]%/*}/../bashclaw'
    gateway_start
  " >> "$log_file" 2>&1 &

  local daemon_pid=$!
  printf '%s' "$daemon_pid" > "$GATEWAY_PID_FILE"
  log_info "Gateway daemon started (pid=$daemon_pid, log=$log_file)"
}

gateway_shutdown() {
  if [[ ! -f "$GATEWAY_PID_FILE" ]]; then
    log_warn "No gateway PID file found"
    return 1
  fi

  local pid
  pid="$(cat "$GATEWAY_PID_FILE" 2>/dev/null)"
  if [[ -z "$pid" ]]; then
    log_warn "Empty PID file"
    rm -f "$GATEWAY_PID_FILE"
    return 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    log_warn "Gateway process $pid not running"
    rm -f "$GATEWAY_PID_FILE"
    return 1
  fi

  log_info "Stopping gateway (pid=$pid)..."
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    log_warn "Gateway did not stop gracefully, sending SIGKILL"
    kill -9 "$pid" 2>/dev/null
  fi

  rm -f "$GATEWAY_PID_FILE"
  log_info "Gateway stopped"
}

gateway_reload() {
  log_info "Gateway reloading configuration (USR1)..."
  config_reload
  log_info "Configuration reloaded"
}

gateway_handle_sigint() {
  log_info "Gateway received SIGINT, shutting down..."
  GATEWAY_RUNNING=false
  exit 0
}

gateway_handle_sigterm() {
  log_info "Gateway received SIGTERM, shutting down..."
  GATEWAY_RUNNING=false
  exit 0
}

# ---- HTTP Servers ----

gateway_run_socat() {
  log_info "Starting HTTP server via socat on port $GATEWAY_PORT"
  local handler_script
  handler_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gateway/http_handler.sh"
  socat TCP-LISTEN:"$GATEWAY_PORT",reuseaddr,fork \
    EXEC:"bash '$handler_script'" \
    2>&1 || log_error "socat exited"
}

gateway_run_nc() {
  local handler_script
  handler_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gateway/http_handler.sh"

  local fifo_path="${BASHCLAW_STATE_DIR:?}/gateway.fifo"
  rm -f "$fifo_path"
  mkfifo "$fifo_path"

  # Detect nc flavor: OpenBSD nc (macOS/Ubuntu) uses "nc -l PORT",
  # GNU/BusyBox nc uses "nc -l -p PORT"
  local nc_args="-l"
  if nc -h 2>&1 | grep -q '\-p'; then
    nc_args="-l -p"
  fi

  log_info "Starting HTTP server via nc + FIFO on port $GATEWAY_PORT (nc_args='$nc_args')"

  while [[ "$GATEWAY_RUNNING" == "true" ]]; do
    nc $nc_args "$GATEWAY_PORT" < "$fifo_path" | \
      bash "$handler_script" > "$fifo_path" 2>/dev/null || true
  done

  rm -f "$fifo_path"
}

# ---- Channel Listeners ----

gateway_start_channels() {
  log_info "Starting channel listeners..."

  local channels_enabled
  channels_enabled="$(config_get_raw '.channels | keys // []' 2>/dev/null)"
  if [[ "$channels_enabled" == "null" || "$channels_enabled" == "[]" ]]; then
    log_info "No channels configured"
    return 0
  fi

  local num_channels
  num_channels="$(printf '%s' "$channels_enabled" | jq 'length')"

  local channel_dir
  channel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels"

  local i=0
  while (( i < num_channels )); do
    local ch_name
    ch_name="$(printf '%s' "$channels_enabled" | jq -r ".[$i]")"

    # Skip non-channel config keys
    case "$ch_name" in
      defaults|_*) i=$((i + 1)); continue ;;
    esac

    local ch_enabled
    ch_enabled="$(config_channel_get "$ch_name" "enabled" "true")"
    if [[ "$ch_enabled" != "true" ]]; then
      log_debug "Channel disabled: $ch_name"
      i=$((i + 1))
      continue
    fi

    local ch_script="${channel_dir}/${ch_name}.sh"
    if [[ ! -f "$ch_script" ]]; then
      log_warn "Channel script not found: $ch_script"
      i=$((i + 1))
      continue
    fi

    log_info "Starting channel: $ch_name"
    (
      source "$ch_script"
      local start_func="channel_${ch_name}_start"
      if declare -f "$start_func" &>/dev/null; then
        "$start_func"
      else
        log_warn "No start function for channel: $ch_name"
      fi
    ) &

    i=$((i + 1))
  done

  # Wait for all channel listeners
  wait
}

# ---- Cron Runner ----

gateway_cron_runner() {
  log_info "Cron runner starting..."

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  ensure_dir "$cron_dir"

  while [[ "$GATEWAY_RUNNING" != "false" ]]; do
    sleep 60

    local f
    for f in "${cron_dir}"/*.json; do
      [[ -f "$f" ]] || continue

      local job
      job="$(cat "$f" 2>/dev/null)" || continue
      local enabled schedule command job_id agent_id
      enabled="$(printf '%s' "$job" | jq -r '.enabled // false')"
      if [[ "$enabled" != "true" ]]; then
        continue
      fi

      schedule="$(printf '%s' "$job" | jq -r '.schedule // ""')"
      command="$(printf '%s' "$job" | jq -r '.command // ""')"
      job_id="$(printf '%s' "$job" | jq -r '.id // ""')"
      agent_id="$(printf '%s' "$job" | jq -r '.agent_id // "main"')"

      if [[ -z "$schedule" || -z "$command" ]]; then
        continue
      fi

      if cron_matches_now "$schedule"; then
        log_info "Cron job triggered: id=$job_id schedule=$schedule"
        (
          agent_run "$agent_id" "$command" "cron" "cron:${job_id}"
        ) &
      fi
    done
  done
}

cron_matches_now() {
  local schedule="$1"

  # Parse cron expression: minute hour day month weekday
  # Use set -- for Bash 3.2 compatibility (no read -ra)
  local old_ifs="$IFS"
  IFS=' '
  set -- $schedule
  IFS="$old_ifs"
  if [ "$#" -lt 5 ]; then
    return 1
  fi
  local f_min="$1" f_hour="$2" f_day="$3" f_month="$4" f_dow="$5"

  local now_min now_hour now_day now_month now_dow
  now_min=$(( 10#$(date +%M) ))
  now_hour=$(( 10#$(date +%H) ))
  now_day=$(( 10#$(date +%d) ))
  now_month=$(( 10#$(date +%m) ))
  now_dow="$(date +%u)"  # 1=Monday, 7=Sunday

  cron_field_matches "$f_min" "$now_min" 0 59 || return 1
  cron_field_matches "$f_hour" "$now_hour" 0 23 || return 1
  cron_field_matches "$f_day" "$now_day" 1 31 || return 1
  cron_field_matches "$f_month" "$now_month" 1 12 || return 1
  cron_field_matches "$f_dow" "$now_dow" 0 7 || return 1

  return 0
}

cron_field_matches() {
  local field="$1"
  local current="$2"
  local min_val="$3"
  local max_val="$4"

  # Wildcard
  if [[ "$field" == "*" ]]; then
    return 0
  fi

  # Handle */N step values
  if [[ "$field" == *"/"* ]]; then
    local base="${field%%/*}"
    local step="${field##*/}"
    if [[ "$base" == "*" ]]; then
      base="$min_val"
    fi
    if (( step > 0 && (current - base) % step == 0 && current >= base )); then
      return 0
    fi
    return 1
  fi

  # Handle comma-separated values
  if [[ "$field" == *","* ]]; then
    local IFS=','
    local val
    for val in $field; do
      if (( val == current )); then
        return 0
      fi
    done
    return 1
  fi

  # Handle range (N-M)
  if [[ "$field" == *"-"* ]]; then
    local range_start="${field%%-*}"
    local range_end="${field##*-}"
    if (( current >= range_start && current <= range_end )); then
      return 0
    fi
    return 1
  fi

  # Exact match
  if (( field == current )); then
    return 0
  fi

  return 1
}

# ---- Health Monitor ----

gateway_health_monitor() {
  log_info "Health monitor starting..."

  while [[ "$GATEWAY_RUNNING" != "false" ]]; do
    sleep 300  # 5 minutes

    # Check disk space
    local disk_usage
    if [[ "$(uname -s)" == "Darwin" ]]; then
      disk_usage="$(df -h "${BASHCLAW_STATE_DIR}" | tail -1 | awk '{print $5}' | tr -d '%')"
    else
      disk_usage="$(df -h "${BASHCLAW_STATE_DIR}" | tail -1 | awk '{print $5}' | tr -d '%')"
    fi

    if [[ -n "$disk_usage" ]] && (( disk_usage > 90 )); then
      log_warn "Disk usage is ${disk_usage}% - consider cleaning up state directory"
    fi

    # Check session file count
    local session_count=0
    if [[ -d "${BASHCLAW_STATE_DIR}/sessions" ]]; then
      session_count="$(find "${BASHCLAW_STATE_DIR}/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
    fi
    log_debug "Health check: disk=${disk_usage:-?}% sessions=$session_count"
  done
}

_cmd_gateway_usage() {
  cat <<'EOF'
Usage: bashclaw gateway [options]

Options:
  -p, --port PORT    Server port (default: from config or 18789)
  -v, --verbose      Enable debug logging
  -d, --daemon       Run as background daemon
  --stop             Stop running gateway daemon
  -h, --help         Show this help

The gateway runs channel listeners, a cron runner, and an HTTP server
for the web dashboard and API.

HTTP server: socat (concurrent) or nc + FIFO (serial fallback).
For production, put nginx/caddy in front as reverse proxy.
EOF
}
