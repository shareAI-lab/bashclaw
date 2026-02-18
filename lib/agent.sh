#!/usr/bin/env bash
# Core agent runtime loop
# Compatible with bash 3.2+ (no associative arrays)

# ---- Constants ----

BASHCLAW_RESERVE_TOKENS_FLOOR=20000
BASHCLAW_SOFT_THRESHOLD_TOKENS=4000
BASHCLAW_MAX_COMPACTION_RETRIES=3

AGENT_MAX_TOOL_ITERATIONS="${AGENT_MAX_TOOL_ITERATIONS:-10}"
AGENT_DEFAULT_TEMPERATURE="${AGENT_DEFAULT_TEMPERATURE:-0.7}"

# ---- Message Building ----

agent_build_messages() {
  local session_file="$1"
  local user_message="$2"
  local max_history="${3:-50}"

  require_command jq "agent_build_messages requires jq"

  local history
  history="$(session_load "$session_file" "$max_history")"

  local messages
  messages="$(printf '%s' "$history" | jq '[
    .[] |
    select(.type != "session") |
    if .type == "tool_call" then
      {
        role: "assistant",
        content: [{
          type: "tool_use",
          id: .tool_id,
          name: .tool_name,
          input: (if (.tool_input | type) == "string" then (.tool_input | fromjson? // {}) else (.tool_input // {}) end)
        }]
      }
    elif .type == "tool_result" then
      {
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: .tool_id,
          content: .content,
          is_error: (.is_error // false)
        }]
      }
    else
      {role: .role, content: .content}
    end
  ]')"

  if [[ -n "$user_message" ]]; then
    messages="$(printf '%s' "$messages" | jq --arg msg "$user_message" '. + [{role: "user", content: $msg}]')"
  fi

  printf '%s' "$messages"
}

# ---- Tool Spec ----

agent_build_tools_spec() {
  local agent_id="${1:-main}"

  require_command jq "agent_build_tools_spec requires jq"

  # Check for profile-based tool filtering
  local profile
  profile="$(config_agent_get_raw "$agent_id" '.tools.profile' 2>/dev/null)"
  if is_jq_empty "$profile"; then
    profile=""
  fi

  # Check for allow/deny lists
  local allow_list
  allow_list="$(config_agent_get_raw "$agent_id" '.tools.allow' 2>/dev/null)"
  if is_jq_empty "$allow_list"; then
    allow_list="[]"
  fi
  local deny_list
  deny_list="$(config_agent_get_raw "$agent_id" '.tools.deny' 2>/dev/null)"
  if is_jq_empty "$deny_list"; then
    deny_list="[]"
  fi

  # Legacy: check for flat tools array (backward compat)
  local enabled_tools
  enabled_tools="$(config_agent_get "$agent_id" "tools" "")"
  if [[ -n "$enabled_tools" && "$enabled_tools" != "null" ]]; then
    # Check if it's a JSON array (flat list) vs object (new format with profile/allow/deny)
    local tools_type
    tools_type="$(printf '%s' "$enabled_tools" | jq -r 'type' 2>/dev/null)"
    if [[ "$tools_type" == "array" ]]; then
      local all_specs
      all_specs="$(tools_build_spec "$profile")"
      printf '%s' "$all_specs" | jq --argjson enabled "$enabled_tools" \
        '[.[] | select(.name as $n | $enabled | index($n))]'
      return
    fi
  fi

  # Build spec with profile applied first
  local base_spec
  if [[ -n "$profile" ]]; then
    base_spec="$(tools_build_spec "$profile")"
  else
    base_spec="$(tools_build_spec)"
  fi

  # Apply allow/deny on top of profile
  if [[ "$allow_list" != "[]" || "$deny_list" != "[]" ]]; then
    local filtered="$base_spec"
    # If allow_list is set, restrict to those tools
    if [[ "$allow_list" != "[]" ]]; then
      filtered="$(printf '%s' "$filtered" | jq --argjson allow "$allow_list" \
        '[.[] | select(.name as $n | $allow | index($n))]')"
    fi
    # Remove denied tools
    if [[ "$deny_list" != "[]" ]]; then
      filtered="$(printf '%s' "$filtered" | jq --argjson deny "$deny_list" \
        '[.[] | select(.name as $n | $deny | index($n) | not)]')"
    fi
    printf '%s' "$filtered"
  else
    printf '%s' "$base_spec"
  fi
}

# ---- Token Estimation ----

agent_estimate_tokens() {
  local session_file="$1"

  if [[ ! -f "$session_file" ]]; then
    printf '0'
    return
  fi

  local char_count
  char_count="$(wc -c < "$session_file" )"
  printf '%d' $((char_count / 4))
}

