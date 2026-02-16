#!/usr/bin/env bash
# Cron job management command for bashclaw

cmd_cron() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    list)    _cmd_cron_list ;;
    add)     _cmd_cron_add "$@" ;;
    remove)  _cmd_cron_remove "$@" ;;
    enable)  _cmd_cron_toggle "$1" "true" ;;
    disable) _cmd_cron_toggle "$1" "false" ;;
    run)     _cmd_cron_run "$@" ;;
    history) _cmd_cron_history "$@" ;;
    -h|--help|help|"") _cmd_cron_usage ;;
    *) log_error "Unknown cron subcommand: $subcommand"; _cmd_cron_usage; return 1 ;;
  esac
}

_cmd_cron_list() {
  require_command jq "cron list requires jq"

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  if [[ ! -d "$cron_dir" ]]; then
    printf 'No cron jobs found.\n'
    return 0
  fi

  local count=0
  local f
  for f in "${cron_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local id schedule command enabled agent_id
    id="$(jq -r '.id // "?"' < "$f" 2>/dev/null)"
    schedule="$(jq -r '.schedule // "?"' < "$f" 2>/dev/null)"
    command="$(jq -r '.command // "?" | .[0:60]' < "$f" 2>/dev/null)"
    enabled="$(jq -r '.enabled // false' < "$f" 2>/dev/null)"
    agent_id="$(jq -r '.agent_id // "main"' < "$f" 2>/dev/null)"

    local status_str="disabled"
    if [[ "$enabled" == "true" ]]; then
      status_str="enabled"
    fi

    printf '  %-20s  %-15s  %-8s  agent=%-8s  %s\n' "$id" "$schedule" "$status_str" "$agent_id" "$command"
    count=$((count + 1))
  done

  if (( count == 0 )); then
    printf 'No cron jobs found.\n'
  else
    printf '\nTotal: %d jobs\n' "$count"
  fi
}

_cmd_cron_add() {
  local schedule="" command="" agent_id="" job_id=""

  if [[ $# -ge 2 && "$1" != -* ]]; then
    schedule="$1"
    command="$2"
    shift 2
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent_id="$2"; shift 2 ;;
      --id) job_id="$2"; shift 2 ;;
      -h|--help) _cmd_cron_usage; return 0 ;;
      *)
        if [[ -z "$schedule" ]]; then
          schedule="$1"
        elif [[ -z "$command" ]]; then
          command="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$schedule" || -z "$command" ]]; then
    log_error "Schedule and command are required"
    printf 'Usage: bashclaw cron add "SCHEDULE" "COMMAND" [--agent AGENT] [--id ID]\n'
    return 1
  fi

  require_command jq "cron add requires jq"

  agent_id="${agent_id:-main}"
  if [[ -z "$job_id" ]]; then
    job_id="$(uuid_generate)"
  fi

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  ensure_dir "$cron_dir"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local safe_id
  safe_id="$(sanitize_key "$job_id")"

  jq -nc \
    --arg id "$job_id" \
    --arg sched "$schedule" \
    --arg cmd "$command" \
    --arg aid "$agent_id" \
    --arg ts "$ts" \
    '{id: $id, schedule: $sched, command: $cmd, agent_id: $aid, created_at: $ts, enabled: true}' \
    > "${cron_dir}/${safe_id}.json"

  printf 'Cron job added: %s\n' "$job_id"
  printf '  Schedule: %s\n' "$schedule"
  printf '  Command:  %s\n' "$command"
  printf '  Agent:    %s\n' "$agent_id"
}

_cmd_cron_remove() {
  local job_id="${1:-}"

  if [[ -z "$job_id" ]]; then
    log_error "Job ID is required"
    printf 'Usage: bashclaw cron remove ID\n'
    return 1
  fi

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  local safe_id
  safe_id="$(sanitize_key "$job_id")"
  local file="${cron_dir}/${safe_id}.json"

  if [[ -f "$file" ]]; then
    rm -f "$file"
    printf 'Removed cron job: %s\n' "$job_id"
  else
    printf 'Cron job not found: %s\n' "$job_id"
    return 1
  fi
}

