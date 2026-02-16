#!/usr/bin/env bash
# Message routing for bashclaw
# Compatible with bash 3.2+ (no associative arrays)

# ---- Channel-specific message length limits ----

_channel_max_length() {
  case "$1" in
    telegram)  echo 4096 ;;
    discord)   echo 2000 ;;
    slack)     echo 40000 ;;
    whatsapp)  echo 4096 ;;
    imessage)  echo 20000 ;;
    line)      echo 5000 ;;
    signal)    echo 4096 ;;
    feishu)    echo 30000 ;;
    web)       echo 100000 ;;
    *)         echo 4096 ;;
  esac
}

# ---- Seven-Level Priority Route Resolution (Gap 7.1) ----

routing_resolve_agent() {
  local channel="${1:-default}"
  local sender="${2:-}"
  local guild_id="${3:-}"
  local team_id="${4:-}"
  local account_id="${5:-}"
  local parent_peer="${6:-}"

  local bindings
  bindings="$(config_get_raw '.bindings // []')"

  if [[ "$bindings" != "null" && "$bindings" != "[]" ]]; then
    # Level 1: exact peer binding
    local matched
    matched="$(printf '%s' "$bindings" | jq -r \
      --arg ch "$channel" --arg sender "$sender" '
      [.[] | select(.match.channel == $ch and .match.peer.id == $sender)] |
      .[0].agentId // empty
    ' 2>/dev/null)"
    if [[ -n "$matched" ]]; then
      printf '%s' "$matched"
      return
    fi

    # Level 2: parent peer binding (thread inheritance)
    if [[ -n "$parent_peer" ]]; then
      matched="$(printf '%s' "$bindings" | jq -r \
        --arg ch "$channel" --arg pp "$parent_peer" '
        [.[] | select(.match.channel == $ch and .match.peer.id == $pp)] |
        .[0].agentId // empty
      ' 2>/dev/null)"
      if [[ -n "$matched" ]]; then
        printf '%s' "$matched"
        return
      fi
    fi

    # Level 3: guild binding
    if [[ -n "$guild_id" ]]; then
      matched="$(printf '%s' "$bindings" | jq -r \
        --arg g "$guild_id" '
        [.[] | select(.match.guild == $g)] |
        .[0].agentId // empty
      ' 2>/dev/null)"
      if [[ -n "$matched" ]]; then
        printf '%s' "$matched"
        return
      fi
    fi

    # Level 4: team binding
    if [[ -n "$team_id" ]]; then
      matched="$(printf '%s' "$bindings" | jq -r \
        --arg t "$team_id" '
        [.[] | select(.match.team == $t)] |
        .[0].agentId // empty
      ' 2>/dev/null)"
      if [[ -n "$matched" ]]; then
        printf '%s' "$matched"
        return
      fi
    fi

    # Level 5: account binding (no peer/guild/team)
    if [[ -n "$account_id" ]]; then
      matched="$(printf '%s' "$bindings" | jq -r \
        --arg aid "$account_id" '
        [.[] | select(.match.accountId == $aid and (.match.peer == null) and (.match.guild == null) and (.match.team == null))] |
        .[0].agentId // empty
      ' 2>/dev/null)"
      if [[ -n "$matched" ]]; then
        printf '%s' "$matched"
        return
      fi
    fi

    # Level 6: channel binding with wildcard accountId
    matched="$(printf '%s' "$bindings" | jq -r \
      --arg ch "$channel" '
      [.[] | select(.match.channel == $ch and (.match.peer == null) and (.match.guild == null) and (.match.team == null) and (.match.accountId == null))] |
      .[0].agentId // empty
    ' 2>/dev/null)"
    if [[ -n "$matched" ]]; then
      printf '%s' "$matched"
      return
    fi
  fi

  # Level 6 fallback: channel config agentId
  local channel_agent
  channel_agent="$(config_channel_get "$channel" "agentId" "")"
  if [[ -n "$channel_agent" ]]; then
    printf '%s' "$channel_agent"
    return
  fi

  # Level 7: default agent
  local default_agent
  default_agent="$(config_get '.agents.defaultId' 'main')"
  printf '%s' "$default_agent"
}

# ---- DM / Group Policy Resolution (Gap 9.2) ----