agent_should_memory_flush() {
  local session_file="$1"
  local context_window="${2:-200000}"

  local estimated_tokens
  estimated_tokens="$(agent_estimate_tokens "$session_file")"
  local threshold=$((context_window - BASHCLAW_RESERVE_TOKENS_FLOOR - BASHCLAW_SOFT_THRESHOLD_TOKENS))

  if (( estimated_tokens < threshold )); then
    return 1
  fi

  local compaction_count
  compaction_count="$(session_meta_get "$session_file" "compactionCount" "0")"
  local flush_compaction_count
  flush_compaction_count="$(session_meta_get "$session_file" "memoryFlushCompactionCount" "-1")"

  if [[ "$flush_compaction_count" == "$compaction_count" ]]; then
    return 1
  fi

  return 0
}

agent_run_memory_flush() {
  local agent_id="$1"
  local session_file="$2"

  local today
  today="$(date '+%Y-%m-%d')"
  local flush_prompt="Pre-compaction memory flush. Store durable memories now (use memory/${today}.md). If nothing to store, reply with ${BASHCLAW_SILENT_REPLY_TOKEN}."
  local flush_system="Pre-compaction memory flush turn. The session is near auto-compaction; capture durable memories to disk."

  log_info "Running memory flush for agent=$agent_id"

  local compaction_count
  compaction_count="$(session_meta_get "$session_file" "compactionCount" "0")"
  session_meta_update "$session_file" "memoryFlushCompactionCount" "$compaction_count"

  session_append "$session_file" "user" "$flush_prompt"

  local model max_tokens
  model="$(agent_resolve_model "$agent_id")"
  max_tokens="$(_model_max_tokens "$model")"

  local max_history
  max_history="$(config_get '.session.maxHistory' '200')"
  local messages
  messages="$(agent_build_messages "$session_file" "" "$max_history")"
  local tools_json
  tools_json="$(agent_build_tools_spec "$agent_id")"

  local response
  response="$(agent_call_api "$model" "$flush_system" "$messages" "$max_tokens" "$AGENT_DEFAULT_TEMPERATURE" "$tools_json" 2>/dev/null)" || true

  local text_content
  text_content="$(printf '%s' "$response" | jq -r '
    [.content[]? | select(.type == "text") | .text] | join("")
  ' 2>/dev/null)"

  if [[ -n "$text_content" && "$text_content" != "$BASHCLAW_SILENT_REPLY_TOKEN" ]]; then
    session_append "$session_file" "assistant" "$text_content"
  fi

  _agent_extract_and_track_usage "$response" "$agent_id" "$model" "$session_file"
}

# ---- Usage Tracking ----

