#!/usr/bin/env bash
# JSONL session management for bashclaw

session_dir() {
  local base="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/sessions"
  ensure_dir "$base"
  printf '%s' "$base"
}

# Resolve cross-channel identity via identityLinks config.
# If the sender matches a linked peer, return the canonical identity.
session_resolve_identity() {
  local channel="$1"
  local sender="$2"

  if [[ -z "$sender" ]]; then
    printf '%s' "$sender"
    return
  fi

  require_command jq "session_resolve_identity requires jq"

  local links
  links="$(config_get_raw '.identityLinks // []' 2>/dev/null)"
  if [[ -z "$links" || "$links" == "null" || "$links" == "[]" ]]; then
    printf '%s' "$sender"
    return
  fi

  local qualified="${channel}:${sender}"
  local canonical
  canonical="$(printf '%s' "$links" | jq -r \
    --arg s "$sender" --arg q "$qualified" '
    [.[] | select(
      (.peers // []) | any(. == $s or . == $q)
    ) | .canonical] | .[0] // empty
  ' 2>/dev/null)"

  if [[ -n "$canonical" ]]; then
    printf '%s' "$canonical"
  else
    printf '%s' "$sender"
  fi
}

session_file() {
  local agent_id="$1"
  local channel="${2:-default}"
  local sender="${3:-}"
  local account_id="${4:-}"

  # Resolve identity links before constructing path
  sender="$(session_resolve_identity "$channel" "$sender")"

  local scope
  scope="$(config_get '.session.dmScope' '')"
  if [[ -z "$scope" ]]; then
    scope="$(config_get '.session.scope' 'per-sender')"
  fi
  local dir
  dir="$(session_dir)"

  case "$scope" in
    per-sender|per-channel-peer)
      if [[ -n "$sender" ]]; then
        ensure_dir "${dir}/${agent_id}/${channel}"
        printf '%s/%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel" "$sender"
      else
        ensure_dir "${dir}/${agent_id}"
        printf '%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel"
      fi
      ;;
    per-peer)
      if [[ -n "$sender" ]]; then
        ensure_dir "${dir}/${agent_id}/direct"
        printf '%s/%s/direct/%s.jsonl' "$dir" "$agent_id" "$sender"
      else
        ensure_dir "${dir}/${agent_id}"
        printf '%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel"
      fi
      ;;
    per-account-channel-peer)
      local acct="${account_id:-_default}"
      if [[ -n "$sender" ]]; then
        ensure_dir "${dir}/${agent_id}/${channel}/${acct}/direct"
        printf '%s/%s/%s/%s/direct/%s.jsonl' "$dir" "$agent_id" "$channel" "$acct" "$sender"
      else
        ensure_dir "${dir}/${agent_id}/${channel}/${acct}"
        printf '%s/%s/%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel" "$acct" "$channel"
      fi
      ;;
    per-channel)
      ensure_dir "${dir}/${agent_id}"
      printf '%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel"
      ;;
    main|global)
      printf '%s/%s.jsonl' "$dir" "$agent_id"
      ;;
    *)
      ensure_dir "${dir}/${agent_id}/${channel}"
      printf '%s/%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel" "${sender:-_global}"
      ;;
  esac
}

session_key() {
  local agent_id="$1"
  local channel="${2:-default}"
  local sender="${3:-}"
  local session_type="${4:-direct}"

  # Normalize sender
  sender="$(session_resolve_identity "$channel" "$sender")"

  # Structured key format: agent:AGENT_ID:CHANNEL:TYPE:PEER_ID
  if [[ -n "$sender" ]]; then
    printf 'agent:%s:%s:%s:%s' "$agent_id" "$channel" "$session_type" "$sender"
  else
    printf 'agent:%s:%s:%s' "$agent_id" "$channel" "$session_type"
  fi
}

# Ensure a JSONL session header exists as the first line of the file.
# Creates the header if the file is empty or does not exist.
session_ensure_header() {
  local file="$1"

  # If the file exists and is non-empty, check if it already has a header
  if [[ -f "$file" && -s "$file" ]]; then
    local first_line
    first_line="$(head -n 1 "$file")"
    if printf '%s' "$first_line" | grep -q '"type":"session"' 2>/dev/null; then
      return 0
    fi
    # File has content but no header; prepend one
    require_command jq "session_ensure_header requires jq"
    local sid
    sid="$(uuid_generate)"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local header
    header="$(jq -nc \
      --arg sid "$sid" \
      --arg ts "$ts" \
      '{type:"session",version:"1",id:$sid,timestamp:$ts,engine:"bashclaw"}')"
    local tmp
    tmp="$(tmpfile "session_header")"
    printf '%s\n' "$header" > "$tmp"
    cat "$file" >> "$tmp"
    mv "$tmp" "$file"
    return 0
  fi

  # File is empty or does not exist; create with header
  require_command jq "session_ensure_header requires jq"
  ensure_dir "$(dirname "$file")"
  local sid
  sid="$(uuid_generate)"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local header
  header="$(jq -nc \
    --arg sid "$sid" \
    --arg ts "$ts" \
    '{type:"session",version:"1",id:$sid,timestamp:$ts,engine:"bashclaw"}')"
  printf '%s\n' "$header" > "$file"
}