_cmd_cron_toggle() {
  local job_id="${1:-}"
  local enabled="${2:-true}"

  if [[ -z "$job_id" ]]; then
    log_error "Job ID is required"
    return 1
  fi

  require_command jq "cron enable/disable requires jq"

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  local safe_id
  safe_id="$(sanitize_key "$job_id")"
  local file="${cron_dir}/${safe_id}.json"

  if [[ ! -f "$file" ]]; then
    printf 'Cron job not found: %s\n' "$job_id"
    return 1
  fi

  local updated
  updated="$(jq --arg e "$enabled" '.enabled = ($e == "true")' < "$file")"
  printf '%s\n' "$updated" > "$file"

  if [[ "$enabled" == "true" ]]; then
    printf 'Enabled cron job: %s\n' "$job_id"
  else
    printf 'Disabled cron job: %s\n' "$job_id"
  fi
}

_cmd_cron_run() {
  local job_id="${1:-}"

  if [[ -z "$job_id" ]]; then
    log_error "Job ID is required"
    printf 'Usage: bashclaw cron run ID\n'
    return 1
  fi

  require_command jq "cron run requires jq"

  local cron_dir="${BASHCLAW_STATE_DIR:?}/cron"
  local safe_id
  safe_id="$(sanitize_key "$job_id")"
  local file="${cron_dir}/${safe_id}.json"

  if [[ ! -f "$file" ]]; then
    printf 'Cron job not found: %s\n' "$job_id"
    return 1
  fi

  local command agent_id
  command="$(jq -r '.command // ""' < "$file")"
  agent_id="$(jq -r '.agent_id // "main"' < "$file")"

  if [[ -z "$command" ]]; then
    log_error "Cron job has no command"
    return 1
  fi

  printf 'Running cron job: %s\n' "$job_id"
  printf 'Agent: %s\n' "$agent_id"
  printf 'Command: %s\n\n' "$command"

  local result
  result="$(agent_run "$agent_id" "$command" "cron" "cron:${job_id}")"

  # Log to history
  local history_dir="${BASHCLAW_STATE_DIR:?}/cron/history"
  ensure_dir "$history_dir"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local entry
  entry="$(jq -nc --arg id "$job_id" --arg ts "$ts" --arg out "$result" \
    '{job_id: $id, ran_at: $ts, output: $out}')"
  printf '%s\n' "$entry" >> "${history_dir}/runs.jsonl"

  if [[ -n "$result" ]]; then
    printf '%s\n' "$result"
  else
    printf '[no output]\n'
  fi
}

_cmd_cron_history() {
  local limit=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "cron history requires jq"

  local history_file="${BASHCLAW_STATE_DIR:?}/cron/history/runs.jsonl"
  if [[ ! -f "$history_file" ]]; then
    printf 'No cron history found.\n'
    return 0
  fi

  printf 'Recent cron runs:\n'
  tail -n "$limit" "$history_file" | jq -r '"  [\(.ran_at)] job=\(.job_id) output=\(.output | .[0:80])"' 2>/dev/null
}

_cmd_cron_usage() {
  cat <<'EOF'
Usage: bashclaw cron <subcommand> [options]

Subcommands:
  list                              List all cron jobs
  add "SCHEDULE" "COMMAND" [opts]   Add a cron job
  remove ID                         Remove a cron job
  enable ID                         Enable a cron job
  disable ID                        Disable a cron job
  run ID                            Manually trigger a cron job
  history [--limit N]               Show cron execution history

Add options:
  --agent AGENT    Agent to handle the job (default: main)
  --id ID          Custom job ID (auto-generated if omitted)

Schedule format: standard cron expression (minute hour day month weekday)
  Examples:
    "*/5 * * * *"     Every 5 minutes
    "0 9 * * 1-5"     Weekdays at 9am
    "0 */2 * * *"     Every 2 hours

Examples:
  bashclaw cron add "*/10 * * * *" "check system status" --agent main
  bashclaw cron list
  bashclaw cron disable my-job
  bashclaw cron run my-job
  bashclaw cron history --limit 10
EOF
}
