#!/usr/bin/env bash
# Claude Code CLI engine for bashclaw
# Delegates agent execution to the Claude Code CLI (claude -p --output-format stream-json)

ENGINE_CLAUDE_TIMEOUT="${ENGINE_CLAUDE_TIMEOUT:-300}"

engine_claude_available() {
  is_command_available claude
}

engine_claude_version() {
  if engine_claude_available; then
    claude --version 2>/dev/null || printf 'unknown'
  else
    printf ''
  fi
}

# Read Claude Code session_id from BashClaw session metadata
engine_claude_session_id() {
  local session_file="$1"
  session_meta_get "$session_file" "cc_session_id" ""
}

# Core Claude Code CLI execution
engine_claude_run() {
  local agent_id="${1:-main}"
  local message="$2"
  local channel="${3:-default}"
  local sender="${4:-}"

  if ! engine_claude_available; then
    log_error "Claude CLI not found"
    printf ''
    return 1
  fi

  require_command jq "engine_claude_run requires jq"

  # Resolve session file
  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"
  session_meta_load "$sess_file" >/dev/null 2>&1

  # Append user message to BashClaw session for history tracking
  session_append "$sess_file" "user" "$message"

  # Resolve model and max_turns from agent config
  local model
  model="$(config_agent_get "$agent_id" "model" "")"
  if [[ -z "$model" ]]; then
    model="${MODEL_ID:-claude-opus-4-6}"
  fi

  local max_turns
  max_turns="$(config_agent_get "$agent_id" "maxTurns" "50")"

  # Build CLI arguments
  local args=()
  args+=(--output-format stream-json)
  args+=(--model "$model")
  args+=(--max-turns "$max_turns")

  # Resume existing Claude Code session if available
  local cc_session_id
  cc_session_id="$(engine_claude_session_id "$sess_file")"
  if [[ -n "$cc_session_id" ]]; then
    args+=(--resume "$cc_session_id")
  fi

  # System prompt
  local system_prompt
  system_prompt="$(agent_build_system_prompt "$agent_id" "false" "$channel")"
  if [[ -n "$system_prompt" ]]; then
    args+=(--append-system-prompt "$system_prompt")
  fi

  # Allowed tools from agent config
  local tools_config
  tools_config="$(config_agent_get_raw "$agent_id" '.tools.allow // null')"
  if [[ -n "$tools_config" && "$tools_config" != "null" && "$tools_config" != "[]" ]]; then
    local tool_name
    while IFS= read -r tool_name; do
      [[ -z "$tool_name" ]] && continue
      args+=(--allowedTools "$tool_name")
    done < <(printf '%s' "$tools_config" | jq -r '.[]' 2>/dev/null)
  fi

  log_info "engine_claude: model=$model agent=$agent_id session=${cc_session_id:-new}"

  # Execute claude CLI and capture NDJSON output
  local response_file
  response_file="$(tmpfile "claude_engine")"

  claude -p "$message" "${args[@]}" 2>/dev/null > "$response_file" &
  local claude_pid=$!

  # Wait with absolute timeout
  local waited=0
  while kill -0 "$claude_pid" 2>/dev/null; do
    if (( waited >= ENGINE_CLAUDE_TIMEOUT )); then
      kill "$claude_pid" 2>/dev/null || true
      log_warn "Claude CLI timed out after ${ENGINE_CLAUDE_TIMEOUT}s"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$claude_pid" 2>/dev/null || true

  # Parse NDJSON output
  local final_text=""
  local new_session_id=""
  local total_cost=""
  local num_turns=""

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local msg_type
    msg_type="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"

    case "$msg_type" in
      system)
        local sid
        sid="$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null)"
        if [[ -n "$sid" ]]; then
          new_session_id="$sid"
        fi
        ;;
      assistant)
        local text
        text="$(printf '%s' "$line" | jq -r '
          [.message.content[]? | select(.type == "text") | .text] | join("")
        ' 2>/dev/null)"
        if [[ -n "$text" ]]; then
          final_text="$text"
        fi
        ;;
      result)
        local rtext
        rtext="$(printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null)"
        if [[ -n "$rtext" ]]; then
          final_text="$rtext"
        fi
        total_cost="$(printf '%s' "$line" | jq -r '.total_cost_usd // empty' 2>/dev/null)"
        num_turns="$(printf '%s' "$line" | jq -r '.num_turns // empty' 2>/dev/null)"
        ;;
    esac
  done < "$response_file"

  rm -f "$response_file"

  # Persist Claude Code session_id for future --resume
  if [[ -n "$new_session_id" ]]; then
    session_meta_update "$sess_file" "cc_session_id" "\"${new_session_id}\""
  fi

  # Append assistant response to BashClaw session
  if [[ -n "$final_text" ]]; then
    session_append "$sess_file" "assistant" "$final_text"
  fi

  # Track cost metadata
  if [[ -n "$total_cost" ]]; then
    session_meta_update "$sess_file" "cc_total_cost_usd" "\"${total_cost}\""
  fi
  if [[ -n "$num_turns" ]]; then
    session_meta_update "$sess_file" "cc_num_turns" "$num_turns"
  fi

  printf '%s' "$final_text"
}