routing_resolve_dm_policy() {
  local channel="$1"
  local sender="$2"

  local policy
  policy="$(config_get_raw ".channels.${channel}.dmPolicy // null" 2>/dev/null)"
  if [[ "$policy" == "null" || -z "$policy" ]]; then
    printf '{"policy":"open","allowFrom":[]}'
    return
  fi

  printf '%s' "$policy"
}

routing_resolve_group_policy() {
  local channel="$1"

  local policy
  policy="$(config_get_raw ".channels.${channel}.groupPolicy // null" 2>/dev/null)"
  if [[ "$policy" == "null" || -z "$policy" ]]; then
    printf '{"policy":"open"}'
    return
  fi

  printf '%s' "$policy"
}

# ---- Allowlist Check ----

routing_check_allowlist() {
  local channel="$1"
  local sender="$2"
  local is_dm="${3:-true}"

  # Check DM/Group policy first
  if [[ "$is_dm" == "true" ]]; then
    local dm_policy_json
    dm_policy_json="$(routing_resolve_dm_policy "$channel" "$sender")"
    local dm_policy_mode
    dm_policy_mode="$(printf '%s' "$dm_policy_json" | jq -r '.policy // "open"' 2>/dev/null)"

    case "$dm_policy_mode" in
      open)
        return 0
        ;;
      pairing)
        local pair_dir="${BASHCLAW_STATE_DIR:?}/pairing/verified"
        local safe_key
        safe_key="$(sanitize_key "${channel}_${sender}")"
        if [[ -f "${pair_dir}/${safe_key}" ]]; then
          return 0
        fi
        log_warn "Sender not paired: channel=$channel sender=$sender"
        return 1
        ;;
      allowlist)
        # Fall through to allowlist check below
        ;;
    esac
  fi

  local allowlist
  allowlist="$(config_get_raw ".channels.${channel}.allowFrom // null" 2>/dev/null)"

  # Also check dmPolicy.allowFrom if present
  if [[ "$allowlist" == "null" || -z "$allowlist" ]]; then
    allowlist="$(config_get_raw ".channels.${channel}.dmPolicy.allowFrom // null" 2>/dev/null)"
  fi

  if [[ "$allowlist" == "null" || -z "$allowlist" ]]; then
    return 0
  fi

  local is_allowed
  is_allowed="$(printf '%s' "$allowlist" | jq --arg s "$sender" \
    'if type == "array" then any(. == $s or . == ($s | tonumber? // "")) else true end' 2>/dev/null)"

  if [[ "$is_allowed" == "true" ]]; then
    return 0
  fi

  log_warn "Sender not in allowlist: channel=$channel sender=$sender"
  return 1
}

# ---- Mention Gating ----

routing_check_mention_gating() {
  local channel="$1"
  local message="$2"
  local is_group="${3:-false}"

  if [[ "$is_group" != "true" ]]; then
    return 0
  fi

  # Check group policy
  local group_policy_json
  group_policy_json="$(routing_resolve_group_policy "$channel")"
  local group_mode
  group_mode="$(printf '%s' "$group_policy_json" | jq -r '.policy // "open"' 2>/dev/null)"

  case "$group_mode" in
    disabled)
      log_debug "Group messages disabled for channel=$channel"
      return 1
      ;;
    mention-only)
      # Must mention the bot
      ;;
    open)
      local require_mention
      require_mention="$(config_channel_get "$channel" "requireMention" "true")"
      if [[ "$require_mention" != "true" ]]; then
        return 0
      fi
      ;;
  esac

  local bot_name
  bot_name="$(config_channel_get "$channel" "botName" "")"
  if [[ -z "$bot_name" ]]; then
    bot_name="$(config_get '.agents.defaults.name' 'bashclaw')"
  fi

  local lower_msg lower_name
  lower_msg="$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')"
  lower_name="$(printf '%s' "$bot_name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower_msg" == *"@${lower_name}"* ]]; then
    return 0
  fi

  if [[ "$lower_msg" == *"${lower_name}"* ]]; then
    return 0
  fi

  log_debug "Mention gating: bot=$bot_name not mentioned in group message"
  return 1
}

# ---- Reply Formatting ----

routing_format_reply() {
  local channel="$1"
  local text="$2"

  local max_len
  max_len="$(_channel_max_length "$channel")"

  if [ "${#text}" -le "$max_len" ]; then
    printf '%s' "$text"
    return
  fi

  local truncated="${text:0:$((max_len - 20))}

[message truncated]"
  printf '%s' "$truncated"
}

# ---- Long Message Splitting ----

