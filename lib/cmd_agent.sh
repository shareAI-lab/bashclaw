#!/usr/bin/env bash
# Agent CLI command for bashclaw

cmd_agent() {
  local message="" agent_id="main" channel="default" sender="" interactive=false verbose=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message) message="$2"; shift 2 ;;
      -a|--agent) agent_id="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -s|--sender) sender="$2"; shift 2 ;;
      -i|--interactive) interactive=true; shift ;;
      -v|--verbose) verbose=true; shift ;;
      -h|--help) _cmd_agent_usage; return 0 ;;
      *) message="$*"; break ;;
    esac
  done

  if [[ "$verbose" == "true" ]]; then
    LOG_LEVEL="debug"
  fi

  if [[ "$interactive" == "true" ]]; then
    cmd_agent_interactive "$agent_id" "$channel" "$sender"
    return $?
  fi

  if [[ -z "$message" ]]; then
    log_error "Message is required. Use -m 'message' or -i for interactive mode."
    _cmd_agent_usage
    return 1
  fi

  local response
  response="$(agent_run "$agent_id" "$message" "$channel" "$sender")"
  if [[ -n "$response" ]]; then
    printf '%s\n' "$response"
  fi
}

cmd_agent_interactive() {
  local agent_id="${1:-main}"
  local channel="${2:-default}"
  local sender="${3:-cli}"

  log_info "Interactive mode: agent=$agent_id channel=$channel"
  printf 'Bashclaw interactive mode (agent: %s)\n' "$agent_id"
  printf 'Commands: /reset /history /status /quit\n\n'

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  local _use_readline=false
  local _history_file="${BASHCLAW_STATE_DIR}/history"
  if (echo "" | read -e 2>/dev/null); then
    _use_readline=true
    if [[ -f "$_history_file" ]]; then
      history -r "$_history_file" 2>/dev/null || true
    fi
  fi

  while true; do
    local input
    if [[ "$_use_readline" == "true" ]]; then
      if ! IFS= read -e -r -p 'You: ' input; then
        printf '\n'
        break
      fi
    else
      printf 'You: '
      if ! IFS= read -r input; then
        printf '\n'
        break
      fi
    fi

    input="$(trim "$input")"
    if [[ -z "$input" ]]; then
      continue
    fi

    if [[ "$_use_readline" == "true" ]]; then
      history -s "$input" 2>/dev/null || true
      history -a "$_history_file" 2>/dev/null || true
    fi

    # Handle slash commands
    case "$input" in
      /reset)
        session_clear "$sess_file"
        printf 'Session cleared.\n\n'
        continue
        ;;
      /history)
        local history
        history="$(session_load "$sess_file")"
        local count
        count="$(printf '%s' "$history" | jq 'length')"
        printf 'Session history: %s messages\n' "$count"
        printf '%s' "$history" | jq -r '.[] | "\(.role): \(.content // .tool_name // "[tool]")"' 2>/dev/null | tail -20
        printf '\n'
        continue
        ;;
      /status)
        local model provider
        model="$(agent_resolve_model "$agent_id")"
        provider="$(agent_resolve_provider "$model")"
        local msg_count
        msg_count="$(session_count "$sess_file")"
        printf 'Agent: %s\n' "$agent_id"
        printf 'Model: %s (%s)\n' "$model" "$provider"
        printf 'Channel: %s\n' "$channel"
        printf 'Session messages: %s\n' "$msg_count"
        printf '\n'
        continue
        ;;
      /quit|/exit|/q)
        printf 'Goodbye.\n'
        break
        ;;
      /*)
        printf 'Unknown command: %s\n\n' "$input"
        continue
        ;;
    esac

    local response
    response="$(agent_run "$agent_id" "$input" "$channel" "$sender")"
    if [[ -n "$response" ]]; then
      printf 'Assistant: %s\n\n' "$response"
    else
      printf 'Assistant: [no response]\n\n'
    fi
  done
}

_cmd_agent_usage() {
  cat <<'EOF'
Usage: bashclaw agent [options] [message]

Options:
  -m, --message TEXT    Message to send to the agent
  -a, --agent ID        Agent ID (default: main)
  -c, --channel NAME    Channel context (default: default)
  -s, --sender ID       Sender identifier
  -i, --interactive     Start interactive REPL mode
  -v, --verbose         Enable debug logging
  -h, --help            Show this help

Interactive commands:
  /reset    Clear session history
  /history  Show recent session history
  /status   Show agent status
  /quit     Exit interactive mode
EOF
}