_agent_extract_and_track_usage() {
  local response="$1"
  local agent_id="$2"
  local model="$3"
  local session_file="$4"

  local input_tokens output_tokens
  local usage_parsed
  usage_parsed="$(printf '%s' "$response" | jq -r '
    [
      (.usage.input_tokens // .usage.prompt_tokens // 0 | tostring),
      (.usage.output_tokens // .usage.completion_tokens // 0 | tostring)
    ] | join("\n")
  ' 2>/dev/null)"
  {
    IFS= read -r input_tokens
    IFS= read -r output_tokens
  } <<< "$usage_parsed"

  input_tokens="${input_tokens:-0}"
  output_tokens="${output_tokens:-0}"

  if [[ "$input_tokens" == "null" ]]; then input_tokens=0; fi
  if [[ "$output_tokens" == "null" ]]; then output_tokens=0; fi

  agent_track_usage "$agent_id" "$model" "$input_tokens" "$output_tokens"

  if [[ -n "$session_file" ]]; then
    local prev_total
    prev_total="$(session_meta_get "$session_file" "totalTokens" "0")"
    local new_total=$((prev_total + input_tokens + output_tokens))
    session_meta_update "$session_file" "totalTokens" "$new_total"
  fi
}

agent_track_usage() {
  local agent_id="$1"
  local model="$2"
  local input_tokens="${3:-0}"
  local output_tokens="${4:-0}"

  require_command jq "agent_track_usage requires jq"

  local usage_dir="${BASHCLAW_STATE_DIR:?}/usage"
  ensure_dir "$usage_dir"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local line
  line="$(jq -nc \
    --arg aid "$agent_id" \
    --arg m "$model" \
    --argjson it "$input_tokens" \
    --argjson ot "$output_tokens" \
    --arg ts "$now" \
    '{agent_id: $aid, model: $m, input_tokens: $it, output_tokens: $ot, timestamp: $ts}')"

  printf '%s\n' "$line" >> "${usage_dir}/usage.jsonl"
}

# ---- Main Agent Loop ----

agent_run() {
  local agent_id="${1:-main}"
  local user_message="$2"
  local channel="${3:-default}"
  local sender="${4:-}"
  local is_subagent="${5:-false}"

  if [[ -z "$user_message" ]]; then
    log_error "agent_run: message is required"
    printf '{"error": "message is required"}'
    return 1
  fi

  require_command jq "agent_run requires jq"
  require_command curl "agent_run requires curl"

  local model
  model="$(agent_resolve_model "$agent_id")"
  local provider
  provider="$(agent_resolve_provider "$model")"
  log_info "Agent run: agent=$agent_id model=$model provider=$provider"

  local max_tokens
  max_tokens="$(_model_max_tokens "$model")"

  local context_window
  context_window="$(_model_context_window "$model")"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  session_check_idle_reset "$sess_file" || true

  session_meta_load "$sess_file" >/dev/null 2>&1

  # session_start hook for new sessions
  if [[ ! -f "$sess_file" || "$(wc -l < "$sess_file" 2>/dev/null )" == "0" ]]; then
    if declare -f hooks_run &>/dev/null; then
      hooks_run "session_start" "$(jq -nc --arg aid "$agent_id" --arg ch "$channel" \
        '{agent_id: $aid, channel: $ch, engine: "builtin"}' 2>/dev/null)" 2>/dev/null || true
    fi
  fi

  if [[ "$is_subagent" != "true" ]] && agent_should_memory_flush "$sess_file" "$context_window"; then
    agent_run_memory_flush "$agent_id" "$sess_file"
  fi

  session_append "$sess_file" "user" "$user_message"

  local system_prompt
  system_prompt="$(agent_build_system_prompt "$agent_id" "$is_subagent" "$channel")"

  local tools_json
  tools_json="$(agent_build_tools_spec "$agent_id")"

  local iteration=0
  local final_text=""
  local compaction_retries=0
  local current_model="$model"

  local max_turns
  max_turns="$(config_agent_get "$agent_id" "maxTurns" "$AGENT_MAX_TOOL_ITERATIONS")"

  while [ "$iteration" -lt "$max_turns" ]; do
    iteration=$((iteration + 1))

    # Auto-compaction check before building messages
    if session_check_compaction "$sess_file" "$agent_id"; then
      local compaction_mode
      compaction_mode="$(config_agent_get_raw "$agent_id" '.compaction.mode' 2>/dev/null)"
      if is_jq_empty "$compaction_mode"; then
        compaction_mode="summary"
      fi
      log_info "Auto-compaction triggered for agent=$agent_id mode=$compaction_mode"
      if [[ "$compaction_mode" == "truncate" ]]; then
        session_compact "$sess_file" "$current_model" "" "truncate" || true
      else
        session_compact "$sess_file" "$current_model" "" "summary" || true
      fi
    fi

    local max_history
    max_history="$(config_get '.session.maxHistory' '200')"
    local messages
    messages="$(agent_build_messages "$sess_file" "" "$max_history")"

    local response
    local api_call_failed="false"
    response="$(agent_call_api "$current_model" "$system_prompt" "$messages" "$max_tokens" "$AGENT_DEFAULT_TEMPERATURE" "$tools_json")" || api_call_failed="true"

    if [[ "$api_call_failed" == "true" ]] && session_detect_overflow "$response"; then
      log_warn "Context overflow detected (compaction_retries=$compaction_retries)"

      if (( compaction_retries == 0 )); then
        local reduced_history=$((max_history / 2))
        if (( reduced_history < 10 )); then
          reduced_history=10
        fi
        session_prune "$sess_file" "$reduced_history"
        compaction_retries=$((compaction_retries + 1))
        iteration=$((iteration - 1))
        continue
      fi

      if (( compaction_retries <= BASHCLAW_MAX_COMPACTION_RETRIES )); then
        log_info "Auto-compaction attempt $compaction_retries"
        session_compact "$sess_file" "$current_model" "" || true
        compaction_retries=$((compaction_retries + 1))
        iteration=$((iteration - 1))
        continue
      fi

      local fallback
      fallback="$(agent_resolve_fallback_model "$current_model")"
      if [[ -n "$fallback" ]]; then
        log_info "Falling back from $current_model to $fallback"
        current_model="$fallback"
        max_tokens="$(_model_max_tokens "$current_model")"
        compaction_retries=0
        iteration=$((iteration - 1))
        continue
      fi

      log_warn "All degradation levels exhausted, resetting session"
      session_clear "$sess_file"
      session_append "$sess_file" "user" "$user_message"
      compaction_retries=0
      iteration=$((iteration - 1))
      continue
    fi

    if [[ "$api_call_failed" == "true" ]]; then
      log_error "API call failed on iteration $iteration"
      printf '%s' "$response"
      return 1
    fi

    local api_error
    api_error="$(printf '%s' "$response" | jq -r '.error // empty' 2>/dev/null)"
    if [[ -n "$api_error" && "$api_error" != "null" ]]; then
      log_error "API error: $api_error"
      printf '%s' "$response"
      return 1
    fi

    _agent_extract_and_track_usage "$response" "$agent_id" "$current_model" "$sess_file"

    local stop_reason
    stop_reason="$(printf '%s' "$response" | jq -r '.stop_reason // "end_turn"')"

    local text_content
    text_content="$(printf '%s' "$response" | jq -r '
      [.content[]? | select(.type == "text") | .text] | join("")
    ')"

    if [[ -n "$text_content" ]]; then
      final_text="$text_content"
    fi

    if [[ "$stop_reason" == "tool_use" ]]; then
      log_debug "Tool use requested on iteration $iteration"

      if [[ -n "$text_content" ]]; then
        session_append "$sess_file" "assistant" "$text_content"
      fi

      local tool_calls
      tool_calls="$(printf '%s' "$response" | jq -c '[.content[]? | select(.type == "tool_use")]')"
      local num_calls
      num_calls="$(printf '%s' "$tool_calls" | jq 'length')"

      local i=0
      while [ "$i" -lt "$num_calls" ]; do
        local tool_call
        tool_call="$(printf '%s' "$tool_calls" | jq -c ".[$i]")"
        local tool_name tool_id tool_input
        tool_name="$(printf '%s' "$tool_call" | jq -r '.name')"
        tool_id="$(printf '%s' "$tool_call" | jq -r '.id')"
        tool_input="$(printf '%s' "$tool_call" | jq -c '.input')"

        log_info "Tool call: $tool_name (id=$tool_id)"

        session_append_tool_call "$sess_file" "$tool_name" "$tool_input" "$tool_id"

        local tool_result
        tool_result="$(tool_execute "$tool_name" "$tool_input" 2>&1)" || true

        log_debug "Tool result ($tool_name): ${tool_result:0:200}"

        local is_error="false"
        if printf '%s' "$tool_result" | jq -e '.error' &>/dev/null; then
          is_error="true"
        fi

        session_append_tool_result "$sess_file" "$tool_id" "$tool_result" "$is_error"

        # Fire tool_result_persist hook event
        if declare -f hooks_run &>/dev/null; then
          hooks_run "tool_result_persist" "$(jq -nc --arg tn "$tool_name" --arg tid "$tool_id" --arg err "$is_error" '{tool_name: $tn, tool_id: $tid, is_error: ($err == "true")}')" 2>/dev/null || true
        fi

        i=$((i + 1))
      done

      # Append reflection nudge after tool results if configured
      local reflection_prompt
      reflection_prompt="$(config_get '.agents.defaults.reflectionPrompt' '')"
      if [[ -z "$reflection_prompt" ]]; then
        reflection_prompt="Analyze the tool result. If the task is complete, provide a final response. If not, decide the next action."
      fi
      # Allow disabling reflection via config (set to "false")
      local reflection_disabled
      reflection_disabled="$(config_get_raw '.agents.defaults.reflectionPrompt' 2>/dev/null)"
      if [[ "$reflection_disabled" != "false" ]]; then
        session_append "$sess_file" "user" "$reflection_prompt"
      fi

      continue
    fi

    if [[ -n "$text_content" ]]; then
      session_append "$sess_file" "assistant" "$text_content"
    fi

    break
  done

  if [ "$iteration" -ge "$max_turns" ]; then
    log_warn "Agent reached max tool iterations ($max_turns)"
  fi

  local max_history_val
  max_history_val="$(config_get '.session.maxHistory' '200')"
  session_prune "$sess_file" "$max_history_val"

  printf '%s' "$final_text"
}

# ---- Agent-to-Agent Messaging ----

tool_agent_message() {
  local input="$1"
  require_command jq "tool_agent_message requires jq"

  local target_agent message_text from_agent
  target_agent="$(printf '%s' "$input" | jq -r '.target_agent // empty')"
  message_text="$(printf '%s' "$input" | jq -r '.message // empty')"
  from_agent="$(printf '%s' "$input" | jq -r '.from_agent // "main"')"

  if [[ -z "$target_agent" ]]; then
    printf '{"error": "target_agent is required"}'
    return 1
  fi

  if [[ -z "$message_text" ]]; then
    printf '{"error": "message is required"}'
    return 1
  fi

  log_info "Agent message: from=$from_agent to=$target_agent (subagent)"

  local response
  response="$(agent_run "$target_agent" "$message_text" "agent" "$from_agent" "true" 2>&1)" || true

  jq -nc \
    --arg from "$from_agent" \
    --arg to "$target_agent" \
    --arg resp "$response" \
    '{from_agent: $from, target_agent: $to, response: $resp}'
}