_session_lock() {
  local lockfile="${1}.lock"
  local attempts=0
  while ! mkdir "$lockfile" 2>/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts > 50 )); then
      rm -rf "$lockfile" 2>/dev/null || true
      mkdir "$lockfile" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
}

_session_unlock() {
  local lockfile="${1}.lock"
  rmdir "$lockfile" 2>/dev/null || true
}

session_append() {
  local file="$1"
  local role="$2"
  local content="$3"

  require_command jq "session_append requires jq"

  _session_lock "$file"

  # Ensure the session header exists before appending
  session_ensure_header "$file"

  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc --arg r "$role" --arg c "$content" --arg t "$ts" \
    '{role: $r, content: $c, ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"

  session_meta_update "$file" "updatedAt" "\"${ts}\""

  _session_unlock "$file"
}

session_append_tool_call() {
  local file="$1"
  local tool_name="$2"
  local tool_input="$3"
  local tool_id="${4:-$(uuid_generate)}"

  require_command jq "session_append_tool_call requires jq"
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc \
    --arg tn "$tool_name" \
    --arg ti "$tool_input" \
    --arg tid "$tool_id" \
    --arg t "$ts" \
    '{role: "assistant", type: "tool_call", tool_name: $tn, tool_input: ($ti | fromjson? // $ti), tool_id: $tid, ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"
}

session_append_tool_result() {
  local file="$1"
  local tool_id="$2"
  local result="$3"
  local is_error="${4:-false}"

  require_command jq "session_append_tool_result requires jq"
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc \
    --arg tid "$tool_id" \
    --arg r "$result" \
    --arg err "$is_error" \
    --arg t "$ts" \
    '{role: "tool", type: "tool_result", tool_id: $tid, content: $r, is_error: ($err == "true"), ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"
}

session_load() {
  local file="$1"
  local max_lines="${2:-0}"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_load requires jq"

  # Filter out the session header line (type=="session")
  if (( max_lines > 0 )); then
    tail -n "$max_lines" "$file" | jq -s '[.[] | select(.type != "session")]'
  else
    jq -s '[.[] | select(.type != "session")]' < "$file"
  fi
}

session_load_as_messages() {
  local file="$1"
  local max_lines="${2:-0}"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_load_as_messages requires jq"
  local raw
  if (( max_lines > 0 )); then
    raw="$(tail -n "$max_lines" "$file" | jq -s '[.[] | select(.type != "session")]')"
  else
    raw="$(jq -s '[.[] | select(.type != "session")]' < "$file")"
  fi

  printf '%s' "$raw" | jq '[.[] | {role: .role, content: .content}]'
}

session_clear() {
  local file="$1"
  if [[ -f "$file" ]]; then
    : > "$file"
    log_debug "Session cleared: $file"
  fi
}

session_delete() {
  local file="$1"
  if [[ -f "$file" ]]; then
    rm -f "$file"
    log_debug "Session deleted: $file"
  fi
}

session_prune() {
  local file="$1"
  local keep="${2:-100}"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  local total
  total="$(wc -l < "$file" | tr -d ' ')"
  if (( total <= keep )); then
    return 0
  fi

  local tmp
  tmp="$(tmpfile "session_prune")"
  tail -n "$keep" "$file" > "$tmp"
  mv "$tmp" "$file"
  log_debug "Session pruned to $keep entries: $file"
}