routing_split_long_message() {
  local text="$1"
  local max_len="${2:-4096}"

  if [ "${#text}" -le "$max_len" ]; then
    printf '%s\n' "$text"
    return
  fi

  local remaining="$text"

  while [ "${#remaining}" -gt 0 ]; do
    if [ "${#remaining}" -le "$max_len" ]; then
      printf '%s\n' "$remaining"
      break
    fi

    local chunk="${remaining:0:$max_len}"
    local split_pos=-1

    # Try to split at a paragraph boundary (double newline)
    local last_para
    last_para="$(printf '%s' "$chunk" | grep -bn '^$' | tail -1 | cut -d: -f1)"
    if [[ -n "$last_para" && "$last_para" -gt 0 ]]; then
      local tmp_chunk="$chunk"
      local found_pos=""
      local search_from=0
      while true; do
        local idx="${tmp_chunk%%

*}"
        if [[ "$idx" == "$tmp_chunk" ]]; then
          break
        fi
        local idx_len="${#idx}"
        search_from=$((search_from + idx_len))
        found_pos="$search_from"
        tmp_chunk="${tmp_chunk:$((idx_len + 2))}"
        search_from=$((search_from + 2))
      done
      if [[ -n "$found_pos" ]]; then
        split_pos="$found_pos"
      fi
    fi

    # Fall back to last newline
    if [ "$split_pos" -lt 0 ] 2>/dev/null; then
      local nl_chunk="${chunk%
*}"
      if [[ "$nl_chunk" != "$chunk" && -n "$nl_chunk" ]]; then
        split_pos="${#nl_chunk}"
      fi
    fi

    # Fall back to last space
    if [ "$split_pos" -lt 0 ] 2>/dev/null; then
      local sp_chunk="${chunk% *}"
      if [[ "$sp_chunk" != "$chunk" && -n "$sp_chunk" ]]; then
        split_pos="${#sp_chunk}"
      fi
    fi

    # Hard cut if no boundary found
    if [ "$split_pos" -lt 0 ] 2>/dev/null; then
      split_pos=$max_len
    fi

    printf '%s\n' "${remaining:0:$split_pos}"
    remaining="${remaining:$split_pos}"
    # Trim leading whitespace from remaining
    remaining="${remaining#"${remaining%%[![:space:]]*}"}"
  done
}

# ---- Delivery Plan (Gap 7.3) ----

routing_build_delivery_plan() {
  local channel="${1:?channel required}"
  local sender="${2:-}"
  local thread_id="${3:-}"
  local message_id="${4:-}"
  local account_id="${5:-}"

  require_command jq "routing_build_delivery_plan requires jq"

  jq -nc \
    --arg ch "$channel" \
    --arg to "$sender" \
    --arg tid "$thread_id" \
    --arg mid "$message_id" \
    --arg aid "$account_id" \
    '{channel: $ch, to: $to, threadId: $tid, replyToMessageId: $mid, accountId: $aid}'
}

# ---- Message Debounce (Gap 7.2) ----

routing_debounce() {
  local channel="${1:?channel required}"
  local sender="${2:?sender required}"
  local message="${3:?message required}"
  local debounce_ms="${4:-0}"

  if [[ "$debounce_ms" == "0" || -z "$debounce_ms" ]]; then
    printf '%s' "$message"
    return
  fi

  local debounce_dir="${BASHCLAW_STATE_DIR:?}/debounce"
  ensure_dir "$debounce_dir"

  local safe_key
  safe_key="$(sanitize_key "${channel}_${sender}")"
  local buffer_file="${debounce_dir}/${safe_key}.buf"
  local timer_file="${debounce_dir}/${safe_key}.timer"

  # Append message to buffer
  printf '%s\n' "$message" >> "$buffer_file"

  # Record current timestamp (ms approximation using seconds)
  local now
  now="$(date +%s)"
  printf '%s' "$now" > "$timer_file"

  # Convert ms to seconds (integer division, minimum 1)
  local wait_sec=$(( (debounce_ms + 999) / 1000 ))
  if [[ "$wait_sec" -lt 1 ]]; then
    wait_sec=1
  fi

  # Wait and check if another message arrived
  sleep "$wait_sec"

  local last_ts
  last_ts="$(cat "$timer_file" 2>/dev/null || echo 0)"
  if [[ "$last_ts" != "$now" ]]; then
    # Another message arrived, this call is superseded
    return 1
  fi

  # This is the final call: collect and merge all buffered messages
  if [[ -f "$buffer_file" ]]; then
    cat "$buffer_file"
    rm -f "$buffer_file" "$timer_file"
  fi
}

