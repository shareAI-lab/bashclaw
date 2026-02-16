#!/usr/bin/env bash
# Hooks management command for bashclaw

cmd_hooks() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    list)    _cmd_hooks_list ;;
    add)     _cmd_hooks_add "$@" ;;
    remove)  _cmd_hooks_remove "$@" ;;
    enable)  _cmd_hooks_toggle "$1" "true" ;;
    disable) _cmd_hooks_toggle "$1" "false" ;;
    test)    _cmd_hooks_test "$@" ;;
    -h|--help|help|"") _cmd_hooks_usage ;;
    *) log_error "Unknown hooks subcommand: $subcommand"; _cmd_hooks_usage; return 1 ;;
  esac
}

_hooks_dir() {
  printf '%s/hooks' "${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}"
}

_cmd_hooks_list() {
  require_command jq "hooks list requires jq"

  local hooks_dir
  hooks_dir="$(_hooks_dir)"
  if [[ ! -d "$hooks_dir" ]]; then
    printf 'No hooks configured.\n'
    return 0
  fi

  local count=0
  local f
  for f in "${hooks_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local name event script enabled
    name="$(jq -r '.name // "?"' < "$f" 2>/dev/null)"
    event="$(jq -r '.event // "?"' < "$f" 2>/dev/null)"
    script="$(jq -r '.script // "?"' < "$f" 2>/dev/null)"
    enabled="$(jq -r '.enabled // false' < "$f" 2>/dev/null)"

    local status_str="disabled"
    if [[ "$enabled" == "true" ]]; then
      status_str="enabled"
    fi

    printf '  %-20s  event=%-20s  %-8s  %s\n' "$name" "$event" "$status_str" "$script"
    count=$((count + 1))
  done

  if (( count == 0 )); then
    printf 'No hooks configured.\n'
  else
    printf '\nTotal: %d hooks\n' "$count"
  fi
}

_cmd_hooks_add() {
  local name="" event="" script=""

  if [[ $# -ge 1 && "$1" != -* ]]; then
    name="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --event) event="$2"; shift 2 ;;
      --script) script="$2"; shift 2 ;;
      -h|--help) _cmd_hooks_usage; return 0 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$name" || -z "$event" || -z "$script" ]]; then
    log_error "Name, event, and script are required"
    printf 'Usage: bashclaw hooks add NAME --event EVENT --script PATH\n'
    return 1
  fi

  if [[ ! -f "$script" ]]; then
    log_error "Script file not found: $script"
    return 1
  fi

  require_command jq "hooks add requires jq"

  local hooks_dir
  hooks_dir="$(_hooks_dir)"
  ensure_dir "$hooks_dir"

  local safe_name
  safe_name="$(sanitize_key "$name")"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local abs_script
  if [[ "$script" = /* ]]; then
    abs_script="$script"
  else
    abs_script="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"
  fi

  jq -nc \
    --arg name "$name" \
    --arg event "$event" \
    --arg script "$abs_script" \
    --arg ts "$ts" \
    '{name: $name, event: $event, script: $script, enabled: true, created_at: $ts}' \
    > "${hooks_dir}/${safe_name}.json"

  printf 'Hook added: %s\n' "$name"
  printf '  Event:  %s\n' "$event"
  printf '  Script: %s\n' "$abs_script"
}

_cmd_hooks_remove() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    log_error "Hook name is required"
    printf 'Usage: bashclaw hooks remove NAME\n'
    return 1
  fi

  local hooks_dir
  hooks_dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${hooks_dir}/${safe_name}.json"

  if [[ -f "$file" ]]; then
    rm -f "$file"
    printf 'Removed hook: %s\n' "$name"
  else
    printf 'Hook not found: %s\n' "$name"
    return 1
  fi
}

_cmd_hooks_toggle() {
  local name="${1:-}"
  local enabled="${2:-true}"

  if [[ -z "$name" ]]; then
    log_error "Hook name is required"
    return 1
  fi

  require_command jq "hooks enable/disable requires jq"

  local hooks_dir
  hooks_dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${hooks_dir}/${safe_name}.json"

  if [[ ! -f "$file" ]]; then
    printf 'Hook not found: %s\n' "$name"
    return 1
  fi

  local updated
  updated="$(jq --arg e "$enabled" '.enabled = ($e == "true")' < "$file")"
  printf '%s\n' "$updated" > "$file"

  if [[ "$enabled" == "true" ]]; then
    printf 'Enabled hook: %s\n' "$name"
  else
    printf 'Disabled hook: %s\n' "$name"
  fi
}

_cmd_hooks_test() {
  local name="" input_json=""

  if [[ $# -ge 1 && "$1" != -* ]]; then
    name="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input) input_json="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$name" ]]; then
    log_error "Hook name is required"
    printf 'Usage: bashclaw hooks test NAME [--input JSON]\n'
    return 1
  fi

  require_command jq "hooks test requires jq"

  local hooks_dir
  hooks_dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${hooks_dir}/${safe_name}.json"

  if [[ ! -f "$file" ]]; then
    printf 'Hook not found: %s\n' "$name"
    return 1
  fi

  local script event
  script="$(jq -r '.script // ""' < "$file")"
  event="$(jq -r '.event // ""' < "$file")"

  if [[ -z "$script" || ! -f "$script" ]]; then
    log_error "Hook script not found: $script"
    return 1
  fi

  printf 'Testing hook: %s\n' "$name"
  printf 'Event:  %s\n' "$event"
  printf 'Script: %s\n\n' "$script"

  if [[ -n "$input_json" ]]; then
    BASHCLAW_HOOK_EVENT="$event" BASHCLAW_HOOK_INPUT="$input_json" bash "$script"
  else
    BASHCLAW_HOOK_EVENT="$event" bash "$script"
  fi

  local exit_code=$?
  printf '\nExit code: %d\n' "$exit_code"
  return "$exit_code"
}

_cmd_hooks_usage() {
  cat <<'EOF'
Usage: bashclaw hooks <subcommand> [options]

Subcommands:
  list                                   List all hooks
  add NAME --event EVENT --script PATH   Add a hook
  remove NAME                            Remove a hook
  enable NAME                            Enable a hook
  disable NAME                           Disable a hook
  test NAME [--input JSON]               Test a hook

Events:
  message.received     Triggered when a message is received
  message.sent         Triggered when a message is sent
  agent.start          Triggered when an agent starts
  agent.stop           Triggered when an agent stops
  session.created      Triggered when a session is created
  session.cleared      Triggered when a session is cleared
  gateway.start        Triggered when the gateway starts
  gateway.stop         Triggered when the gateway stops

Hook scripts receive these environment variables:
  BASHCLAW_HOOK_EVENT    The event name
  BASHCLAW_HOOK_INPUT    JSON input data (if provided)

Examples:
  bashclaw hooks add my-logger --event message.received --script /path/to/log.sh
  bashclaw hooks list
  bashclaw hooks test my-logger --input '{"text": "hello"}'
  bashclaw hooks disable my-logger
  bashclaw hooks remove my-logger
EOF
}