session_list() {
  local base_dir
  base_dir="$(session_dir)"

  if [[ ! -d "$base_dir" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_list requires jq"
  local ndjson=""
  local f
  while IFS= read -r -d '' f; do
    local relative="${f#${base_dir}/}"
    local count
    count="$(wc -l < "$f" | tr -d ' ')"
    ndjson="${ndjson}$(jq -nc --arg p "$relative" --argjson c "$count" \
      '{"path": $p, "count": $c}')"$'\n'
  done < <(find "$base_dir" -name '*.jsonl' -print0 2>/dev/null)

  local result
  if [[ -n "$ndjson" ]]; then
    result="$(printf '%s' "$ndjson" | jq -s '.')"
  else
    result="[]"
  fi
  printf '%s' "$result"
}

session_check_idle_reset() {
  local file="$1"
  local idle_minutes="${2:-}"

  if [[ -z "$idle_minutes" ]]; then
    idle_minutes="$(config_get '.session.idleResetMinutes' '30')"
  fi

  if [[ ! -f "$file" ]] || (( idle_minutes <= 0 )); then
    return 1
  fi

  local last_line
  last_line="$(tail -n 1 "$file")"
  if [[ -z "$last_line" ]]; then
    return 1
  fi

  require_command jq "session_check_idle_reset requires jq"
  local last_ts
  last_ts="$(printf '%s' "$last_line" | jq -r '.ts // 0' 2>/dev/null)"
  if [[ "$last_ts" == "0" || -z "$last_ts" ]]; then
    return 1
  fi

  local now_ms
  now_ms="$(timestamp_ms)"
  local diff_minutes=$(( (now_ms - last_ts) / 60000 ))

  if (( diff_minutes >= idle_minutes )); then
    session_clear "$file"
    log_info "Session idle-reset after ${diff_minutes}m: $file"
    # Fire session_end hook event
    if declare -f hooks_run &>/dev/null; then
      hooks_run "session_end" "{\"file\":\"$file\",\"reason\":\"idle_timeout\",\"idle_minutes\":$diff_minutes}" 2>/dev/null || true
    fi
    return 0
  fi
  return 1
}

session_export() {
  local file="$1"
  local format="${2:-json}"

  if [[ ! -f "$file" ]]; then
    log_warn "Session file not found: $file"
    return 1
  fi

  case "$format" in
    json)
      session_load "$file"
      ;;
    text)
      require_command jq "session_export text requires jq"
      jq -r 'select(.type != "session") | "\(.role // "unknown"): \(.content // "")"' < "$file"
      ;;
    *)
      log_error "Unknown export format: $format (use json or text)"
      return 1
      ;;
  esac
}

session_count() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '0'
    return 0
  fi
  local total
  total="$(wc -l < "$file" | tr -d ' ')"
  # Subtract the header line if present
  if [[ "$total" -gt 0 ]]; then
    local first_line
    first_line="$(head -n 1 "$file")"
    if printf '%s' "$first_line" | grep -q '"type":"session"' 2>/dev/null; then
      total=$((total - 1))
    fi
  fi
  printf '%d' "$total"
}

session_last_role() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf ''
    return 0
  fi
  require_command jq "session_last_role requires jq"
  local last_line
  last_line="$(tail -n 1 "$file")"
  if [[ -z "$last_line" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$last_line" | jq -r '.role // ""' 2>/dev/null
}

# ---- Session Metadata ----

# Return the metadata file path for a session
session_meta_file() {
  local session_file="$1"
  printf '%s' "${session_file%.jsonl}.meta.json"
}

# Load session metadata, initializing if absent
session_meta_load() {
  local session_file="$1"
  require_command jq "session_meta_load requires jq"

  local meta_file
  meta_file="$(session_meta_file "$session_file")"

  if [[ -f "$meta_file" ]]; then
    cat "$meta_file"
    return
  fi

  local now
  now="$(timestamp_ms)"
  local session_id
  session_id="$(uuid_generate)"

  local meta
  meta="$(jq -nc \
    --arg sid "$session_id" \
    --arg ts "$now" \
    '{
      sessionId: $sid,
      updatedAt: ($ts | tonumber),
      channel: "",
      lastChannel: "",
      totalTokens: 0,
      compactionCount: 0,
      memoryFlushCompactionCount: -1,
      queueMode: "followup"
    }')"

  ensure_dir "$(dirname "$meta_file")"
  printf '%s\n' "$meta" > "$meta_file"
  chmod 600 "$meta_file" 2>/dev/null || true
  printf '%s' "$meta"
}

# Update a single field in session metadata
session_meta_update() {
  local session_file="$1"
  local field="$2"
  local value="$3"

  require_command jq "session_meta_update requires jq"

  local meta_file
  meta_file="$(session_meta_file "$session_file")"

  local meta
  if [[ -f "$meta_file" ]]; then
    meta="$(cat "$meta_file")"
  else
    meta="$(session_meta_load "$session_file")"
  fi

  meta="$(printf '%s' "$meta" | jq --arg f "$field" --argjson v "$value" '.[$f] = $v')"
  printf '%s\n' "$meta" > "$meta_file"
}