# ---- Async Dispatch (Gap 7.4) ----

routing_dispatch_async() {
  local channel="${1:-default}"
  local sender="${2:-}"
  local message="$3"
  local is_group="${4:-false}"

  require_command jq "routing_dispatch_async requires jq"

  # Generate run_id
  local run_id
  if command -v uuidgen >/dev/null 2>&1; then
    run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    run_id="run_$(date +%s)_$$_${RANDOM}"
  fi

  local accepted_at
  accepted_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Check dedup
  if command -v dedup_check >/dev/null 2>&1; then
    local dedup_key="${channel}:${sender}:$(printf '%s' "$message" | head -c 100)"
    if dedup_check "$dedup_key" 60 2>/dev/null; then
      log_info "Duplicate message suppressed: channel=$channel sender=$sender"
      jq -nc --arg rid "$run_id" --arg at "$accepted_at" \
        '{status: "duplicate", run_id: $rid, accepted_at: $at}'
      return 0
    fi
    dedup_record "$dedup_key" "$run_id" 2>/dev/null || true
  fi

  # Store the request for background processing
  local queue_dir="${BASHCLAW_STATE_DIR:?}/async_queue"
  ensure_dir "$queue_dir"
  local req_file="${queue_dir}/${run_id}.json"

  jq -nc \
    --arg rid "$run_id" \
    --arg ch "$channel" \
    --arg snd "$sender" \
    --arg msg "$message" \
    --arg grp "$is_group" \
    --arg at "$accepted_at" \
    '{run_id: $rid, channel: $ch, sender: $snd, message: $msg, is_group: $grp, accepted_at: $at, status: "pending"}' \
    > "$req_file"

  # Spawn background processing
  (
    routing_dispatch "$channel" "$sender" "$message" "$is_group" > "${queue_dir}/${run_id}.result" 2>&1
    # Update status
    if [[ -f "$req_file" ]]; then
      local result_content=""
      if [[ -f "${queue_dir}/${run_id}.result" ]]; then
        result_content="$(cat "${queue_dir}/${run_id}.result")"
      fi
      jq -nc \
        --arg rid "$run_id" \
        --arg st "completed" \
        --arg res "$result_content" \
        '{run_id: $rid, status: $st, result: $res}' \
        > "$req_file"
    fi
  ) &

  # Return accepted response immediately
  jq -nc --arg rid "$run_id" --arg at "$accepted_at" \
    '{status: "accepted", run_id: $rid, accepted_at: $at}'
}

# ---- Channel Outbound Delivery (Gap 15.1) ----

routing_deliver() {
  local delivery_plan="$1"
  local payload="$2"

  require_command jq "routing_deliver requires jq"

  local channel
  channel="$(printf '%s' "$delivery_plan" | jq -r '.channel // "default"')"
  local to
  to="$(printf '%s' "$delivery_plan" | jq -r '.to // empty')"
  local thread_id
  thread_id="$(printf '%s' "$delivery_plan" | jq -r '.threadId // empty')"

  # Get outbound config for channel
  local text_chunk_limit
  text_chunk_limit="$(config_get_raw ".channels.${channel}.outbound.textChunkLimit // 4096" 2>/dev/null)"
  if [[ "$text_chunk_limit" == "null" ]]; then
    text_chunk_limit=4096
  fi

  # Split payload if needed
  local chunks
  chunks="$(routing_split_long_message "$payload" "$text_chunk_limit")"

  # Format each chunk for the channel
  local formatted_chunks=""
  while IFS= read -r chunk; do
    [[ -z "$chunk" ]] && continue
    local formatted
    formatted="$(routing_format_reply "$channel" "$chunk")"
    if [[ -n "$formatted_chunks" ]]; then
      formatted_chunks="${formatted_chunks}
---CHUNK_SEPARATOR---
${formatted}"
    else
      formatted_chunks="$formatted"
    fi
  done <<EOF
$chunks
EOF

  # Build delivery result
  jq -nc \
    --arg ch "$channel" \
    --arg to "$to" \
    --arg tid "$thread_id" \
    --arg payload "$formatted_chunks" \
    '{channel: $ch, to: $to, threadId: $tid, payload: $payload, delivered: true}'
}

