#!/usr/bin/env bash
# Engine abstraction layer for bashclaw
# Routes agent execution to builtin runtime, Claude Code CLI, or other agent CLIs

# Detect available CLI engines on the system
engine_detect() {
  if is_command_available claude; then
    printf 'claude'
  elif is_command_available codex; then
    printf 'codex'
  else
    printf 'builtin'
  fi
}

# Resolve which engine to use for an agent
engine_resolve() {
  local agent_id="${1:-main}"

  local engine
  engine="$(config_agent_get "$agent_id" "engine" "")"

  if [[ -z "$engine" ]]; then
    engine="$(config_get '.agents.defaults.engine' 'builtin')"
  fi

  case "$engine" in
    builtin|claude|codex)
      printf '%s' "$engine"
      ;;
    auto)
      engine_detect
      ;;
    *)
      printf 'builtin'
      ;;
  esac
}

# Universal entry point for agent execution
engine_run() {
  local agent_id="${1:-main}"
  local message="$2"
  local channel="${3:-default}"
  local sender="${4:-}"
  local is_subagent="${5:-false}"

  local engine
  engine="$(engine_resolve "$agent_id")"
  log_debug "engine_run: agent=$agent_id engine=$engine"

  # before_agent_start hook
  if declare -f hooks_run &>/dev/null; then
    hooks_run "before_agent_start" "$(jq -nc --arg aid "$agent_id" --arg eng "$engine" --arg ch "$channel" \
      '{agent_id: $aid, engine: $eng, channel: $ch}' 2>/dev/null)" 2>/dev/null || true
  fi

  # pre_message hook (modifying: can alter message)
  if declare -f hooks_run &>/dev/null; then
    local hook_input
    hook_input="$(jq -nc --arg aid "$agent_id" --arg ch "$channel" --arg msg "$message" \
      '{agent_id: $aid, channel: $ch, message: $msg}' 2>/dev/null)"
    hook_input="$(hooks_run "pre_message" "$hook_input" 2>/dev/null)" || true
    local modified_msg
    modified_msg="$(printf '%s' "$hook_input" | jq -r '.message // empty' 2>/dev/null)"
    if [[ -n "$modified_msg" ]]; then
      message="$modified_msg"
    fi
  fi

  local response=""
  case "$engine" in
    claude)
      if declare -f engine_claude_run &>/dev/null; then
        response="$(engine_claude_run "$agent_id" "$message" "$channel" "$sender" "$is_subagent")"
      else
        log_warn "Claude engine not available, falling back to builtin"
        response="$(agent_run "$agent_id" "$message" "$channel" "$sender" "$is_subagent")"
      fi
      ;;
    builtin|*)
      response="$(agent_run "$agent_id" "$message" "$channel" "$sender" "$is_subagent")"
      ;;
  esac

  # post_message hook
  if declare -f hooks_run &>/dev/null; then
    hooks_run "post_message" "$(jq -nc --arg aid "$agent_id" --arg ch "$channel" --arg resp "${response:0:500}" \
      '{agent_id: $aid, channel: $ch, response: $resp}' 2>/dev/null)" 2>/dev/null || true
  fi

  # agent_end hook
  if declare -f hooks_run &>/dev/null; then
    hooks_run "agent_end" "$(jq -nc --arg aid "$agent_id" --arg eng "$engine" --arg ch "$channel" \
      '{agent_id: $aid, engine: $eng, channel: $ch}' 2>/dev/null)" 2>/dev/null || true
  fi

  printf '%s' "$response"
}

# Return JSON info about detected engines
engine_info() {
  require_command jq "engine_info requires jq"

  local claude_ver=""
  if is_command_available claude; then
    claude_ver="$(claude --version 2>/dev/null || echo 'unknown')"
  fi

  local codex_ver=""
  if is_command_available codex; then
    codex_ver="$(codex --version 2>/dev/null || echo 'unknown')"
  fi

  local current_default
  current_default="$(config_get '.agents.defaults.engine' 'builtin')"

  local detected
  detected="$(engine_detect)"

  jq -nc \
    --arg detected "$detected" \
    --arg claude_ver "$claude_ver" \
    --arg codex_ver "$codex_ver" \
    --arg default_engine "$current_default" \
    '{
      detected: $detected,
      default: $default_engine,
      engines: {
        builtin: {available: true},
        claude: {available: ($claude_ver != ""), version: $claude_ver},
        codex: {available: ($codex_ver != ""), version: $codex_ver}
      }
    }'
}