# Read a single field from session metadata
session_meta_get() {
  local session_file="$1"
  local field="$2"
  local default="${3:-}"

  require_command jq "session_meta_get requires jq"

  local meta_file
  meta_file="$(session_meta_file "$session_file")"

  if [[ ! -f "$meta_file" ]]; then
    printf '%s' "$default"
    return
  fi

  local value
  value="$(jq -r --arg f "$field" '.[$f] // empty' < "$meta_file" 2>/dev/null)"
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

# ---- Token Estimation ----

# Estimate the number of tokens in a session file.
# Uses chars/4 as a rough approximation.
session_estimate_tokens() {
  local session_file="$1"

  if [[ ! -f "$session_file" ]]; then
    printf '0'
    return
  fi

  local char_count
  char_count="$(wc -c < "$session_file" | tr -d ' ')"
  printf '%d' $((char_count / 4))
}

# Check whether auto-compaction should be triggered.
# Returns 0 if compaction needed, 1 if not.
session_check_compaction() {
  local session_file="$1"
  local agent_id="${2:-main}"

  if [[ ! -f "$session_file" ]]; then
    return 1
  fi

  require_command jq "session_check_compaction requires jq"

  local context_tokens
  context_tokens="$(config_agent_get "$agent_id" "contextTokens" "200000")"

  local threshold
  threshold="$(config_agent_get_raw "$agent_id" '.compaction.threshold' 2>/dev/null)"
  if [[ -z "$threshold" || "$threshold" == "null" ]]; then
    threshold="0.8"
  fi

  local estimated
  estimated="$(session_estimate_tokens "$session_file")"

  local limit
  limit="$(printf '%s' "" | jq -n --argjson ct "$context_tokens" --argjson th "$threshold" \
    '($ct * $th) | floor')"

  if (( estimated > limit )); then
    return 0
  fi

  return 1
}

# ---- Auto-Compaction ----

# Detect context overflow from an API error response.
# Returns 0 if overflow detected, 1 otherwise.
session_detect_overflow() {
  local api_response="$1"

  local error_text
  error_text="$(printf '%s' "$api_response" | jq -r '
    (.error.message // "") + " " + (.error.type // "") + " " + (.error // "" | tostring)
  ' 2>/dev/null)"

  if [[ -z "$error_text" ]]; then
    return 1
  fi

  local lower_text
  lower_text="$(printf '%s' "$error_text" | tr '[:upper:]' '[:lower:]')"

  case "$lower_text" in
    *"request_too_large"*)       return 0 ;;
    *"context length exceeded"*) return 0 ;;
    *"maximum context length"*)  return 0 ;;
    *"prompt is too long"*)      return 0 ;;
    *"too many tokens"*)         return 0 ;;
    *"token limit"*)             return 0 ;;
    *"content too large"*)       return 0 ;;
  esac

  # Check for HTTP 413 + "too large" combination
  local http_status
  http_status="$(printf '%s' "$api_response" | jq -r '.error.status // .status // empty' 2>/dev/null)"
  if [[ "$http_status" == "413" ]]; then
    return 0
  fi

  return 1
}