# ---- Main Dispatch Pipeline ----

routing_dispatch() {
  local channel="${1:-default}"
  local sender="${2:-}"
  local message="$3"
  local is_group="${4:-false}"
  local thread_id="${5:-}"
  local message_id="${6:-}"
  local account_id="${7:-}"

  if [[ -z "$message" ]]; then
    log_warn "routing_dispatch: empty message"
    printf ''
    return 1
  fi

  # Security: audit log incoming message
  security_audit_log "message_received" "channel=$channel sender=$sender"

  # Security: rate limit check
  if ! security_rate_limit "$sender" 2>/dev/null; then
    log_info "Message rate-limited: sender=$sender"
    printf ''
    return 1
  fi

  if ! routing_check_allowlist "$channel" "$sender"; then
    log_info "Message blocked by allowlist: channel=$channel sender=$sender"
    printf ''
    return 1
  fi

  if ! routing_check_mention_gating "$channel" "$message" "$is_group"; then
    log_debug "Message skipped (no mention in group): channel=$channel"
    printf ''
    return 0
  fi

  # Debounce check
  local debounce_ms
  debounce_ms="$(config_channel_get "$channel" "debounceMs" "0")"
  if [[ "$debounce_ms" != "0" && -n "$debounce_ms" ]]; then
    local debounced_msg
    debounced_msg="$(routing_debounce "$channel" "$sender" "$message" "$debounce_ms")" || {
      log_debug "Message debounced (superseded): channel=$channel sender=$sender"
      printf ''
      return 0
    }
    if [[ -n "$debounced_msg" ]]; then
      message="$debounced_msg"
    fi
  fi

  # Auto-reply check before agent dispatch
  local auto_response
  auto_response="$(autoreply_check "$message" "$channel" 2>/dev/null)" || true
  if [[ -n "$auto_response" ]]; then
    log_info "Auto-reply matched: channel=$channel sender=$sender"
    security_audit_log "autoreply_matched" "channel=$channel sender=$sender"
    local formatted
    formatted="$(routing_format_reply "$channel" "$auto_response")"
    printf '%s' "$formatted"
    return 0
  fi

  local agent_id
  agent_id="$(routing_resolve_agent "$channel" "$sender" "" "" "$account_id")"
  log_info "Routing: channel=$channel sender=$sender agent=$agent_id"

  # Build delivery plan for reply routing
  local delivery_plan
  delivery_plan="$(routing_build_delivery_plan "$channel" "$sender" "$thread_id" "$message_id" "$account_id")"

  # Run pre_message hooks
  local hook_input
  hook_input="$(jq -nc \
    --arg ch "$channel" \
    --arg snd "$sender" \
    --arg msg "$message" \
    --arg aid "$agent_id" \
    --arg tid "$thread_id" \
    '{channel: $ch, sender: $snd, message: $msg, agent_id: $aid, thread_id: $tid}' 2>/dev/null)"

  local hooked_input
  hooked_input="$(hooks_run "pre_message" "$hook_input" 2>/dev/null)" || true
  if [[ -n "$hooked_input" ]]; then
    local hooked_msg
    hooked_msg="$(printf '%s' "$hooked_input" | jq -r '.message // empty' 2>/dev/null)"
    if [[ -n "$hooked_msg" ]]; then
      message="$hooked_msg"
    fi
  fi

  local response
  response="$(agent_run "$agent_id" "$message" "$channel" "$sender")"

  if [[ -z "$response" ]]; then
    log_warn "Agent returned empty response"
    printf ''
    return 1
  fi

  # Run post_message hooks
  local post_hook_input
  post_hook_input="$(jq -nc \
    --arg ch "$channel" \
    --arg snd "$sender" \
    --arg msg "$message" \
    --arg resp "$response" \
    --arg aid "$agent_id" \
    '{channel: $ch, sender: $snd, message: $msg, response: $resp, agent_id: $aid}' 2>/dev/null)"
  hooks_run "post_message" "$post_hook_input" >/dev/null 2>&1 || true

  # Security: audit log response
  security_audit_log "message_responded" "channel=$channel sender=$sender agent=$agent_id"

  local formatted
  formatted="$(routing_format_reply "$channel" "$response")"

  # Deliver via channel outbound if available
  routing_deliver "$delivery_plan" "$formatted" >/dev/null 2>&1 || true

  printf '%s' "$formatted"
}