# Compact a session by summarizing old history via LLM or truncating.
# mode: "summary" (default) uses LLM to summarize, "truncate" keeps recent messages.
# Keeps the summary + recent messages within the reserve token budget.
session_compact() {
  local session_file="$1"
  local model="$2"
  local api_key="$3"
  local mode="${4:-summary}"

  if [[ ! -f "$session_file" ]]; then
    return 1
  fi

  require_command jq "session_compact requires jq"

  local total_lines
  total_lines="$(wc -l < "$session_file" | tr -d ' ')"
  if (( total_lines <= 10 )); then
    log_debug "Session too short to compact ($total_lines lines)"
    return 1
  fi

  # Determine how many tokens to keep after compaction
  local reserve_tokens
  reserve_tokens="$(config_get_raw '.agents.defaults.compaction.reserveTokens // 50000' 2>/dev/null)"
  if [[ -z "$reserve_tokens" || "$reserve_tokens" == "null" ]]; then
    reserve_tokens=50000
  fi

  if [[ "$mode" == "truncate" ]]; then
    # Truncate mode: keep only the last N messages that fit within the reserve budget
    local current_chars
    current_chars="$(wc -c < "$session_file" | tr -d ' ')"
    local target_chars=$((reserve_tokens * 4))

    if (( current_chars <= target_chars )); then
      log_debug "Session within reserve budget, no truncation needed"
      return 1
    fi

    # Binary search for the right number of tail lines
    local keep_lines=$((total_lines / 2))
    local tmp
    tmp="$(tmpfile "session_trunc_probe")"
    while (( keep_lines > 6 )); do
      tail -n "$keep_lines" "$session_file" > "$tmp"
      local probe_chars
      probe_chars="$(wc -c < "$tmp" | tr -d ' ')"
      if (( probe_chars <= target_chars )); then
        break
      fi
      keep_lines=$((keep_lines / 2))
    done
    rm -f "$tmp"

    if (( keep_lines < 6 )); then
      keep_lines=6
    fi

    local tmp2
    tmp2="$(tmpfile "session_compact_truncate")"
    tail -n "$keep_lines" "$session_file" > "$tmp2"
    mv "$tmp2" "$session_file"

    local prev_count
    prev_count="$(session_meta_get "$session_file" "compactionCount" "0")"
    local new_count=$((prev_count + 1))
    session_meta_update "$session_file" "compactionCount" "$new_count"

    log_info "Session truncated to $keep_lines lines (compaction #${new_count}, mode=truncate)"
    return 0
  fi

  # Summary mode (default): use LLM to summarize old messages
  # Keep the last 20% of messages (at least 6)
  local keep_recent=$((total_lines / 5))
  if (( keep_recent < 6 )); then
    keep_recent=6
  fi
  if (( keep_recent > total_lines )); then
    keep_recent=$total_lines
  fi

  local old_count=$((total_lines - keep_recent))
  if (( old_count <= 0 )); then
    return 1
  fi

  # Extract old messages for summarization
  local old_messages
  old_messages="$(head -n "$old_count" "$session_file" | jq -s '
    [.[] | select(.role == "user" or .role == "assistant") | {role: .role, content: (.content // "" | .[0:500])}]
  ' 2>/dev/null)"

  if [[ -z "$old_messages" || "$old_messages" == "[]" ]]; then
    return 1
  fi

  # Build a compaction prompt
  local compact_prompt="Summarize the following conversation history into a concise context summary. Preserve key facts, decisions, user preferences, and action items. Output only the summary, no preamble."
  local compact_messages
  compact_messages="$(jq -nc --arg prompt "$compact_prompt" --argjson msgs "$old_messages" '
    [{role: "user", content: ($prompt + "\n\n" + ($msgs | map(.role + ": " + .content) | join("\n")))}]
  ')"

  # Call the API for summarization using the provider abstraction
  local provider
  provider="$(agent_resolve_provider "$model")"
  local summary_response
  local api_format
  api_format="$(_provider_api_format "$provider")"
  case "$api_format" in
    anthropic)
      summary_response="$(agent_call_anthropic "$model" "You are a conversation summarizer." "$compact_messages" 2048 0.3 "" 2>/dev/null)" || true
      ;;
    openai)
      summary_response="$(agent_call_openai "$model" "You are a conversation summarizer." "$compact_messages" 2048 0.3 "" 2>/dev/null)" || true
      ;;
    google)
      summary_response="$(agent_call_google "$model" "You are a conversation summarizer." "$compact_messages" 2048 0.3 "" 2>/dev/null)" || true
      ;;
    *)
      log_error "Unsupported API format for compaction: $api_format (provider=$provider)"
      return 1
      ;;
  esac

  local summary_text
  summary_text="$(printf '%s' "$summary_response" | jq -r '
    [.content[]? | select(.type == "text") | .text] | join("")
  ' 2>/dev/null)"

  if [[ -z "$summary_text" ]]; then
    log_warn "Compaction failed: could not generate summary"
    # Fallback: just drop old messages
    local tmp
    tmp="$(tmpfile "session_compact_fallback")"
    tail -n "$keep_recent" "$session_file" > "$tmp"
    mv "$tmp" "$session_file"
    return 0
  fi

  # Build new session: summary as system message + recent messages
  local tmp
  tmp="$(tmpfile "session_compact")"
  local ts
  ts="$(timestamp_ms)"
  local summary_line
  summary_line="$(jq -nc --arg c "[Session compacted] $summary_text" --arg t "$ts" \
    '{role: "system", content: $c, ts: ($t | tonumber), compacted: true}')"
  printf '%s\n' "$summary_line" > "$tmp"
  tail -n "$keep_recent" "$session_file" >> "$tmp"
  mv "$tmp" "$session_file"

  # Update compaction count in metadata
  local prev_count
  prev_count="$(session_meta_get "$session_file" "compactionCount" "0")"
  local new_count=$((prev_count + 1))
  session_meta_update "$session_file" "compactionCount" "$new_count"

  log_info "Session compacted: kept $keep_recent recent + summary (compaction #${new_count}, mode=summary)"
  return 0
}
